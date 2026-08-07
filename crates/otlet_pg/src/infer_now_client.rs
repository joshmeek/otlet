pub(crate) fn request_infer_now(
    task_name: &str,
    subject_id: &str,
    input: &Value,
    timeout_ms: u32,
) -> Result<Option<i64>, String> {
    let Some(submitted) = submit_infer_now(task_name, subject_id, input)? else {
        return Ok(None);
    };
    crate::wake::signal_worker_latch_immediate();
    Ok(wait_for_submitted_infer_now(&submitted, timeout_ms)?.map(|completed| completed.job_id))
}

#[allow(clippy::too_many_arguments)]
fn request_infer_now_with_inline_task(
    task_name: &str,
    subject_id: &str,
    model_name: &str,
    instruction: &str,
    output_schema: &Value,
    runtime_options: &Value,
    input: &Value,
    timeout_ms: u32,
) -> Result<Option<i64>, String> {
    let Some(submitted) = submit_infer_now_with_inline_task(
        task_name,
        subject_id,
        model_name,
        instruction,
        output_schema,
        runtime_options,
        input,
    )?
    else {
        return Ok(None);
    };
    crate::wake::signal_worker_latch_immediate();
    Ok(wait_for_submitted_infer_now(&submitted, timeout_ms)?.map(|completed| completed.job_id))
}

pub(crate) fn submit_infer_now(
    task_name: &str,
    subject_id: &str,
    input: &Value,
) -> Result<Option<SubmittedInferNow>, String> {
    let input_text = serde_json::to_string(input).map_err(|err| err.to_string())?;
    submit_infer_now_text(task_name, subject_id, None, None, &input_text, false)
}

pub(crate) fn submit_infer_now_bytes(
    task_name: &str,
    subject_id: &str,
    expected_workload_revision_hash: &str,
    input_json: &[u8],
) -> Result<Option<SubmittedInferNow>, String> {
    let input_text = std::str::from_utf8(input_json)
        .map_err(|err| format!("infer-now input is not valid UTF-8: {err}"))?;
    submit_infer_now_text(
        task_name,
        subject_id,
        Some(expected_workload_revision_hash),
        None,
        input_text,
        true,
    )
}

fn submit_infer_now_with_inline_task(
    task_name: &str,
    subject_id: &str,
    model_name: &str,
    instruction: &str,
    output_schema: &Value,
    runtime_options: &Value,
    input: &Value,
) -> Result<Option<SubmittedInferNow>, String> {
    let mut source_fields = input
        .as_object()
        .ok_or_else(|| "infer-now input must be a JSON object".to_owned())?
        .keys()
        .cloned()
        .collect::<Vec<_>>();
    source_fields.sort();
    let inline_task_text = serde_json::to_string(&json!({
        "model_name": model_name,
        "instruction": instruction,
        "output_schema": output_schema,
        "runtime_options": runtime_options,
        "input_shaping": {"source_fields": source_fields}
    }))
    .map_err(|err| err.to_string())?;
    let input_text = serde_json::to_string(input).map_err(|err| err.to_string())?;
    submit_infer_now_text(
        task_name,
        subject_id,
        None,
        Some(&inline_task_text),
        &input_text,
        false,
    )
}

fn submit_infer_now_text(
    task_name: &str,
    subject_id: &str,
    expected_workload_revision_hash: Option<&str>,
    inline_task_text: Option<&str>,
    input_text: &str,
    customscan_origin: bool,
) -> Result<Option<SubmittedInferNow>, String> {
    ensure_request_callbacks();
    reap_dead_requester_slots();
    check_len("task_name", task_name.len(), TASK_CAP)?;
    check_len("subject_id", subject_id.len(), SUBJECT_CAP)?;
    if let Some(hash) = expected_workload_revision_hash {
        check_len("workload_revision_hash", hash.len(), WORKLOAD_REVISION_CAP)?;
    }
    if let Some(inline_task_text) = inline_task_text {
        check_len("inline_task", inline_task_text.len(), INLINE_TASK_CAP)?;
    }
    check_len("input", input_text.len(), INPUT_CAP)?;

    let request_id = {
        let mut state = INFER_NOW_STATE.exclusive();
        let Some(slot_index) = state.slots.iter().position(|slot| slot.state == STATE_IDLE) else {
            state.busy_rejections = state.busy_rejections.saturating_add(1);
            return Ok(None);
        };

        state.next_request_id = state.next_request_id.saturating_add(1);
        let request_id = state.next_request_id;
        state.submitted = state.submitted.saturating_add(1);
        state.last_job_id = 0;
        state.last_start_latency_ms = 0;
        state.last_worker_run_ms = 0;
        let slot = &mut state.slots[slot_index];
        slot.request_id = request_id;
        slot.state = STATE_REQUESTED;
        slot.timeout_cancel_pending = false;
        slot.completion_started = false;
        slot.customscan_origin = customscan_origin;
        slot.requester_pid = unsafe { pg_sys::MyProcPid };
        slot.last_job_id = 0;
        slot.last_elapsed_ms = 0;
        slot.requested_at = unsafe { pg_sys::GetCurrentTimestamp() };
        slot.started_at = 0;
        slot.finished_at = 0;
        slot.last_start_latency_ms = 0;
        slot.last_worker_run_ms = 0;
        slot.error_len = 0;
        slot.task_len = write_buf(&mut slot.task, task_name.as_bytes());
        slot.subject_len = write_buf(&mut slot.subject, subject_id.as_bytes());
        slot.workload_revision_len = if let Some(hash) = expected_workload_revision_hash {
            write_buf(&mut slot.workload_revision, hash.as_bytes())
        } else {
            slot.workload_revision.fill(0);
            0
        };
        slot.inline_task_len = if let Some(text) = inline_task_text {
            write_buf(&mut slot.inline_task, text.as_bytes())
        } else {
            slot.inline_task.fill(0);
            0
        };
        slot.input_len = write_buf(&mut slot.input, input_text.as_bytes());
        request_id
    };

    Ok(Some(SubmittedInferNow { request_id }))
}

pub(crate) fn wait_for_submitted_infer_now(
    submitted: &SubmittedInferNow,
    timeout_ms: u32,
) -> Result<Option<CompletedInferNow>, String> {
    wait_for_submitted_infer_now_detailed(submitted, timeout_ms)
        .map_err(|failure| failure.error)
}

pub(crate) fn wait_for_submitted_infer_now_detailed(
    submitted: &SubmittedInferNow,
    timeout_ms: u32,
) -> Result<Option<CompletedInferNow>, FailedInferNow> {
    wait_for_request(submitted.request_id, timeout_ms.min(MAX_WAIT_MS))
}

pub(crate) fn signal_infer_now_worker() {
    crate::wake::signal_worker_latch_immediate();
}

fn wait_for_request(
    request_id: u64,
    timeout_ms: u32,
) -> Result<Option<CompletedInferNow>, FailedInferNow> {
    let completed_normally = std::cell::Cell::new(false);
    pgrx::PgTryBuilder::new(std::panic::AssertUnwindSafe(|| {
        let result = wait_for_request_inner(request_id, timeout_ms);
        completed_normally.set(true);
        result
    }))
    .finally(|| {
        if !completed_normally.get() {
            abandon_current_backend_requests(ABORT_CANCEL_REASON);
        }
    })
    .execute()
}

fn wait_for_request_inner(
    request_id: u64,
    timeout_ms: u32,
) -> Result<Option<CompletedInferNow>, FailedInferNow> {
    let start = unsafe { pg_sys::GetCurrentTimestamp() };
    loop {
        unsafe {
            pg_sys::ProcessInterrupts();
        }
        {
            let mut state = INFER_NOW_STATE.exclusive();
            if let Some(slot_index) = state
                .slots
                .iter()
                .position(|slot| slot.request_id == request_id)
            {
                match state.slots[slot_index].state {
                    STATE_DONE => {
                        let elapsed = elapsed_ms(start);
                        let completed = CompletedInferNow {
                            job_id: state.slots[slot_index].last_job_id,
                        };
                        {
                            let slot = &mut state.slots[slot_index];
                            slot.last_elapsed_ms = elapsed;
                            slot.state = STATE_IDLE;
                            slot.requester_pid = 0;
                        }
                        state.last_elapsed_ms = elapsed;
                        return Ok(Some(completed));
                    }
                    STATE_FAILED => {
                        let failed = failed_infer_now(&state.slots[slot_index]);
                        let elapsed = elapsed_ms(start);
                        {
                            let slot = &mut state.slots[slot_index];
                            slot.last_elapsed_ms = elapsed;
                            slot.state = STATE_IDLE;
                            slot.requester_pid = 0;
                        }
                        state.last_elapsed_ms = elapsed;
                        return Err(failed);
                    }
                    _ => {}
                }
            }
        }

        if unsafe {
            pg_sys::TimestampDifferenceExceeds(
                start,
                pg_sys::GetCurrentTimestamp(),
                std::ffi::c_int::try_from(timeout_ms).unwrap_or(std::ffi::c_int::MAX),
            )
        } {
            let mut terminal_result = None;
            {
                let mut state = INFER_NOW_STATE.exclusive();
                if let Some(slot_index) = state
                    .slots
                    .iter()
                    .position(|slot| slot.request_id == request_id)
                {
                    match state.slots[slot_index].state {
                        STATE_DONE => {
                            terminal_result = Some(Ok(Some(CompletedInferNow {
                                job_id: state.slots[slot_index].last_job_id,
                            })));
                            state.slots[slot_index].state = STATE_IDLE;
                            state.slots[slot_index].requester_pid = 0;
                        }
                        STATE_FAILED => {
                            terminal_result =
                                Some(Err(failed_infer_now(&state.slots[slot_index])));
                            state.slots[slot_index].state = STATE_IDLE;
                            state.slots[slot_index].requester_pid = 0;
                        }
                        STATE_REQUESTED => {
                            state.slots[slot_index].state = STATE_IDLE;
                            state.slots[slot_index].requester_pid = 0;
                        }
                        STATE_RUNNING => {
                            if let Some(detached) = detach_running_requester(
                                &mut state.slots[slot_index],
                                TIMEOUT_CANCEL_REASON,
                            ) {
                                if detached.newly_canceled {
                                    state.abort_requests =
                                        state.abort_requests.saturating_add(1);
                                }
                                if detached.job_id > 0 {
                                    state.last_cancel_job_id = detached.job_id;
                                }
                            }
                        }
                        _ => {}
                    }
                    if terminal_result.is_none() {
                        state.timeouts = state.timeouts.saturating_add(1);
                        let elapsed = elapsed_ms(start);
                        state.last_elapsed_ms = elapsed;
                        state.slots[slot_index].last_elapsed_ms = elapsed;
                    }
                }
            }
            if let Some(result) = terminal_result {
                return result;
            }
            crate::wake::signal_worker_latch_immediate();
            return Ok(None);
        }

        unsafe {
            pg_sys::WaitLatch(
                pg_sys::MyLatch,
                i32::try_from(
                    pg_sys::WL_LATCH_SET | pg_sys::WL_TIMEOUT | pg_sys::WL_POSTMASTER_DEATH,
                )
                .unwrap_or(i32::MAX),
                50,
                pg_sys::PG_WAIT_EXTENSION,
            );
            pg_sys::ResetLatch(pg_sys::MyLatch);
        }
    }
}

fn signal_requester_latch(slot: &InferNowSlot) {
    let requester = unsafe { pg_sys::BackendPidGetProc(slot.requester_pid) };
    if !requester.is_null() {
        unsafe { pg_sys::SetLatch(&raw mut (*requester).procLatch) };
    }
}

fn requester_alive(requester_pid: i32) -> bool {
    requester_pid > 0 && !unsafe { pg_sys::BackendPidGetProc(requester_pid) }.is_null()
}

fn write_buf(target: &mut [u8], value: &[u8]) -> u32 {
    target.fill(0);
    target[..value.len()].copy_from_slice(value);
    u32::try_from(value.len()).unwrap_or(u32::MAX)
}

fn read_buf(source: &[u8], len: usize) -> String {
    String::from_utf8_lossy(&source[..len.min(source.len())]).into_owned()
}

fn read_optional_buf(source: &[u8], len: usize) -> Option<String> {
    (len > 0).then(|| read_buf(source, len))
}

fn write_error(slot: &mut InferNowSlot, error: &str) {
    let bytes = error.as_bytes();
    let len = bytes.len().min(ERROR_CAP);
    slot.error.fill(0);
    slot.error[..len].copy_from_slice(&bytes[..len]);
    slot.error_len = u32::try_from(len).unwrap_or(u32::MAX);
}

fn check_len(label: &str, len: usize, cap: usize) -> Result<(), String> {
    if len > cap {
        Err(format!("infer-now {label} exceeds {cap} byte cap"))
    } else {
        Ok(())
    }
}

fn elapsed_ms(start: pg_sys::TimestampTz) -> u64 {
    let now = unsafe { pg_sys::GetCurrentTimestamp() };
    elapsed_between_ms(start, now)
}

fn elapsed_between_ms(start: pg_sys::TimestampTz, end: pg_sys::TimestampTz) -> u64 {
    if start == 0 || end == 0 {
        return 0;
    }
    unsafe { pg_sys::TimestampDifferenceMilliseconds(start, end) }
        .max(0)
        .cast_unsigned()
}

const fn infer_queue_state_label(
    requested_slots: usize,
    running_slots: usize,
    completed_slots: usize,
    failed_slots: usize,
) -> &'static str {
    if running_slots > 0 {
        "running"
    } else if requested_slots > 0 {
        "requested"
    } else if failed_slots > 0 {
        "failed"
    } else if completed_slots > 0 {
        "done"
    } else {
        "idle"
    }
}

#[cfg(test)]
mod tests {
    use super::{
        InferNowSlot, STATE_DONE, STATE_FAILED, STATE_IDLE, STATE_REQUESTED, STATE_RUNNING,
        classify_orphaned_request_status, failed_infer_now, restart_recovery_state,
        timeout_cancel_matches, write_error,
    };

    #[test]
    fn timeout_cancel_matches_only_the_recorded_job() {
        assert!(timeout_cancel_matches(true, 42, 42));
        assert!(!timeout_cancel_matches(true, 42, 41));
        assert!(!timeout_cancel_matches(false, 42, 42));
        assert!(!timeout_cancel_matches(true, 0, 0));
    }

    #[test]
    fn restart_keeps_started_requests_for_fail_closed_recovery() {
        assert_eq!(restart_recovery_state(STATE_RUNNING, true), STATE_RUNNING);
        assert_eq!(restart_recovery_state(STATE_RUNNING, false), STATE_RUNNING);
        assert_eq!(restart_recovery_state(STATE_REQUESTED, false), STATE_IDLE);
        assert_eq!(restart_recovery_state(STATE_REQUESTED, true), STATE_REQUESTED);
        assert_eq!(restart_recovery_state(STATE_DONE, false), STATE_IDLE);
        assert_eq!(restart_recovery_state(STATE_FAILED, false), STATE_IDLE);
        assert_eq!(restart_recovery_state(STATE_DONE, true), STATE_DONE);
    }

    #[test]
    fn missing_orphaned_jobs_fail_delivery_without_retrying_recovery() {
        assert!(!classify_orphaned_request_status(41, None).unwrap());
        assert!(!classify_orphaned_request_status(41, Some("canceled")).unwrap());
        assert!(classify_orphaned_request_status(41, Some("complete")).unwrap());
        assert!(classify_orphaned_request_status(41, Some("running")).is_err());
    }

    #[test]
    fn failures_keep_their_slot_job_identity() {
        let mut first = InferNowSlot {
            state: STATE_FAILED,
            last_job_id: 41,
            ..InferNowSlot::default()
        };
        let mut second = InferNowSlot {
            state: STATE_FAILED,
            last_job_id: 42,
            ..InferNowSlot::default()
        };
        write_error(&mut first, "first failure");
        write_error(&mut second, "second failure");

        let first_failure = failed_infer_now(&first);
        let second_failure = failed_infer_now(&second);
        assert_eq!((first_failure.job_id, first_failure.error.as_str()), (41, "first failure"));
        assert_eq!(
            (second_failure.job_id, second_failure.error.as_str()),
            (42, "second failure")
        );
    }
}
