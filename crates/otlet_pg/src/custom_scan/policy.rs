fn wait_elapsed_ms(start: pg_sys::TimestampTz) -> u64 {
    let now = unsafe { pg_sys::GetCurrentTimestamp() };
    let elapsed = unsafe { pg_sys::TimestampDifferenceMilliseconds(start, now) };
    elapsed.max(0) as u64
}

fn refresh_policy_from_parts(
    auto_policy: bool,
    allow_refresh: bool,
    wait_ms: u32,
    infer_ms: u32,
) -> &'static str {
    if auto_policy {
        "auto_lookup_wait_infer_refresh_fail_closed"
    } else if allow_refresh {
        "queue_refresh_and_fail_closed"
    } else if infer_ms > 0 {
        "infer_now_bounded"
    } else if wait_ms > 0 {
        "wait_for_inflight_refresh"
    } else {
        "fail_closed_no_refresh"
    }
}

fn worker_handoff_from_parts(
    auto_policy: bool,
    allow_refresh: bool,
    wait_ms: u32,
    infer_ms: u32,
) -> &'static str {
    if auto_policy {
        "auto_resident_worker_wait_infer_or_commit_latch"
    } else if infer_ms > 0 {
        "shared_memory_immediate_latch_resident_worker_infer_now"
    } else if allow_refresh {
        "shared_memory_xact_commit_latch_targeted_refresh"
    } else if wait_ms > 0 {
        "bounded_latest_snapshot_wait_for_active_refresh"
    } else {
        "none_for_fail_closed_lookup"
    }
}

fn infer_now_input_path(infer_ms: u32) -> &'static str {
    if infer_ms == 0 {
        "none"
    } else {
        "tuple_slot_mvcc_json_no_spi"
    }
}

fn semantic_policy_for_selected_path(selected_path: &str) -> SemanticAutoPolicy {
    match selected_path {
        "bounded_infer_now" | "wait_for_refresh" | "queue_refresh" | "fresh_inference_scan"
        | "fresh_pair_inference" => semantic_auto_policy(true),
        _ => semantic_auto_policy(false),
    }
}

fn source_tuple_provider(runtime: &RuntimeState) -> &'static str {
    if !runtime.child_plan.is_null() && is_semantic_join_runtime(runtime) {
        "child_subquery_join_execprocnode"
    } else if !runtime.child_plan.is_null() {
        "child_plan_execprocnode"
    } else {
        "child_plan_required_no_table_beginscan_fallback"
    }
}

fn is_semantic_join_runtime(runtime: &RuntimeState) -> bool {
    runtime.index_kind == SemanticIndexKind::Join
        || runtime.source_table.starts_with("otlet.semantic_join:")
}

fn runtime_index_kind_text(runtime: &RuntimeState) -> &'static str {
    if is_semantic_join_runtime(runtime) {
        "join"
    } else {
        runtime.index_kind.as_str()
    }
}

unsafe fn source_tuple_provider_from_state(
    state: *mut OtletSemanticCustomScanState,
) -> &'static str {
    unsafe {
        if !state.is_null() && (*state).child_plan_rows > 0 {
            "child_plan_execprocnode"
        } else {
            "not_started"
        }
    }
}

fn estimated_model_cost_ms(infer_ms: u32, infer_max_rows: u32) -> u64 {
    (infer_ms as u64).saturating_mul(infer_max_rows as u64)
}

fn with_latest_snapshot<T>(f: impl FnOnce() -> T) -> T {
    struct SnapshotGuard;

    impl Drop for SnapshotGuard {
        fn drop(&mut self) {
            unsafe {
                pg_sys::PopActiveSnapshot();
            }
        }
    }

    unsafe {
        pg_sys::PushActiveSnapshot(pg_sys::GetLatestSnapshot());
    }
    let _guard = SnapshotGuard;
    f()
}
