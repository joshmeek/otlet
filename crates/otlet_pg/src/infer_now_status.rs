pub(crate) fn status_json() -> JsonB {
    let state = INFER_NOW_STATE.share();
    let mut requested_slots = 0usize;
    let mut running_slots = 0usize;
    let mut completed_slots = 0usize;
    let mut failed_slots = 0usize;
    let mut available_slots = 0usize;
    let mut active_slot = -1i32;
    let mut last_slot = InferNowSlot::default();
    for (index, slot) in state.slots.iter().enumerate() {
        match slot.state {
            STATE_REQUESTED => {
                requested_slots += 1;
                if active_slot < 0 {
                    active_slot = i32::try_from(index).unwrap_or(-1);
                }
            }
            STATE_RUNNING => {
                running_slots += 1;
                if active_slot < 0 {
                    active_slot = i32::try_from(index).unwrap_or(-1);
                }
            }
            STATE_DONE => completed_slots += 1,
            STATE_FAILED => failed_slots += 1,
            STATE_IDLE => available_slots += 1,
            _ => {}
        }
        if slot.request_id > last_slot.request_id {
            last_slot = *slot;
        }
    }
    JsonB(json!({
        "state": infer_queue_state_label(requested_slots, running_slots, completed_slots, failed_slots),
        "request_id": state.next_request_id,
        "submitted": state.submitted,
        "started": state.started,
        "completed": state.completed,
        "failed": state.failed,
        "timeouts": state.timeouts,
        "abort_requests": state.abort_requests,
        "busy_rejections": state.busy_rejections,
        "last_job_id": state.last_job_id,
        "last_cancel_job_id": state.last_cancel_job_id,
        "last_elapsed_ms": state.last_elapsed_ms,
        "last_start_latency_ms": state.last_start_latency_ms,
        "last_worker_run_ms": state.last_worker_run_ms,
        "task_bytes": last_slot.task_len,
        "task_cap": TASK_CAP,
        "subject_bytes": last_slot.subject_len,
        "subject_cap": SUBJECT_CAP,
        "inline_task_bytes": last_slot.inline_task_len,
        "inline_task_cap": INLINE_TASK_CAP,
        "input_bytes": last_slot.input_len,
        "input_cap": INPUT_CAP,
        "error_cap": ERROR_CAP,
        "max_wait_ms": MAX_WAIT_MS,
        "slot_count": INFER_NOW_SLOTS,
        "requested_slots": requested_slots,
        "running_slots": running_slots,
        "done_slots": completed_slots,
        "failed_slots": failed_slots,
        "queue_depth": requested_slots + running_slots,
        "available_slots": available_slots,
        "active_slot": active_slot,
        "admission_policy": INFER_NOW_ADMISSION_POLICY,
        "cap_policy": "task_subject_inline_task_input_byte_caps_reject_before_queue_insert",
        "timeout_policy": "requester_fail_closed_job_cancel_requested_no_late_materialization",
        "cancellation_policy": "timeout_calls_cancel_job_then_linked_runtime_checks_cancel_requested",
        "mutation_policy": "otlet_tables_only_no_user_table_mutation",
        "error": read_buf(&last_slot.error, last_slot.error_len as usize),
    }))
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn pg_finfo_otlet_worker_infer_now() -> *const pg_sys::Pg_finfo_record {
    &raw const OTLET_WORKER_INFER_NOW_FINFO
}

#[pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn otlet_worker_infer_now(fcinfo: pg_sys::FunctionCallInfo) -> pg_sys::Datum {
    let task_name = unsafe { pgrx::pg_getarg::<String>(fcinfo, 0) }.unwrap_or_default();
    let subject_id = unsafe { pgrx::pg_getarg::<String>(fcinfo, 1) }.unwrap_or_default();
    let input =
        unsafe { pgrx::pg_getarg::<JsonB>(fcinfo, 2) }.map_or_else(|| json!({}), |json| json.0);
    let timeout_ms = unsafe { pgrx::pg_getarg::<i32>(fcinfo, 3) }
        .unwrap_or(10_000)
        .clamp(0, i32::try_from(MAX_WAIT_MS).unwrap_or(i32::MAX))
        .cast_unsigned();
    let model_name = unsafe { pgrx::pg_getarg::<String>(fcinfo, 4) };
    let instruction = unsafe { pgrx::pg_getarg::<String>(fcinfo, 5) }.unwrap_or_default();
    let output_schema = unsafe { pgrx::pg_getarg::<JsonB>(fcinfo, 6) }
        .map_or_else(|| json!({"type":"object"}), |json| json.0);
    let runtime_options =
        unsafe { pgrx::pg_getarg::<JsonB>(fcinfo, 7) }.map_or_else(|| json!({}), |json| json.0);

    let job = match model_name.as_deref().filter(|name| !name.is_empty()) {
        Some(model_name) => request_infer_now_with_inline_task(
            &task_name,
            &subject_id,
            model_name,
            &instruction,
            &output_schema,
            &runtime_options,
            &input,
            timeout_ms,
        ),
        None => request_infer_now(&task_name, &subject_id, &input, timeout_ms),
    };
    let job_id = match job {
        Ok(Some(job_id)) => job_id,
        Ok(None) => 0,
        Err(err) => {
            pgrx::error!("otlet infer-now request failed: {err}");
        }
    };
    job_id.into_datum().unwrap()
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn pg_finfo_otlet_worker_infer_now_state() -> *const pg_sys::Pg_finfo_record {
    &raw const OTLET_WORKER_INFER_NOW_STATE_FINFO
}

#[pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn otlet_worker_infer_now_state(
    _fcinfo: pg_sys::FunctionCallInfo,
) -> pg_sys::Datum {
    status_json().into_datum().unwrap()
}

