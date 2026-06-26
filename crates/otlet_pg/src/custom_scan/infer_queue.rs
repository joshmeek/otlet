fn queue_refresh_if_allowed(runtime: &mut RuntimeState, subject_id: &str) {
    if !runtime.allow_refresh || runtime.queued_refresh_subjects.contains(subject_id) {
        return;
    }
    runtime
        .queued_refresh_subjects
        .insert(subject_id.to_string());
    match queue_subject_refresh(&runtime.task_name, subject_id) {
        Ok(true) => runtime.queued_refreshes += 1,
        Ok(false) => {}
        Err(err) => pgrx::warning!("otlet semantic CustomScan refresh queue failed: {err}"),
    }
}

fn queue_subject_refresh(task_name: &str, subject_id: &str) -> Result<bool, String> {
    let query = format!(
        "SELECT otlet.run_task_subject({}, {})::bigint AS queued",
        sql_literal(task_name),
        sql_literal(subject_id)
    );
    pgrx::Spi::connect(|client| {
        let table = client
            .select(query.as_str(), Some(1), &[])
            .map_err(to_string)?;
        let row = table.first();
        let queued = row.get_by_name::<i64, _>("queued").map_err(to_string)?;
        Ok(queued.unwrap_or(0) > 0)
    })
}

fn wait_for_refresh_if_allowed(
    runtime: &mut RuntimeState,
    subject_id: &str,
    active_seen_before_wait: bool,
) -> Result<SemanticResolution, String> {
    if runtime.wait_ms == 0 {
        return Ok(SemanticResolution::Unresolved);
    }
    let start = unsafe { pg_sys::GetCurrentTimestamp() };
    let max_wait_ms = runtime.wait_ms.min(10_000) as std::ffi::c_int;
    let mut active_seen = active_seen_before_wait;
    loop {
        unsafe {
            pg_sys::ProcessInterrupts();
        }
        let active =
            with_latest_snapshot(|| active_subject_refreshes(&runtime.task_name, subject_id))?;
        if active == 0 {
            if !active_seen {
                return Ok(SemanticResolution::Unresolved);
            }
            with_latest_snapshot(|| materialize_semantic_subject(runtime, subject_id))?;
            let state = refresh_runtime_subject_state(runtime, subject_id)?;
            match state {
                SubjectSemanticState::FreshMatch => return Ok(SemanticResolution::Match),
                SubjectSemanticState::FreshNonMatch => return Ok(SemanticResolution::NonMatch),
                _ => return Ok(SemanticResolution::Unresolved),
            }
        } else {
            active_seen = true;
        }
        let now = unsafe { pg_sys::GetCurrentTimestamp() };
        if unsafe { pg_sys::TimestampDifferenceExceeds(start, now, max_wait_ms) } {
            return Ok(SemanticResolution::Unresolved);
        }
        unsafe {
            pg_sys::pg_usleep(50_000);
        }
    }
}

fn should_prefetch_infer_now(runtime: &RuntimeState) -> bool {
    runtime.infer_ms > 0
        && runtime.infer_max_rows > 1
        && !runtime.auto_policy
        && !runtime.allow_refresh
}

unsafe fn prefetch_infer_now_batch(
    node: *mut pg_sys::CustomScanState,
    runtime: &mut RuntimeState,
    current_subject_id: &str,
    current_slot: *mut pg_sys::TupleTableSlot,
) -> Result<(), String> {
    let mut rows = Vec::new();
    if !submit_prefetched_infer_row(runtime, current_subject_id, current_slot, &mut rows)? {
        runtime.fail_closed_rows = runtime.fail_closed_rows.saturating_add(1);
        return Ok(());
    }

    let mut prefetched_source_rows = 1usize;
    loop {
        if prefetched_infer_count(&rows) >= remaining_infer_capacity(runtime) {
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
            pg_sys::slot_getattr(slot, runtime.subject_attno as std::ffi::c_int, &mut isnull)
        };
        if isnull {
            continue;
        }
        let Some(subject_id) = (unsafe { datum_to_text(value, runtime.subject_typid) }) else {
            continue;
        };
        match runtime
            .semantic_states
            .get(&subject_id)
            .copied()
            .unwrap_or(SubjectSemanticState::Missing)
        {
            SubjectSemanticState::FreshMatch => {
                runtime.fresh_matches = runtime.fresh_matches.saturating_add(1);
                runtime.lookup_rows = runtime.lookup_rows.saturating_add(1);
                rows.push(PrefetchedRow::Ready(unsafe { copy_slot_buffer(slot)? }));
            }
            SubjectSemanticState::FreshNonMatch => {
                runtime.fresh_non_matches = runtime.fresh_non_matches.saturating_add(1);
                runtime.lookup_rows = runtime.lookup_rows.saturating_add(1);
            }
            SubjectSemanticState::Stale | SubjectSemanticState::Missing => {
                if runtime
                    .semantic_states
                    .get(&subject_id)
                    .copied()
                    .unwrap_or(SubjectSemanticState::Missing)
                    == SubjectSemanticState::Stale
                {
                    runtime.stale_rows = runtime.stale_rows.saturating_add(1);
                } else {
                    runtime.missing_rows = runtime.missing_rows.saturating_add(1);
                }
                if prefetched_infer_count(&rows) < remaining_infer_capacity(runtime)
                    && submit_prefetched_infer_row(runtime, &subject_id, slot, &mut rows)?
                {
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

    resolve_prefetched_rows(runtime, rows);
    Ok(())
}

fn remaining_infer_capacity(runtime: &RuntimeState) -> usize {
    (runtime.infer_max_rows as usize).saturating_sub(runtime.infer_now_batches as usize)
}

fn prefetched_infer_count(rows: &[PrefetchedRow]) -> usize {
    rows.iter()
        .filter(|row| matches!(row, PrefetchedRow::Infer(_)))
        .count()
}

fn submit_prefetched_infer_row(
    runtime: &mut RuntimeState,
    subject_id: &str,
    slot: *mut pg_sys::TupleTableSlot,
    rows: &mut Vec<PrefetchedRow>,
) -> Result<bool, String> {
    if runtime.infer_ms == 0 || runtime.infer_now_batches >= runtime.infer_max_rows as u64 {
        return Ok(false);
    }
    let input = semantic_slot_input(runtime, subject_id, slot)
        .map_err(|err| format!("tuple-slot infer-now input failed; SPI fallback disabled: {err}"))?
        .ok_or_else(|| "tuple-slot infer-now input missing; SPI fallback disabled".to_string())?;
    let submitted_at = unsafe { pg_sys::GetCurrentTimestamp() };
    let snapshot_before = crate::infer_now::snapshot();
    let Some(submitted) =
        crate::infer_now::submit_infer_now(&runtime.task_name, subject_id, &input)?
    else {
        return Ok(false);
    };
    let buffered_slot = unsafe { copy_slot_buffer(slot)? };
    crate::infer_now::signal_infer_now_worker();
    rows.push(PrefetchedRow::Infer(PendingInferNowRow {
        subject_id: subject_id.to_string(),
        slot: buffered_slot,
        submitted,
        submitted_at,
        snapshot_before,
    }));
    Ok(true)
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
                        runtime.infer_now_last_error = truncate_infer_now_error(&err);
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

fn record_infer_now_timeout_deltas(
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
            return Err("cannot copy null tuple slot".to_string());
        }
        if (*slot).tts_tupleDescriptor.is_null() {
            return Err("cannot copy tuple slot without tuple descriptor".to_string());
        }
        if (*slot).tts_ops.is_null() {
            return Err("cannot copy tuple slot without slot ops".to_string());
        }
        let buffered_slot =
            pg_sys::MakeSingleTupleTableSlot((*slot).tts_tupleDescriptor, (*slot).tts_ops);
        if buffered_slot.is_null() {
            return Err("MakeSingleTupleTableSlot returned null".to_string());
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
            runtime.infer_now_last_error = truncate_infer_now_error(&err);
            pgrx::warning!("otlet semantic CustomScan infer-now failed: {err}");
            SemanticResolution::Unresolved
        }
    }
}

fn truncate_infer_now_error(error: &str) -> String {
    const MAX_ERROR_CHARS: usize = 512;
    error.chars().take(MAX_ERROR_CHARS).collect()
}

fn infer_now_if_allowed(
    runtime: &mut RuntimeState,
    subject_id: &str,
    slot: *mut pg_sys::TupleTableSlot,
) -> Result<SemanticResolution, String> {
    if runtime.infer_ms == 0 || runtime.infer_now_batches >= runtime.infer_max_rows as u64 {
        return Ok(SemanticResolution::Unresolved);
    }

    let input = semantic_slot_input(runtime, subject_id, slot)
        .map_err(|err| format!("tuple-slot infer-now input failed; SPI fallback disabled: {err}"))?
        .ok_or_else(|| "tuple-slot infer-now input missing; SPI fallback disabled".to_string())?;
    let start = unsafe { pg_sys::GetCurrentTimestamp() };
    let infer_state_before = crate::infer_now::snapshot();
    let request = crate::infer_now::submit_infer_now(&runtime.task_name, subject_id, &input);
    let submitted = match request {
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
    record_infer_now_executor_context(runtime, job_id)?;
    with_latest_snapshot(|| materialize_semantic_subject(runtime, subject_id))?;
    let provenance = with_latest_snapshot(|| infer_now_provenance_counts(job_id))?;
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
    runtime.infer_trace_version = provenance.trace_version;
    runtime.infer_trace_probability_status = provenance.probability_status;
    runtime.infer_trace_schema_force = provenance.schema_force;
    runtime.infer_trace_detailed_status = provenance.detailed_trace_status;
    runtime.infer_trace_detailed_captured_tokens = provenance.detailed_trace_captured_tokens;
    runtime.infer_trace_detailed_top_k = provenance.detailed_trace_top_k;
    let state = refresh_runtime_subject_state(runtime, subject_id)?;
    runtime.infer_now_ms = runtime.infer_now_ms.saturating_add(wait_elapsed_ms(start));
    match state {
        SubjectSemanticState::FreshMatch => Ok(SemanticResolution::Match),
        SubjectSemanticState::FreshNonMatch => Ok(SemanticResolution::NonMatch),
        _ => Ok(SemanticResolution::Unresolved),
    }
}
