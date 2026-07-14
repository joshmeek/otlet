use pgrx::{IntoDatum, JsonB, PgLwLock, pg_guard, pg_sys};
use serde_json::{Value, json};

const STATE_IDLE: u32 = 0;
const STATE_REQUESTED: u32 = 1;
const STATE_RUNNING: u32 = 2;
const STATE_DONE: u32 = 3;
const STATE_FAILED: u32 = 4;

const TASK_CAP: usize = 128;
const SUBJECT_CAP: usize = 256;
const INLINE_TASK_CAP: usize = 12 * 1024;
const INPUT_CAP: usize = 8192;
const ERROR_CAP: usize = 512;
const MAX_WAIT_MS: u32 = 30_000;
const INFER_NOW_SLOTS: usize = 4;
const TIMEOUT_CANCEL_REASON: &str = "infer-now timeout requested job cancellation";
pub(crate) const INFER_NOW_ADMISSION_POLICY: &str = "bounded_shared_memory_infer_queue_4_slots";

#[repr(C)]
#[derive(Clone, Copy)]
struct InferNowSlot {
    state: u32,
    timeout_cancel_pending: bool,
    request_id: u64,
    requester_latch: usize,
    last_job_id: i64,
    last_elapsed_ms: u64,
    requested_at: pg_sys::TimestampTz,
    started_at: pg_sys::TimestampTz,
    finished_at: pg_sys::TimestampTz,
    last_start_latency_ms: u64,
    last_worker_run_ms: u64,
    task_len: u32,
    subject_len: u32,
    inline_task_len: u32,
    input_len: u32,
    error_len: u32,
    task: [u8; TASK_CAP],
    subject: [u8; SUBJECT_CAP],
    inline_task: [u8; INLINE_TASK_CAP],
    input: [u8; INPUT_CAP],
    error: [u8; ERROR_CAP],
}

impl Default for InferNowSlot {
    fn default() -> Self {
        Self {
            state: STATE_IDLE,
            timeout_cancel_pending: false,
            request_id: 0,
            requester_latch: 0,
            last_job_id: 0,
            last_elapsed_ms: 0,
            requested_at: 0,
            started_at: 0,
            finished_at: 0,
            last_start_latency_ms: 0,
            last_worker_run_ms: 0,
            task_len: 0,
            subject_len: 0,
            inline_task_len: 0,
            input_len: 0,
            error_len: 0,
            task: [0; TASK_CAP],
            subject: [0; SUBJECT_CAP],
            inline_task: [0; INLINE_TASK_CAP],
            input: [0; INPUT_CAP],
            error: [0; ERROR_CAP],
        }
    }
}

#[repr(C)]
pub(crate) struct InferNowState {
    next_request_id: u64,
    submitted: u64,
    started: u64,
    completed: u64,
    failed: u64,
    timeouts: u64,
    abort_requests: u64,
    busy_rejections: u64,
    last_job_id: i64,
    last_cancel_job_id: i64,
    last_elapsed_ms: u64,
    last_start_latency_ms: u64,
    last_worker_run_ms: u64,
    slots: [InferNowSlot; INFER_NOW_SLOTS],
}

impl Default for InferNowState {
    fn default() -> Self {
        Self {
            next_request_id: 0,
            submitted: 0,
            started: 0,
            completed: 0,
            failed: 0,
            timeouts: 0,
            abort_requests: 0,
            busy_rejections: 0,
            last_job_id: 0,
            last_cancel_job_id: 0,
            last_elapsed_ms: 0,
            last_start_latency_ms: 0,
            last_worker_run_ms: 0,
            slots: [InferNowSlot::default(); INFER_NOW_SLOTS],
        }
    }
}

unsafe impl pgrx::PGRXSharedMemory for InferNowState {}

pub(crate) static INFER_NOW_STATE: PgLwLock<InferNowState> =
    unsafe { PgLwLock::new(c"otlet infer now state") };

static OTLET_WORKER_INFER_NOW_FINFO: pg_sys::Pg_finfo_record =
    pg_sys::Pg_finfo_record { api_version: 1 };
static OTLET_WORKER_INFER_NOW_STATE_FINFO: pg_sys::Pg_finfo_record =
    pg_sys::Pg_finfo_record { api_version: 1 };

pub(crate) struct InferNowRequest {
    pub(crate) id: u64,
    pub(crate) task_name: String,
    pub(crate) subject_id: String,
    /// Raw slot JSON for create_task field extraction via `$n::jsonb`.
    pub(crate) inline_task_json: Option<String>,
    /// Canonical JSON text from the shared-memory slot (no parse/re-serialize).
    pub(crate) input_json: String,
}

#[derive(Clone, Copy)]
pub(crate) struct InferNowSnapshot {
    pub(crate) timeouts: u64,
    pub(crate) last_job_id: i64,
}

pub(crate) struct InferNowQueueSnapshot {
    pub(crate) slot_count: usize,
    pub(crate) requested_slots: usize,
    pub(crate) running_slots: usize,
    pub(crate) available_slots: usize,
    pub(crate) busy_rejections: u64,
}

pub(crate) struct SubmittedInferNow {
    pub(crate) request_id: u64,
}

pub(crate) struct CompletedInferNow {
    pub(crate) job_id: i64,
}

pub(crate) fn init_shared_memory() {
    pgrx::pg_shmem_init!(INFER_NOW_STATE);
}

pub(crate) fn take_request() -> Option<InferNowRequest> {
    let mut state = INFER_NOW_STATE.exclusive();
    let slot_index = state
        .slots
        .iter()
        .position(|slot| slot.state == STATE_REQUESTED)?;

    let slot = &state.slots[slot_index];
    let id = slot.request_id;
    let task_name = read_buf(&slot.task, slot.task_len as usize);
    let subject_id = read_buf(&slot.subject, slot.subject_len as usize);
    let inline_task_text = read_optional_buf(&slot.inline_task, slot.inline_task_len as usize);
    let input_text = read_buf(&slot.input, slot.input_len as usize);
    if let Some(text) = inline_task_text.as_deref()
        && let Err(err) = serde_json::from_str::<Value>(text)
    {
        {
            let slot = &mut state.slots[slot_index];
            slot.state = STATE_FAILED;
            write_error(
                slot,
                &format!("infer-now inline_task JSON parse failed: {err}"),
            );
        }
        state.failed = state.failed.saturating_add(1);
        signal_requester_latch(&state.slots[slot_index]);
        return None;
    }
    // Validate JSON once; keep the slot text for `$n::jsonb` (skip Value→JsonB).
    if let Err(err) = serde_json::from_str::<Value>(&input_text) {
        {
            let slot = &mut state.slots[slot_index];
            slot.state = STATE_FAILED;
            write_error(slot, &format!("infer-now input JSON parse failed: {err}"));
        }
        state.failed = state.failed.saturating_add(1);
        signal_requester_latch(&state.slots[slot_index]);
        return None;
    }

    let started_at = unsafe { pg_sys::GetCurrentTimestamp() };
    let start_latency_ms = {
        let slot = &mut state.slots[slot_index];
        slot.started_at = started_at;
        slot.last_start_latency_ms = elapsed_between_ms(slot.requested_at, started_at);
        slot.state = STATE_RUNNING;
        slot.last_start_latency_ms
    };
    state.last_start_latency_ms = start_latency_ms;
    state.started = state.started.saturating_add(1);
    Some(InferNowRequest {
        id,
        task_name,
        subject_id,
        inline_task_json: inline_task_text,
        input_json: input_text,
    })
}

pub(crate) fn mark_request_job_started(request_id: u64, job_id: i64) {
    let mut state = INFER_NOW_STATE.exclusive();
    if let Some(slot) = state.slots.iter_mut().find(|slot| {
        slot.request_id == request_id && matches!(slot.state, STATE_REQUESTED | STATE_RUNNING)
    }) {
        slot.last_job_id = job_id;
        state.last_job_id = job_id;
    }
}

pub(crate) fn snapshot() -> InferNowSnapshot {
    let state = INFER_NOW_STATE.share();
    InferNowSnapshot {
        timeouts: state.timeouts,
        last_job_id: state.last_job_id,
    }
}

pub(crate) fn persist_timeout_cancel(job_id: i64) -> Result<bool, String> {
    let requested = {
        let state = INFER_NOW_STATE.share();
        state.slots.iter().any(|slot| {
            timeout_cancel_matches(slot.timeout_cancel_pending, slot.last_job_id, job_id)
        })
    };
    if !requested {
        return Ok(false);
    }

    let result: pgrx::spi::Result<Option<String>> =
        pgrx::bgworkers::BackgroundWorker::transaction(|| {
            pgrx::Spi::connect_mut(|client| {
                let args = [job_id.into(), TIMEOUT_CANCEL_REASON.into()];
                let rows = client.select(
                    "SELECT status FROM otlet.cancel_job($1, $2) LIMIT 1",
                    Some(1),
                    &args,
                )?;
                rows.first().get::<String>(1)
            })
        });

    match result {
        Ok(Some(status)) if matches!(status.as_str(), "cancel_requested" | "canceled") => Ok(true),
        Ok(Some(status)) => Err(format!(
            "infer-now timeout cancel reached terminal status {status} for job_id={job_id}"
        )),
        Ok(None) => Err(format!(
            "infer-now timeout cancel affected no rows for job_id={job_id}"
        )),
        Err(err) => Err(format!("infer-now timeout cancel failed: {err}")),
    }
}

const fn timeout_cancel_matches(pending: bool, slot_job_id: i64, job_id: i64) -> bool {
    pending && job_id > 0 && slot_job_id == job_id
}

pub(crate) fn queue_snapshot() -> InferNowQueueSnapshot {
    let state = INFER_NOW_STATE.share();
    let mut requested_slots = 0usize;
    let mut running_slots = 0usize;
    let mut available_slots = 0usize;
    for slot in &state.slots {
        match slot.state {
            STATE_REQUESTED => requested_slots += 1,
            STATE_RUNNING => running_slots += 1,
            STATE_IDLE => available_slots += 1,
            _ => {}
        }
    }
    InferNowQueueSnapshot {
        slot_count: INFER_NOW_SLOTS,
        requested_slots,
        running_slots,
        available_slots,
        busy_rejections: state.busy_rejections,
    }
}

pub(crate) fn finish_request(request_id: u64, job_id: i64, error: Option<&str>) {
    let mut state = INFER_NOW_STATE.exclusive();
    let Some(slot_index) = state
        .slots
        .iter()
        .position(|slot| slot.request_id == request_id && slot.state == STATE_RUNNING)
    else {
        return;
    };

    let finished_at = unsafe { pg_sys::GetCurrentTimestamp() };
    let mut should_signal = false;
    let worker_run_ms = {
        let slot = &mut state.slots[slot_index];
        slot.finished_at = finished_at;
        slot.last_worker_run_ms = elapsed_between_ms(slot.started_at, finished_at);
        slot.last_job_id = job_id;
        if let Some(error) = error {
            slot.state = STATE_FAILED;
            write_error(slot, error);
        } else {
            slot.state = STATE_DONE;
            slot.error_len = 0;
        }
        if slot.requester_latch == 0 {
            slot.state = STATE_IDLE;
        } else {
            should_signal = true;
        }
        slot.last_worker_run_ms
    };
    state.last_job_id = job_id;
    state.last_worker_run_ms = worker_run_ms;
    if error.is_some() {
        state.failed = state.failed.saturating_add(1);
    } else {
        state.completed = state.completed.saturating_add(1);
    }
    if should_signal {
        signal_requester_latch(&state.slots[slot_index]);
    }
}

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
