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
    submit_infer_now_text(task_name, subject_id, None, &input_text)
}

pub(crate) fn submit_infer_now_bytes(
    task_name: &str,
    subject_id: &str,
    input_json: &[u8],
) -> Result<Option<SubmittedInferNow>, String> {
    let input_text = std::str::from_utf8(input_json)
        .map_err(|err| format!("infer-now input is not valid UTF-8: {err}"))?;
    submit_infer_now_text(task_name, subject_id, None, input_text)
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
    let inline_task_text = serde_json::to_string(&json!({
        "model_name": model_name,
        "instruction": instruction,
        "output_schema": output_schema,
        "runtime_options": runtime_options
    }))
    .map_err(|err| err.to_string())?;
    let input_text = serde_json::to_string(input).map_err(|err| err.to_string())?;
    submit_infer_now_text(task_name, subject_id, Some(&inline_task_text), &input_text)
}

fn submit_infer_now_text(
    task_name: &str,
    subject_id: &str,
    inline_task_text: Option<&str>,
    input_text: &str,
) -> Result<Option<SubmittedInferNow>, String> {
    check_len("task_name", task_name.len(), TASK_CAP)?;
    check_len("subject_id", subject_id.len(), SUBJECT_CAP)?;
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
        slot.requester_latch = unsafe { pg_sys::MyLatch as usize };
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
    wait_for_request(submitted.request_id, timeout_ms.min(MAX_WAIT_MS))
}

pub(crate) fn signal_infer_now_worker() {
    crate::wake::signal_worker_latch_immediate();
}

fn wait_for_request(request_id: u64, timeout_ms: u32) -> Result<Option<CompletedInferNow>, String> {
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
                            slot.requester_latch = 0;
                        }
                        state.last_elapsed_ms = elapsed;
                        return Ok(Some(completed));
                    }
                    STATE_FAILED => {
                        let error = read_buf(
                            &state.slots[slot_index].error,
                            state.slots[slot_index].error_len as usize,
                        );
                        let elapsed = elapsed_ms(start);
                        {
                            let slot = &mut state.slots[slot_index];
                            slot.last_elapsed_ms = elapsed;
                            slot.state = STATE_IDLE;
                            slot.requester_latch = 0;
                        }
                        state.last_elapsed_ms = elapsed;
                        return Err(error);
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
            let mut cancel_job_id = 0;
            {
                let mut state = INFER_NOW_STATE.exclusive();
                if let Some(slot_index) = state
                    .slots
                    .iter()
                    .position(|slot| slot.request_id == request_id)
                {
                    state.timeouts = state.timeouts.saturating_add(1);
                    let elapsed = elapsed_ms(start);
                    state.last_elapsed_ms = elapsed;
                    {
                        let slot = &mut state.slots[slot_index];
                        slot.last_elapsed_ms = elapsed;
                        slot.requester_latch = 0;
                    }
                    if state.slots[slot_index].state == STATE_REQUESTED {
                        state.slots[slot_index].state = STATE_IDLE;
                    } else if state.slots[slot_index].state == STATE_RUNNING
                        && state.slots[slot_index].last_job_id > 0
                    {
                        cancel_job_id = state.slots[slot_index].last_job_id;
                        state.abort_requests = state.abort_requests.saturating_add(1);
                        state.last_cancel_job_id = cancel_job_id;
                        state.slots[slot_index].timeout_cancel_pending = true;
                        write_error(&mut state.slots[slot_index], TIMEOUT_CANCEL_REASON);
                    }
                }
            }
            if cancel_job_id > 0
                && let Err(err) = cancel_job(cancel_job_id)
            {
                pgrx::warning!("otlet infer-now timeout cancel failed: {err}");
                force_cancel_requested(cancel_job_id, TIMEOUT_CANCEL_REASON);
            }
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

fn cancel_job(job_id: i64) -> Result<(), String> {
    pgrx::Spi::connect_mut(|client| {
        let args = [job_id.into(), TIMEOUT_CANCEL_REASON.into()];
        let table = client
            .select(
                "SELECT id FROM otlet.cancel_job($1, $2) LIMIT 1",
                Some(1),
                &args,
            )
            .map_err(|err| err.to_string())?;
        let canceled = table
            .first()
            .get::<i64>(1)
            .map_err(|err| err.to_string())?
            .is_some();
        if !canceled {
            return Err(format!("cancel_job affected no rows for job_id={job_id}"));
        }
        Ok(())
    })
}

fn force_cancel_requested(job_id: i64, reason: &str) {
    // Error-path only: when cancel_job SPI fails on infer-now timeout, still
    // mark cancel_requested so linked_cancel_requested can stop decode.
    let recovery: pgrx::spi::Result<()> = pgrx::Spi::connect_mut(|client| {
        let args = [job_id.into(), reason.into()];
        client.update(
            "UPDATE otlet.jobs \
             SET status = 'cancel_requested', \
                 error = $2, \
                 cancel_requested_at = COALESCE(cancel_requested_at, now()) \
             WHERE id = $1 AND status = 'running'",
            Some(1),
            &args,
        )?;
        Ok(())
    });
    if let Err(err) = recovery {
        pgrx::warning!("otlet infer-now force cancel_requested failed: {err}");
    }
}

fn signal_requester_latch(slot: &InferNowSlot) {
    if slot.requester_latch != 0 {
        unsafe {
            pg_sys::SetLatch(slot.requester_latch as *mut pg_sys::Latch);
        }
    }
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
    use super::timeout_cancel_matches;

    #[test]
    fn timeout_cancel_matches_only_the_recorded_job() {
        assert!(timeout_cancel_matches(true, 42, 42));
        assert!(!timeout_cancel_matches(true, 42, 41));
        assert!(!timeout_cancel_matches(false, 42, 42));
        assert!(!timeout_cancel_matches(true, 0, 0));
    }
}
