fn wait_elapsed_ms(start: pg_sys::TimestampTz) -> u64 {
    let now = unsafe { pg_sys::GetCurrentTimestamp() };
    let elapsed = unsafe { pg_sys::TimestampDifferenceMilliseconds(start, now) };
    nonnegative_count(elapsed)
}

const fn refresh_policy_from_parts(
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

const fn worker_handoff_from_parts(
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

const fn infer_now_input_path(infer_ms: u32) -> &'static str {
    if infer_ms == 0 {
        "none"
    } else {
        "tuple_slot_mvcc_json_no_spi"
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

fn freeze_infer_now_executor_context_json(runtime: &RuntimeState) -> String {
    json!({
        "executor_origin": "customscan_infer_now",
        "executor_node": "Otlet Semantic Source CustomScan",
        "executor_boundary": "CustomScan owned Postgres-planned source child scan",
        "planner_selected_path": runtime.planner_selected_path,
        "source_tuple_provider": source_tuple_provider(runtime),
        "refresh_policy": refresh_policy_from_parts(
            runtime.auto_policy,
            runtime.allow_refresh,
            runtime.wait_ms,
            runtime.infer_ms,
        ),
        "semantic_index_kind": runtime.index_kind.as_str(),
        "semantic_index_name": runtime.index_name,
    })
    .to_string()
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
        // Match runtime source_tuple_provider: join by index_kind, else child
        // plan presence (not child_plan_rows, which stays 0 until first row /
        // forever on empty scans).
        if state.is_null() {
            "not_started"
        } else if (*state).index_kind == SemanticIndexKind::Join {
            "child_subquery_join_execprocnode"
        } else if (*state).has_child_plan
            || (*state).index_kind == SemanticIndexKind::Row
        {
            // Row CustomScan always requires a PG child plan at begin-scan;
            // report the provider before BeginCustomScan when index_kind is set.
            "child_plan_execprocnode"
        } else {
            "not_started"
        }
    }
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn estimated_model_cost_ms(model_ms: f64, infer_subjects: u64) -> u64 {
    if !model_ms.is_finite() || model_ms <= 0.0 {
        return 0;
    }
    let estimate = (model_ms * infer_subjects as f64).round();
    if estimate >= u64::MAX as f64 {
        u64::MAX
    } else {
        estimate as u64
    }
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
