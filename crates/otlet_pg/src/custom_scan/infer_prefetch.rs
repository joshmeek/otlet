unsafe fn prefetch_infer_now_batch(
    node: *mut pg_sys::CustomScanState,
    runtime: &mut RuntimeState,
    current_subject_id: &str,
    current_slot: *mut pg_sys::TupleTableSlot,
) -> Result<(), String> {
    let target_infer_count = remaining_infer_capacity(runtime);
    if target_infer_count == 0 {
        runtime.fail_closed_rows = runtime.fail_closed_rows.saturating_add(1);
        return Ok(());
    }

    let mut rows = Vec::with_capacity(target_infer_count.saturating_mul(2).max(4));
    if !submit_prefetched_infer_row(runtime, current_subject_id, current_slot, &mut rows)? {
        runtime.fail_closed_rows = runtime.fail_closed_rows.saturating_add(1);
        return Ok(());
    }

    let mut prefetched_infers = 1usize;
    let mut prefetched_source_rows = 1usize;
    loop {
        if prefetched_infers >= target_infer_count {
            break;
        }
        if prefetched_source_rows >= runtime.infer_max_rows as usize {
            break;
        }
        let Some(slot) = (unsafe { next_source_slot(node, runtime) }) else {
            break;
        };
        prefetched_source_rows = prefetched_source_rows.saturating_add(1);
        runtime.rows_seen = runtime.rows_seen.saturating_add(1);
        let mut isnull = false;
        let value = unsafe {
            pg_sys::slot_getattr(
                slot,
                std::ffi::c_int::from(runtime.subject_attno),
                &raw mut isnull,
            )
        };
        if isnull {
            continue;
        }
        let Some(subject_id) = (unsafe { datum_to_text(value, runtime.subject_typid) }) else {
            continue;
        };
        let semantic_state = runtime
            .semantic_states
            .get(&subject_id)
            .copied()
            .unwrap_or(SubjectSemanticState::Missing);
        match semantic_state {
            SubjectSemanticState::FreshMatch => {
                runtime.fresh_matches = runtime.fresh_matches.saturating_add(1);
                runtime.lookup_rows = runtime.lookup_rows.saturating_add(1);
                record_emitted_freshness_basis(runtime, &subject_id);
                rows.push(PrefetchedRow::Ready(unsafe { copy_slot_buffer(slot)? }));
            }
            SubjectSemanticState::FreshNonMatch => {
                runtime.fresh_non_matches = runtime.fresh_non_matches.saturating_add(1);
                runtime.lookup_rows = runtime.lookup_rows.saturating_add(1);
            }
            SubjectSemanticState::Stale | SubjectSemanticState::Missing => {
                if semantic_state == SubjectSemanticState::Stale {
                    runtime.stale_rows = runtime.stale_rows.saturating_add(1);
                } else {
                    runtime.missing_rows = runtime.missing_rows.saturating_add(1);
                }
                if prefetched_infers < target_infer_count
                    && submit_prefetched_infer_row(runtime, &subject_id, slot, &mut rows)?
                {
                    prefetched_infers = prefetched_infers.saturating_add(1);
                    continue;
                }
                runtime.fail_closed_rows = runtime.fail_closed_rows.saturating_add(1);
            }
            SubjectSemanticState::InFlight => {
                runtime.inflight_rows = runtime.inflight_rows.saturating_add(1);
                runtime.fail_closed_rows = runtime.fail_closed_rows.saturating_add(1);
            }
        }
    }

    crate::infer_now::signal_infer_now_worker();
    resolve_prefetched_rows(runtime, rows);
    Ok(())
}

fn remaining_infer_capacity(runtime: &RuntimeState) -> usize {
    let policy_remaining = (runtime.infer_max_rows as usize)
        .saturating_sub(usize::try_from(runtime.infer_now_batches).unwrap_or(usize::MAX));
    let queue_remaining = crate::infer_now::queue_snapshot().available_slots;
    policy_remaining.min(queue_remaining)
}

fn submit_prefetched_infer_row(
    runtime: &RuntimeState,
    subject_id: &str,
    slot: *mut pg_sys::TupleTableSlot,
    rows: &mut Vec<PrefetchedRow>,
) -> Result<bool, String> {
    if runtime.infer_ms == 0 || runtime.infer_now_batches >= u64::from(runtime.infer_max_rows) {
        return Ok(false);
    }
    with_semantic_slot_input_bytes(runtime, subject_id, slot, |input_bytes| {
        let submitted_at = unsafe { pg_sys::GetCurrentTimestamp() };
        let snapshot_before = crate::infer_now::snapshot();
        let Some(submitted) =
            crate::infer_now::submit_infer_now_bytes(&runtime.task_name, subject_id, input_bytes)?
        else {
            return Ok(false);
        };
        let buffered_slot = unsafe { copy_slot_buffer(slot)? };
        rows.push(PrefetchedRow::Infer(PendingInferNowRow {
            subject_id: subject_id.to_owned(),
            slot: buffered_slot,
            submitted,
            submitted_at,
            snapshot_before,
        }));
        Ok(true)
    })
}

fn resolve_prefetched_rows(runtime: &mut RuntimeState, rows: Vec<PrefetchedRow>) {
    for row in rows {
        match row {
            PrefetchedRow::Ready(tuple) => {
                runtime.pending_output_rows.push_back(tuple);
            }
            PrefetchedRow::Infer(pending) => {
                let resolution = wait_for_prefetched_infer_row(runtime, &pending);
                match resolution {
                    Ok(SemanticResolution::Match) => {
                        runtime.infer_resolved_rows = runtime.infer_resolved_rows.saturating_add(1);
                        runtime.infer_returned_rows = runtime.infer_returned_rows.saturating_add(1);
                        record_emitted_freshness_basis(runtime, &pending.subject_id);
                        runtime.pending_output_rows.push_back(pending.slot);
                    }
                    Ok(SemanticResolution::NonMatch) => {
                        runtime.infer_resolved_rows = runtime.infer_resolved_rows.saturating_add(1);
                        unsafe {
                            pg_sys::ExecDropSingleTupleTableSlot(pending.slot);
                        }
                    }
                    Ok(SemanticResolution::Unresolved) => {
                        runtime.fail_closed_rows = runtime.fail_closed_rows.saturating_add(1);
                        unsafe {
                            pg_sys::ExecDropSingleTupleTableSlot(pending.slot);
                        }
                    }
                    Err(err) => {
                        runtime.infer_now_failures = runtime.infer_now_failures.saturating_add(1);
                        truncate_infer_now_error_into(&mut runtime.infer_now_last_error, &err);
                        runtime.fail_closed_rows = runtime.fail_closed_rows.saturating_add(1);
                        unsafe {
                            pg_sys::ExecDropSingleTupleTableSlot(pending.slot);
                        }
                        pgrx::warning!(
                            "otlet semantic CustomScan prefetched infer-now failed: {err}"
                        );
                    }
                }
            }
        }
    }
}

fn wait_for_prefetched_infer_row(
    runtime: &mut RuntimeState,
    pending: &PendingInferNowRow,
) -> Result<SemanticResolution, String> {
    match crate::infer_now::wait_for_submitted_infer_now(&pending.submitted, runtime.infer_ms) {
        Ok(Some(completed)) => {
            finish_infer_now_success(
                runtime,
                &pending.subject_id,
                completed.job_id,
                pending.submitted_at,
            )
        }
        Ok(None) => {
            let infer_state_after = crate::infer_now::snapshot();
            record_infer_now_timeout_deltas(runtime, pending.snapshot_before, infer_state_after);
            runtime.infer_now_ms = runtime
                .infer_now_ms
                .saturating_add(wait_elapsed_ms(pending.submitted_at));
            Ok(SemanticResolution::Unresolved)
        }
        Err(err) => {
            let infer_state_after = crate::infer_now::snapshot();
            if infer_state_after.last_job_id > 0
                && infer_state_after.last_job_id != pending.snapshot_before.last_job_id
            {
                record_infer_now_failed_provenance(runtime, infer_state_after.last_job_id)?;
            }
            runtime.infer_now_ms = runtime
                .infer_now_ms
                .saturating_add(wait_elapsed_ms(pending.submitted_at));
            Err(err)
        }
    }
}

const fn record_infer_now_timeout_deltas(
    runtime: &mut RuntimeState,
    before: crate::infer_now::InferNowSnapshot,
    after: crate::infer_now::InferNowSnapshot,
) {
    if after.timeouts > before.timeouts {
        runtime.infer_now_timeouts = runtime
            .infer_now_timeouts
            .saturating_add(after.timeouts.saturating_sub(before.timeouts));
    }
}

unsafe fn copy_slot_buffer(
    slot: *mut pg_sys::TupleTableSlot,
) -> Result<*mut pg_sys::TupleTableSlot, String> {
    unsafe {
        if slot.is_null() {
            return Err("cannot copy null tuple slot".to_owned());
        }
        if (*slot).tts_tupleDescriptor.is_null() {
            return Err("cannot copy tuple slot without tuple descriptor".to_owned());
        }
        if (*slot).tts_ops.is_null() {
            return Err("cannot copy tuple slot without slot ops".to_owned());
        }
        let buffered_slot =
            pg_sys::MakeSingleTupleTableSlot((*slot).tts_tupleDescriptor, (*slot).tts_ops);
        if buffered_slot.is_null() {
            return Err("MakeSingleTupleTableSlot returned null".to_owned());
        }
        pg_sys::ExecCopySlot(buffered_slot, slot);
        Ok(buffered_slot)
    }
}

fn infer_now_or_record_failure(
    runtime: &mut RuntimeState,
    subject_id: &str,
    slot: *mut pg_sys::TupleTableSlot,
) -> SemanticResolution {
    match infer_now_if_allowed(runtime, subject_id, slot) {
        Ok(resolution) => resolution,
        Err(err) => {
            runtime.infer_now_failures = runtime.infer_now_failures.saturating_add(1);
            truncate_infer_now_error_into(&mut runtime.infer_now_last_error, &err);
            pgrx::warning!("otlet semantic CustomScan infer-now failed: {err}");
            SemanticResolution::Unresolved
        }
    }
}

fn truncate_infer_now_error_into(dst: &mut String, error: &str) {
    const MAX_ERROR_CHARS: usize = 512;
    dst.clear();
    // UTF-8 byte length upper-bounds char count, so this is a safe fast path.
    if error.len() <= MAX_ERROR_CHARS {
        dst.push_str(error);
        return;
    }
    dst.extend(error.chars().take(MAX_ERROR_CHARS));
}

fn infer_now_if_allowed(
    runtime: &mut RuntimeState,
    subject_id: &str,
    slot: *mut pg_sys::TupleTableSlot,
) -> Result<SemanticResolution, String> {
    if runtime.infer_ms == 0 || runtime.infer_now_batches >= u64::from(runtime.infer_max_rows) {
        return Ok(SemanticResolution::Unresolved);
    }

    let start = unsafe { pg_sys::GetCurrentTimestamp() };
    let infer_state_before = crate::infer_now::snapshot();
    let submitted = match with_semantic_slot_input_bytes(runtime, subject_id, slot, |input_bytes| {
        crate::infer_now::submit_infer_now_bytes(&runtime.task_name, subject_id, input_bytes)
    }) {
        Ok(Some(submitted)) => submitted,
        Ok(None) => {
            runtime.infer_now_ms = runtime.infer_now_ms.saturating_add(wait_elapsed_ms(start));
            return Ok(SemanticResolution::Unresolved);
        }
        Err(err) => {
            runtime.infer_now_ms = runtime.infer_now_ms.saturating_add(wait_elapsed_ms(start));
            return Err(err);
        }
    };
    crate::infer_now::signal_infer_now_worker();
    let completed =
        match crate::infer_now::wait_for_submitted_infer_now(&submitted, runtime.infer_ms) {
            Ok(Some(completed)) => completed,
            Ok(None) => {
                let infer_state_after = crate::infer_now::snapshot();
                record_infer_now_timeout_deltas(runtime, infer_state_before, infer_state_after);
                runtime.infer_now_ms = runtime.infer_now_ms.saturating_add(wait_elapsed_ms(start));
                return Ok(SemanticResolution::Unresolved);
            }
            Err(err) => {
                let infer_state_after = crate::infer_now::snapshot();
                if infer_state_after.last_job_id > 0
                    && infer_state_after.last_job_id != infer_state_before.last_job_id
                {
                    record_infer_now_failed_provenance(runtime, infer_state_after.last_job_id)?;
                }
                runtime.infer_now_ms = runtime.infer_now_ms.saturating_add(wait_elapsed_ms(start));
                return Err(err);
            }
        };

    finish_infer_now_success(runtime, subject_id, completed.job_id, start)
}

fn finish_infer_now_success(
    runtime: &mut RuntimeState,
    subject_id: &str,
    job_id: i64,
    start: pg_sys::TimestampTz,
) -> Result<SemanticResolution, String> {
    if job_id <= 0 {
        runtime.infer_now_ms = runtime.infer_now_ms.saturating_add(wait_elapsed_ms(start));
        return Ok(SemanticResolution::Unresolved);
    }
    runtime.infer_now_batches += 1;
    // One SPI session: stamp executor context, read provenance, refresh subject.
    let state = with_latest_snapshot(|| {
        finish_infer_now_success_spi(runtime, subject_id, job_id)
    })?;
    runtime.infer_now_ms = runtime.infer_now_ms.saturating_add(wait_elapsed_ms(start));
    match state {
        SubjectSemanticState::FreshMatch => Ok(SemanticResolution::Match),
        SubjectSemanticState::FreshNonMatch => Ok(SemanticResolution::NonMatch),
        _ => Ok(SemanticResolution::Unresolved),
    }
}

fn finish_infer_now_success_spi(
    runtime: &mut RuntimeState,
    subject_id: &str,
    job_id: i64,
) -> Result<SubjectSemanticState, String> {
    let fused_sql = match runtime.index_kind {
        SemanticIndexKind::Row => INFER_NOW_PROVENANCE_AND_ROW_STATE_SQL,
        SemanticIndexKind::Join => INFER_NOW_PROVENANCE_AND_JOIN_STATE_SQL,
    };
    // One SPI session: stamp via update (volatile), then one pure SELECT for
    // provenance + subject refresh. Avoids UPDATE-in-SELECT under non-volatile
    // CustomScan contexts. Executor context is frozen at begin-scan.
    let (provenance, state) = pgrx::Spi::connect_mut(|client| {
        let update_args = [
            job_id.into(),
            runtime.infer_now_executor_context_json.as_str().into(),
        ];
        client
            .update(INFER_NOW_STAMP_EXECUTOR_CONTEXT_SQL, None, &update_args)
            .map_err(to_string)?;
        let fused_args = match runtime.index_kind {
            SemanticIndexKind::Row => vec![
                job_id.into(),
                subject_id.into(),
                runtime.expected_json.as_str().into(),
                runtime.task_name.as_str().into(),
                runtime.record_type.as_str().into(),
            ],
            SemanticIndexKind::Join => vec![
                job_id.into(),
                runtime.index_name.as_str().into(),
                subject_id.into(),
                runtime.expected_json.as_str().into(),
                runtime.task_name.as_str().into(),
            ],
        };
        let fused_table = client
            .select(fused_sql, Some(1), &fused_args)
            .map_err(to_string)?;
        provenance_and_state_from_spi_table(fused_table)
    })?;
    runtime.infer_receipts = runtime.infer_receipts.saturating_add(provenance.receipts);
    runtime.infer_trace_receipt_id = provenance.receipt_id;
    runtime.infer_trace_prompt_tokens = runtime
        .infer_trace_prompt_tokens
        .saturating_add(provenance.prompt_tokens);
    runtime.infer_trace_generated_tokens = runtime
        .infer_trace_generated_tokens
        .saturating_add(provenance.generated_tokens);
    runtime.infer_trace_generate_ms = runtime
        .infer_trace_generate_ms
        .saturating_add(provenance.generate_ms);
    runtime.infer_trace_finish_sql_ms = runtime
        .infer_trace_finish_sql_ms
        .saturating_add(provenance.finish_sql_ms);
    runtime.infer_trace_materialize_ms = runtime
        .infer_trace_materialize_ms
        .saturating_add(provenance.materialize_ms);
    runtime.infer_trace_version = provenance.trace_version;
    runtime.infer_trace_runtime_fingerprint_hash = provenance.runtime_fingerprint_hash;
    runtime.infer_trace_probability_status = provenance.probability_status;
    runtime.infer_trace_schema_force = provenance.schema_force;
    runtime.infer_trace_detailed_status = provenance.detailed_trace_status;
    runtime.infer_trace_detailed_captured_tokens = provenance.detailed_trace_captured_tokens;
    runtime.infer_trace_detailed_top_k = provenance.detailed_trace_top_k;
    runtime
        .semantic_states
        .insert(subject_id.to_owned(), state);
    Ok(state)
}
