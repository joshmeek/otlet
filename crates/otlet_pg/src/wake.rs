use pgrx::{IntoDatum, JsonB, PgLwLock, pg_guard, pg_sys};
use serde_json::json;
use std::sync::atomic::{AtomicBool, Ordering};

pub(crate) const MISSED_WAKE_RECOVERY_MS: u64 = 5_000;
const WORKER_LATCH_SLOTS: usize = 4;

#[derive(Copy, Clone, Default)]
#[repr(C)]
pub(crate) struct WakeState {
    worker_latch: usize,
    worker_pid: i32,
    worker_latches: [usize; WORKER_LATCH_SLOTS],
    worker_pids: [i32; WORKER_LATCH_SLOTS],
    worker_registrations: u64,
    wake_requests: u64,
    wake_commits: u64,
    wake_successes: u64,
    wake_misses: u64,
    wake_aborts: u64,
    worker_wake_cycles: u64,
    worker_empty_wake_cycles: u64,
    worker_jobs_drained: u64,
    worker_last_drain_count: u64,
    worker_max_drain_count: u64,
}

unsafe impl pgrx::PGRXSharedMemory for WakeState {}

pub(crate) static WAKE_STATE: PgLwLock<WakeState> = unsafe { PgLwLock::new(c"otlet wake state") };

static XACT_CALLBACK_REGISTERED: AtomicBool = AtomicBool::new(false);
static PENDING_WAKE: AtomicBool = AtomicBool::new(false);

static OTLET_WAKE_WORKER_FINFO: pg_sys::Pg_finfo_record =
    pg_sys::Pg_finfo_record { api_version: 1 };
static OTLET_WORKER_WAKE_STATE_FINFO: pg_sys::Pg_finfo_record =
    pg_sys::Pg_finfo_record { api_version: 1 };

pub(crate) fn init_shared_memory() {
    pgrx::pg_shmem_init!(WAKE_STATE);
}

pub(crate) fn register_worker_latch() {
    let mut state = WAKE_STATE.exclusive();
    state.worker_latch = unsafe { pg_sys::MyLatch as usize };
    state.worker_pid = unsafe { pg_sys::MyProcPid };
    if let Some(index) = state
        .worker_pids
        .iter()
        .position(|pid| *pid == state.worker_pid)
        .or_else(|| state.worker_latches.iter().position(|latch| *latch == 0))
    {
        state.worker_latches[index] = state.worker_latch;
        state.worker_pids[index] = state.worker_pid;
    }
    state.worker_registrations = state.worker_registrations.saturating_add(1);
}

pub(crate) fn unregister_worker_latch() {
    let mut state = WAKE_STATE.exclusive();
    let pid = unsafe { pg_sys::MyProcPid };
    for index in 0..WORKER_LATCH_SLOTS {
        if state.worker_pids[index] == pid {
            state.worker_latches[index] = 0;
            state.worker_pids[index] = 0;
        }
    }
    state.worker_latch = state
        .worker_latches
        .iter()
        .copied()
        .find(|latch| *latch != 0)
        .unwrap_or(0);
    state.worker_pid = state
        .worker_pids
        .iter()
        .copied()
        .find(|worker_pid| *worker_pid != 0)
        .unwrap_or(0);
}

pub(crate) fn record_worker_drain(drained: u64) {
    let mut state = WAKE_STATE.exclusive();
    state.worker_wake_cycles = state.worker_wake_cycles.saturating_add(1);
    state.worker_jobs_drained = state.worker_jobs_drained.saturating_add(drained);
    state.worker_last_drain_count = drained;
    state.worker_max_drain_count = state.worker_max_drain_count.max(drained);
    if drained == 0 {
        state.worker_empty_wake_cycles = state.worker_empty_wake_cycles.saturating_add(1);
    }
}

pub(crate) fn signal_worker_latch_immediate() -> bool {
    let mut state = WAKE_STATE.exclusive();
    state.wake_requests = state.wake_requests.saturating_add(1);
    if !signal_registered_workers(&state) {
        state.wake_misses = state.wake_misses.saturating_add(1);
        return false;
    }
    state.wake_successes = state.wake_successes.saturating_add(1);
    true
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn pg_finfo_otlet_wake_worker() -> *const pg_sys::Pg_finfo_record {
    &OTLET_WAKE_WORKER_FINFO
}

#[pgrx::pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn otlet_wake_worker(_fcinfo: pg_sys::FunctionCallInfo) -> pg_sys::Datum {
    let worker_known = mark_wake_pending();
    worker_known.into_datum().unwrap()
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn pg_finfo_otlet_worker_wake_state() -> *const pg_sys::Pg_finfo_record {
    &OTLET_WORKER_WAKE_STATE_FINFO
}

#[pgrx::pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn otlet_worker_wake_state(
    _fcinfo: pg_sys::FunctionCallInfo,
) -> pg_sys::Datum {
    let state = WAKE_STATE.share();
    JsonB(json!({
        "handoff": "shared_memory_xact_commit_latch",
        "worker_latch_registered": state.worker_latch != 0,
        "worker_pid": state.worker_pid,
        "worker_pids": state.worker_pids.iter().copied().filter(|pid| *pid != 0).collect::<Vec<_>>(),
        "registered_workers": state.worker_latches.iter().filter(|latch| **latch != 0).count(),
        "worker_registrations": state.worker_registrations,
        "worker_lifecycle_policy": "clear_latch_on_clean_stop_and_reregister_on_postmaster_restart",
        "wake_requests": state.wake_requests,
        "wake_commits": state.wake_commits,
        "wake_successes": state.wake_successes,
        "wake_misses": state.wake_misses,
        "wake_aborts": state.wake_aborts,
        "missed_wake_recovery_ms": MISSED_WAKE_RECOVERY_MS,
        "worker_wake_cycles": state.worker_wake_cycles,
        "worker_empty_wake_cycles": state.worker_empty_wake_cycles,
        "worker_jobs_drained": state.worker_jobs_drained,
        "worker_last_drain_count": state.worker_last_drain_count,
        "worker_max_drain_count": state.worker_max_drain_count,
    }))
    .into_datum()
    .unwrap()
}

fn mark_wake_pending() -> bool {
    ensure_xact_callback();
    PENDING_WAKE.store(true, Ordering::SeqCst);

    let mut state = WAKE_STATE.exclusive();
    state.wake_requests = state.wake_requests.saturating_add(1);
    state.worker_latches.iter().any(|latch| *latch != 0)
}

fn ensure_xact_callback() {
    if !XACT_CALLBACK_REGISTERED.swap(true, Ordering::SeqCst) {
        unsafe {
            pg_sys::RegisterXactCallback(Some(otlet_wake_xact_callback), std::ptr::null_mut());
        }
    }
}

#[pgrx::pg_guard]
unsafe extern "C-unwind" fn otlet_wake_xact_callback(
    event: pg_sys::XactEvent::Type,
    _arg: *mut std::ffi::c_void,
) {
    let pending = match event {
        pg_sys::XactEvent::XACT_EVENT_COMMIT | pg_sys::XactEvent::XACT_EVENT_PARALLEL_COMMIT => {
            PENDING_WAKE.swap(false, Ordering::SeqCst)
        }
        pg_sys::XactEvent::XACT_EVENT_ABORT | pg_sys::XactEvent::XACT_EVENT_PARALLEL_ABORT => {
            PENDING_WAKE.swap(false, Ordering::SeqCst)
        }
        _ => false,
    };

    if !pending {
        return;
    }

    let mut state = WAKE_STATE.exclusive();
    match event {
        pg_sys::XactEvent::XACT_EVENT_COMMIT | pg_sys::XactEvent::XACT_EVENT_PARALLEL_COMMIT => {
            state.wake_commits = state.wake_commits.saturating_add(1);
            if !signal_registered_workers(&state) {
                state.wake_misses = state.wake_misses.saturating_add(1);
                return;
            }
            state.wake_successes = state.wake_successes.saturating_add(1);
        }
        pg_sys::XactEvent::XACT_EVENT_ABORT | pg_sys::XactEvent::XACT_EVENT_PARALLEL_ABORT => {
            state.wake_aborts = state.wake_aborts.saturating_add(1);
        }
        _ => {}
    }
}

fn signal_registered_workers(state: &WakeState) -> bool {
    let mut signaled = false;
    for latch in state
        .worker_latches
        .iter()
        .copied()
        .filter(|latch| *latch != 0)
    {
        unsafe {
            pg_sys::SetLatch(latch as *mut pg_sys::Latch);
        }
        signaled = true;
    }
    signaled
}
