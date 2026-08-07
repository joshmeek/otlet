use pgrx::{IntoDatum, JsonB, PgLwLock, pg_guard, pg_sys};
use serde_json::{Value, json};
use std::sync::atomic::{AtomicBool, Ordering};

const STATE_IDLE: u32 = 0;
const STATE_REQUESTED: u32 = 1;
const STATE_RUNNING: u32 = 2;
const STATE_DONE: u32 = 3;
const STATE_FAILED: u32 = 4;

const TASK_CAP: usize = 128;
const SUBJECT_CAP: usize = 256;
const WORKLOAD_REVISION_CAP: usize = 96;
const INLINE_TASK_CAP: usize = 12 * 1024;
const INPUT_CAP: usize = 8192;
const ERROR_CAP: usize = 512;
const MAX_WAIT_MS: u32 = 30_000;
const INFER_NOW_SLOTS: usize = 4;
const TIMEOUT_CANCEL_REASON: &str = "infer-now timeout requested job cancellation";
const ABORT_CANCEL_REASON: &str = "infer-now requester statement aborted";
const REQUESTER_GONE_CANCEL_REASON: &str = "infer-now requester backend exited";
pub(crate) const INFER_NOW_ADMISSION_POLICY: &str = "bounded_shared_memory_infer_queue_4_slots";

#[repr(C)]
#[derive(Clone, Copy)]
struct InferNowSlot {
    state: u32,
    timeout_cancel_pending: bool,
    completion_started: bool,
    customscan_origin: bool,
    request_id: u64,
    requester_pid: i32,
    last_job_id: i64,
    last_elapsed_ms: u64,
    requested_at: pg_sys::TimestampTz,
    started_at: pg_sys::TimestampTz,
    finished_at: pg_sys::TimestampTz,
    last_start_latency_ms: u64,
    last_worker_run_ms: u64,
    task_len: u32,
    subject_len: u32,
    workload_revision_len: u32,
    inline_task_len: u32,
    input_len: u32,
    error_len: u32,
    task: [u8; TASK_CAP],
    subject: [u8; SUBJECT_CAP],
    workload_revision: [u8; WORKLOAD_REVISION_CAP],
    inline_task: [u8; INLINE_TASK_CAP],
    input: [u8; INPUT_CAP],
    error: [u8; ERROR_CAP],
}

impl Default for InferNowSlot {
    fn default() -> Self {
        Self {
            state: STATE_IDLE,
            timeout_cancel_pending: false,
            completion_started: false,
            customscan_origin: false,
            request_id: 0,
            requester_pid: 0,
            last_job_id: 0,
            last_elapsed_ms: 0,
            requested_at: 0,
            started_at: 0,
            finished_at: 0,
            last_start_latency_ms: 0,
            last_worker_run_ms: 0,
            task_len: 0,
            subject_len: 0,
            workload_revision_len: 0,
            inline_task_len: 0,
            input_len: 0,
            error_len: 0,
            task: [0; TASK_CAP],
            subject: [0; SUBJECT_CAP],
            workload_revision: [0; WORKLOAD_REVISION_CAP],
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

static REQUEST_CALLBACKS_REGISTERED: AtomicBool = AtomicBool::new(false);

static OTLET_WORKER_INFER_NOW_FINFO: pg_sys::Pg_finfo_record =
    pg_sys::Pg_finfo_record { api_version: 1 };
static OTLET_WORKER_INFER_NOW_STATE_FINFO: pg_sys::Pg_finfo_record =
    pg_sys::Pg_finfo_record { api_version: 1 };

pub(crate) struct InferNowRequest {
    pub(crate) id: u64,
    pub(crate) customscan_origin: bool,
    pub(crate) task_name: String,
    pub(crate) subject_id: String,
    pub(crate) expected_workload_revision_hash: Option<String>,
    /// Raw slot JSON for create_task field extraction via `$n::jsonb`.
    pub(crate) inline_task_json: Option<String>,
    /// Canonical JSON text from the shared-memory slot (no parse/re-serialize).
    pub(crate) input_json: String,
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

pub(crate) struct FailedInferNow {
    pub(crate) job_id: i64,
    pub(crate) error: String,
}

fn failed_infer_now(slot: &InferNowSlot) -> FailedInferNow {
    FailedInferNow {
        job_id: slot.last_job_id,
        error: read_buf(&slot.error, slot.error_len as usize),
    }
}

struct DetachedInferNow {
    job_id: i64,
    newly_canceled: bool,
}

fn detach_running_requester(slot: &mut InferNowSlot, reason: &str) -> Option<DetachedInferNow> {
    slot.requester_pid = 0;
    if slot.state != STATE_RUNNING || slot.completion_started {
        return None;
    }
    let detached = DetachedInferNow {
        job_id: slot.last_job_id,
        newly_canceled: !slot.timeout_cancel_pending,
    };
    slot.timeout_cancel_pending = true;
    write_error(slot, reason);
    Some(detached)
}

pub(crate) struct OrphanedInferNow {
    pub(crate) request_id: u64,
    pub(crate) job_id: i64,
}

pub(crate) fn init_shared_memory() {
    pgrx::pg_shmem_init!(INFER_NOW_STATE);
}

pub(crate) fn recover_requests_after_worker_restart() -> Vec<OrphanedInferNow> {
    let mut state = INFER_NOW_STATE.exclusive();
    let mut orphaned = Vec::new();
    for slot in &mut state.slots {
        let requester_alive = requester_alive(slot.requester_pid);
        if slot.state == STATE_RUNNING {
            orphaned.push(OrphanedInferNow {
                request_id: slot.request_id,
                job_id: slot.last_job_id,
            });
        }
        let recovered_state = restart_recovery_state(slot.state, requester_alive);
        slot.state = recovered_state;
        slot.completion_started = false;
        if recovered_state == STATE_IDLE {
            slot.requester_pid = 0;
        }
    }
    orphaned
}

const fn restart_recovery_state(state: u32, requester_alive: bool) -> u32 {
    match state {
        STATE_REQUESTED if !requester_alive => STATE_IDLE,
        STATE_RUNNING => STATE_RUNNING,
        STATE_DONE | STATE_FAILED if !requester_alive => STATE_IDLE,
        _ => state,
    }
}

fn reap_dead_requester_slots() {
    let should_wake = {
        let mut state = INFER_NOW_STATE.exclusive();
        let mut abort_requests = 0_u64;
        let mut last_cancel_job_id = 0_i64;
        let mut should_wake = false;
        for slot in &mut state.slots {
            if slot.requester_pid <= 0 || requester_alive(slot.requester_pid) {
                continue;
            }
            match slot.state {
                STATE_REQUESTED | STATE_DONE | STATE_FAILED => {
                    slot.requester_pid = 0;
                    slot.state = STATE_IDLE;
                }
                STATE_RUNNING => {
                    if let Some(detached) =
                        detach_running_requester(slot, REQUESTER_GONE_CANCEL_REASON)
                    {
                        if detached.newly_canceled {
                            abort_requests = abort_requests.saturating_add(1);
                        }
                        last_cancel_job_id = last_cancel_job_id.max(detached.job_id);
                        should_wake = true;
                    }
                }
                _ => slot.requester_pid = 0,
            }
        }
        state.abort_requests = state.abort_requests.saturating_add(abort_requests);
        if last_cancel_job_id > 0 {
            state.last_cancel_job_id = last_cancel_job_id;
        }
        should_wake
    };
    if should_wake {
        crate::wake::signal_worker_latch_immediate();
    }
}

fn ensure_request_callbacks() {
    if !REQUEST_CALLBACKS_REGISTERED.swap(true, Ordering::SeqCst) {
        unsafe {
            pg_sys::RegisterXactCallback(Some(infer_now_xact_callback), std::ptr::null_mut());
            pg_sys::RegisterSubXactCallback(Some(infer_now_subxact_callback), std::ptr::null_mut());
        }
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn infer_now_xact_callback(
    event: pg_sys::XactEvent::Type,
    _arg: *mut std::ffi::c_void,
) {
    if matches!(
        event,
        pg_sys::XactEvent::XACT_EVENT_ABORT | pg_sys::XactEvent::XACT_EVENT_PARALLEL_ABORT
    ) {
        abandon_current_backend_requests(ABORT_CANCEL_REASON);
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn infer_now_subxact_callback(
    event: pg_sys::SubXactEvent::Type,
    _my_subid: pg_sys::SubTransactionId,
    _parent_subid: pg_sys::SubTransactionId,
    _arg: *mut std::ffi::c_void,
) {
    if event == pg_sys::SubXactEvent::SUBXACT_EVENT_ABORT_SUB {
        abandon_current_backend_requests(ABORT_CANCEL_REASON);
    }
}

fn abandon_current_backend_requests(reason: &str) {
    if abandon_requester_requests(unsafe { pg_sys::MyProcPid }, reason) {
        crate::wake::signal_worker_latch_immediate();
    }
}

fn abandon_requester_requests(requester_pid: i32, reason: &str) -> bool {
    if requester_pid <= 0 {
        return false;
    }
    let mut state = INFER_NOW_STATE.exclusive();
    let mut abort_requests = 0_u64;
    let mut last_cancel_job_id = 0_i64;
    let mut should_wake = false;
    for slot in &mut state.slots {
        if slot.requester_pid != requester_pid {
            continue;
        }
        match slot.state {
            STATE_REQUESTED => {
                slot.requester_pid = 0;
                slot.state = STATE_IDLE;
            }
            STATE_RUNNING => {
                if let Some(detached) = detach_running_requester(slot, reason) {
                    if detached.newly_canceled {
                        abort_requests = abort_requests.saturating_add(1);
                    }
                    last_cancel_job_id = last_cancel_job_id.max(detached.job_id);
                    should_wake = true;
                }
            }
            STATE_DONE | STATE_FAILED => {
                slot.requester_pid = 0;
                slot.state = STATE_IDLE;
            }
            _ => slot.requester_pid = 0,
        }
    }
    state.abort_requests = state.abort_requests.saturating_add(abort_requests);
    if last_cancel_job_id > 0 {
        state.last_cancel_job_id = last_cancel_job_id;
    }
    should_wake
}

pub(crate) fn take_request() -> Option<InferNowRequest> {
    reap_dead_requester_slots();
    let mut state = INFER_NOW_STATE.exclusive();
    let slot_index = state
        .slots
        .iter()
        .enumerate()
        .filter(|(_, slot)| slot.state == STATE_REQUESTED)
        .min_by_key(|(_, slot)| slot.request_id)
        .map(|(index, _)| index)?;

    let slot = &state.slots[slot_index];
    let id = slot.request_id;
    let customscan_origin = slot.customscan_origin;
    let task_name = read_buf(&slot.task, slot.task_len as usize);
    let subject_id = read_buf(&slot.subject, slot.subject_len as usize);
    let expected_workload_revision_hash =
        read_optional_buf(&slot.workload_revision, slot.workload_revision_len as usize);
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
        customscan_origin,
        task_name,
        subject_id,
        expected_workload_revision_hash,
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

pub(crate) fn try_begin_output_acceptance(job_id: i64) -> bool {
    let mut state = INFER_NOW_STATE.exclusive();
    let Some(slot_index) = state
        .slots
        .iter()
        .position(|slot| slot.state == STATE_RUNNING && slot.last_job_id == job_id && job_id > 0)
    else {
        return true;
    };
    if state.slots[slot_index].timeout_cancel_pending {
        return false;
    }
    if !requester_alive(state.slots[slot_index].requester_pid) {
        if let Some(detached) =
            detach_running_requester(&mut state.slots[slot_index], REQUESTER_GONE_CANCEL_REASON)
        {
            if detached.newly_canceled {
                state.abort_requests = state.abort_requests.saturating_add(1);
            }
            state.last_cancel_job_id = detached.job_id;
        }
        return false;
    }
    state.slots[slot_index].completion_started = true;
    true
}

pub(crate) fn persist_timeout_cancel(job_id: i64) -> Result<bool, String> {
    let reason = {
        let mut state = INFER_NOW_STATE.exclusive();
        let Some(slot_index) = state.slots.iter().position(|slot| {
            slot.state == STATE_RUNNING && slot.last_job_id == job_id && job_id > 0
        }) else {
            return Ok(false);
        };
        if !state.slots[slot_index].timeout_cancel_pending
            && !state.slots[slot_index].completion_started
            && !requester_alive(state.slots[slot_index].requester_pid)
        {
            if let Some(detached) =
                detach_running_requester(&mut state.slots[slot_index], REQUESTER_GONE_CANCEL_REASON)
            {
                if detached.newly_canceled {
                    state.abort_requests = state.abort_requests.saturating_add(1);
                }
                state.last_cancel_job_id = detached.job_id;
            }
        }
        timeout_cancel_matches(
            state.slots[slot_index].timeout_cancel_pending,
            state.slots[slot_index].last_job_id,
            job_id,
        )
        .then(|| {
            let slot = &state.slots[slot_index];
            let reason = read_buf(&slot.error, slot.error_len as usize);
            if reason.is_empty() {
                TIMEOUT_CANCEL_REASON.to_owned()
            } else {
                reason
            }
        })
    };
    let Some(reason) = reason else {
        return Ok(false);
    };

    let result: pgrx::spi::Result<Option<String>> =
        pgrx::bgworkers::BackgroundWorker::transaction(|| {
            pgrx::Spi::connect_mut(|client| {
                let args = [job_id.into(), reason.as_str().into()];
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

pub(crate) fn resolve_orphaned_request(job_id: i64) -> Result<bool, String> {
    let result: pgrx::spi::Result<Option<String>> =
        pgrx::bgworkers::BackgroundWorker::transaction(|| {
            pgrx::Spi::connect(|client| {
                client
                    .select(
                        "SELECT status FROM otlet.jobs WHERE id = $1",
                        Some(1),
                        &[job_id.into()],
                    )?
                    .first()
                    .get::<String>(1)
            })
        });

    match result {
        Ok(status) => classify_orphaned_request_status(job_id, status.as_deref()),
        Err(err) => Err(format!("infer-now restart recovery failed: {err}")),
    }
}

fn classify_orphaned_request_status(job_id: i64, status: Option<&str>) -> Result<bool, String> {
    match status {
        Some("complete") => Ok(true),
        Some("failed" | "canceled") | None => Ok(false),
        Some(status) => Err(format!(
            "infer-now restart recovery reached status {status} for job_id={job_id}"
        )),
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
        if slot.requester_pid == 0 || !requester_alive(slot.requester_pid) {
            slot.state = STATE_IDLE;
            slot.requester_pid = 0;
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
