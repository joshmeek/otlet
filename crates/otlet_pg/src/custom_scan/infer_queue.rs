thread_local! {
    // Match infer_now INPUT_CAP so typical slot JSON avoids growth reallocs.
    static SEMANTIC_SLOT_INPUT_BYTES: RefCell<Vec<u8>> =
        RefCell::new(Vec::with_capacity(8192));
}

const INFER_NOW_INPUT_MISSING: &str =
    "tuple-slot infer-now input missing; SPI fallback disabled";

fn with_semantic_slot_input_bytes<R>(
    runtime: &RuntimeState,
    subject_id: &str,
    slot: *mut pg_sys::TupleTableSlot,
    f: impl FnOnce(&[u8]) -> Result<R, String>,
) -> Result<R, String> {
    let input = semantic_slot_input(runtime, subject_id, slot)
        .map_err(|err| format!("tuple-slot infer-now input failed; SPI fallback disabled: {err}"))?
        .ok_or_else(|| INFER_NOW_INPUT_MISSING.to_owned())?;

    SEMANTIC_SLOT_INPUT_BYTES.with(|cell| {
        let mut bytes = cell.borrow_mut();
        bytes.clear();
        serde_json::to_writer(&mut *bytes, &input).map_err(|err| err.to_string())?;
        f(&bytes)
    })
}

fn queue_refresh_if_allowed(runtime: &mut RuntimeState, subject_id: &str) {
    if !runtime.allow_refresh {
        return;
    }
    if runtime.queued_refresh_subjects.contains(subject_id)
        || runtime
            .pending_refresh_subjects
            .iter()
            .any(|pending| pending == subject_id)
    {
        runtime.refresh_queue_skips = runtime.refresh_queue_skips.saturating_add(1);
        return;
    }
    runtime.pending_refresh_subjects.push(subject_id.to_owned());
    if runtime.pending_refresh_subjects.len() >= CUSTOM_SCAN_REFRESH_BATCH_SIZE {
        flush_refresh_queue_or_warn(runtime);
    }
}

fn flush_refresh_queue_or_warn(runtime: &mut RuntimeState) {
    if let Err(err) = flush_refresh_queue(runtime) {
        pgrx::warning!("otlet semantic CustomScan refresh queue failed: {err}");
    }
}

fn flush_refresh_queue(runtime: &mut RuntimeState) -> Result<(), String> {
    if runtime.pending_refresh_subjects.is_empty() {
        return Ok(());
    }
    let subjects = std::mem::replace(
        &mut runtime.pending_refresh_subjects,
        Vec::with_capacity(CUSTOM_SCAN_REFRESH_BATCH_SIZE),
    );
    runtime.refresh_queue_batches = runtime.refresh_queue_batches.saturating_add(1);
    let results = match queue_subject_refreshes(&runtime.task_name, &subjects) {
        Ok(results) => results,
        Err(err) => {
            runtime.refresh_queue_errors = runtime
                .refresh_queue_errors
                .saturating_add(subjects.len() as u64);
            return Err(err);
        }
    };
    for (subject_id, queued) in results {
        runtime.queued_refresh_subjects.insert(subject_id);
        if queued {
            runtime.queued_refreshes = runtime.queued_refreshes.saturating_add(1);
        } else {
            runtime.refresh_queue_skips = runtime.refresh_queue_skips.saturating_add(1);
        }
    }
    Ok(())
}

fn queue_subject_refreshes(
    task_name: &str,
    subject_ids: &[String],
) -> Result<Vec<(String, bool)>, String> {
    pgrx::Spi::connect(|client| {
        let subject_refs = subject_ids.iter().map(String::as_str).collect::<Vec<_>>();
        let args = [task_name.into(), subject_refs.as_slice().into()];
        let table = client
            .select(
                "SELECT subject_id, queued FROM otlet.run_task_subjects($1, $2::text[])",
                Some(subject_ids.len() as i64),
                &args,
            )
            .map_err(to_string)?;
        let mut results = Vec::with_capacity(table.len());
        for row in table {
            let subject_id = row
                .get::<String>(1)
                .map_err(to_string)?
                .ok_or_else(|| "otlet.run_task_subjects returned null subject_id".to_owned())?;
            let queued = row
                .get::<bool>(2)
                .map_err(to_string)?
                .ok_or_else(|| "otlet.run_task_subjects returned null queued status".to_owned())?;
            results.push((subject_id, queued));
        }
        if results.len() != subject_ids.len() {
            return Err(format!(
                "otlet.run_task_subjects returned {} of {} subjects",
                results.len(),
                subject_ids.len()
            ));
        }
        Ok(results)
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
    let max_wait_ms = std::ffi::c_int::try_from(runtime.wait_ms.min(10_000))
        .unwrap_or(std::ffi::c_int::MAX);
    let mut active_seen = active_seen_before_wait;
    let mut sleep_us: i64 = 50_000;
    loop {
        unsafe {
            pg_sys::ProcessInterrupts();
        }
        // One snapshot+SPI: poll active jobs; on completion transition, materialize
        // and re-read state without a second connect.
        let outcome = with_latest_snapshot(|| {
            wait_poll_active_or_materialize(runtime, subject_id, active_seen)
        })?;
        match outcome {
            WaitPollOutcome::StillActive => {
                active_seen = true;
            }
            WaitPollOutcome::NeverActive => {
                return Ok(SemanticResolution::Unresolved);
            }
            WaitPollOutcome::Resolved(state) => {
                return Ok(match state {
                    SubjectSemanticState::FreshMatch => SemanticResolution::Match,
                    SubjectSemanticState::FreshNonMatch => SemanticResolution::NonMatch,
                    _ => SemanticResolution::Unresolved,
                });
            }
        }
        let now = unsafe { pg_sys::GetCurrentTimestamp() };
        if unsafe { pg_sys::TimestampDifferenceExceeds(start, now, max_wait_ms) } {
            return Ok(SemanticResolution::Unresolved);
        }
        unsafe {
            pg_sys::pg_usleep(sleep_us);
        }
        // Back off while still in-flight so long waits do not SPI-poll every 50ms.
        sleep_us = (sleep_us.saturating_mul(2)).min(200_000);
    }
}

enum WaitPollOutcome {
    StillActive,
    NeverActive,
    Resolved(SubjectSemanticState),
}

fn wait_poll_active_or_materialize(
    runtime: &mut RuntimeState,
    subject_id: &str,
    active_seen: bool,
) -> Result<WaitPollOutcome, String> {
    // Cheap active-only probe until we have seen an active job. After that, one
    // SELECT gates materialize on !is_active and returns subject state.
    let fused_sql = match runtime.index_kind {
        SemanticIndexKind::Row => SEMANTIC_ROW_WAIT_MATERIALIZE_STATE_SQL,
        SemanticIndexKind::Join => SEMANTIC_JOIN_WAIT_MATERIALIZE_STATE_SQL,
    };
    pgrx::Spi::connect(|client| {
        if !active_seen {
            let active_args = [runtime.task_name.as_str().into(), subject_id.into()];
            let active_table = client
                .select(
                    "SELECT true AS active \
                     FROM otlet.jobs \
                     WHERE task_name = $1 \
                       AND subject_id = $2 \
                       AND status IN ('queued', 'running', 'cancel_requested') \
                     LIMIT 1",
                    Some(1),
                    &active_args,
                )
                .map_err(to_string)?;
            // Empty set = no active job (same as EXISTS false). A present row is true.
            if !active_table.is_empty() {
                return Ok(WaitPollOutcome::StillActive);
            }
            return Ok(WaitPollOutcome::NeverActive);
        }

        let state_args = match runtime.index_kind {
            SemanticIndexKind::Row => vec![
                runtime.index_name.as_str().into(),
                subject_id.into(),
                runtime.expected_json.as_str().into(),
                runtime.task_name.as_str().into(),
                runtime.record_type.as_str().into(),
            ],
            SemanticIndexKind::Join => vec![
                runtime.index_name.as_str().into(),
                subject_id.into(),
                runtime.expected_json.as_str().into(),
                runtime.task_name.as_str().into(),
            ],
        };
        let state_table = client
            .select(fused_sql, Some(1), &state_args)
            .map_err(to_string)?;
        let (is_active, state) = wait_poll_state_from_spi_table(state_table)?;
        if is_active {
            return Ok(WaitPollOutcome::StillActive);
        }
        runtime
            .semantic_states
            .insert(subject_id.to_owned(), state);
        Ok(WaitPollOutcome::Resolved(state))
    })
}

const fn should_prefetch_infer_now(runtime: &RuntimeState) -> bool {
    runtime.infer_ms > 0 && runtime.infer_max_rows > 1 && !runtime.allow_refresh
}
