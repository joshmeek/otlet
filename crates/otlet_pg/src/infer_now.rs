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
                    "SELECT status FROM otlet.request_job_cancellation($1, $2) LIMIT 1",
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

include!("infer_now_client.rs");
include!("infer_now_status.rs");
