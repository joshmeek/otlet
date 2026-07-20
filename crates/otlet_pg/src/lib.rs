#![recursion_limit = "256"]

pgrx::pg_module_magic!();

mod custom_scan;
mod infer_now;
mod job;
mod model;
mod runtime;
mod wake;
mod worker;

pgrx::extension_sql_file!("../sql/010_core_schema.sql", name = "schema", bootstrap);
pgrx::extension_sql_file!(
    "../sql/020_identity_contract.sql",
    name = "identity_contract",
    requires = ["schema"]
);
pgrx::extension_sql_file!(
    "../sql/030_action_schema.sql",
    name = "action_schema",
    requires = ["identity_contract"]
);
pgrx::extension_sql_file!(
    "../sql/040_semantic_schema.sql",
    name = "semantic_schema",
    requires = ["action_schema"]
);
pgrx::extension_sql_file!(
    "../sql/050_runtime_models.sql",
    name = "runtime_models",
    requires = ["semantic_schema"]
);
pgrx::extension_sql_file!(
    "../sql/060_tasks_scan.sql",
    name = "tasks_scan",
    requires = ["runtime_models"]
);
pgrx::extension_sql_file!(
    "../sql/070_runtime_health.sql",
    name = "runtime_health",
    requires = ["tasks_scan"]
);
pgrx::extension_sql_file!(
    "../sql/080_job_claims.sql",
    name = "job_claims",
    requires = ["runtime_health"]
);
pgrx::extension_sql_file!(
    "../sql/090_job_attempts.sql",
    name = "job_attempts",
    requires = ["job_claims"]
);
pgrx::extension_sql_file!(
    "../sql/100_job_cancellation.sql",
    name = "job_cancellation",
    requires = ["job_attempts"]
);
pgrx::extension_sql_file!(
    "../sql/110_job_terminal_recovery.sql",
    name = "job_terminal_recovery",
    requires = ["job_cancellation"]
);
pgrx::extension_sql_file!(
    "../sql/120_action_contract.sql",
    name = "action_contract",
    requires = ["job_terminal_recovery"]
);
pgrx::extension_sql_file!(
    "../sql/130_action_completion_review.sql",
    name = "action_completion_review",
    requires = ["action_contract"]
);
pgrx::extension_sql_file!(
    "../sql/140_action_execution.sql",
    name = "action_execution",
    requires = ["action_completion_review"]
);
pgrx::extension_sql_file!(
    "../sql/150_eval_labels.sql",
    name = "eval_labels",
    requires = ["action_execution"]
);
pgrx::extension_sql_file!(
    "../sql/160_action_review_status.sql",
    name = "action_review_status",
    requires = ["eval_labels"]
);
pgrx::extension_sql_file!(
    "../sql/170_inference_receipt_status.sql",
    name = "inference_receipt_status",
    requires = ["action_review_status"]
);
pgrx::extension_sql_file!(
    "../sql/180_runtime_cache_status.sql",
    name = "runtime_cache_status",
    requires = ["inference_receipt_status"]
);
pgrx::extension_sql_file!(
    "../sql/190_trace_tokens.sql",
    name = "trace_tokens",
    requires = ["runtime_cache_status"]
);
pgrx::extension_sql_file!(
    "../sql/200_trace_visibility.sql",
    name = "trace_visibility",
    requires = ["trace_tokens"]
);
pgrx::extension_sql_file!(
    "../sql/210_runtime_status.sql",
    name = "runtime_status",
    requires = ["trace_visibility"]
);
pgrx::extension_sql_file!(
    "../sql/220_semantic_stale.sql",
    name = "semantic_stale",
    requires = ["runtime_status"]
);
pgrx::extension_sql_file!(
    "../sql/230_semantic_index_admin.sql",
    name = "semantic_index_admin",
    requires = ["semantic_stale"]
);
pgrx::extension_sql_file!(
    "../sql/240_semantic_materialization.sql",
    name = "semantic_materialization",
    requires = ["semantic_index_admin"]
);
pgrx::extension_sql_file!(
    "../sql/250_semantic_reads.sql",
    name = "semantic_reads",
    requires = ["semantic_materialization"]
);
pgrx::extension_sql_file!(
    "../sql/260_semantic_join_core.sql",
    name = "semantic_join_core",
    requires = ["semantic_reads"]
);
pgrx::extension_sql_file!(
    "../sql/270_semantic_join_reads.sql",
    name = "semantic_join_reads",
    requires = ["semantic_join_core"]
);
pgrx::extension_sql_file!(
    "../sql/280_semantic_cost.sql",
    name = "semantic_cost",
    requires = ["semantic_join_reads"]
);
pgrx::extension_sql_file!(
    "../sql/290_semantic_join_plan.sql",
    name = "semantic_join_plan",
    requires = ["semantic_cost"]
);
pgrx::extension_sql_file!(
    "../sql/300_semantic_predicates.sql",
    name = "semantic_predicates",
    requires = ["semantic_join_plan"]
);
pgrx::extension_sql_file!(
    "../sql/310_semantic_status_plan.sql",
    name = "semantic_status_plan",
    requires = ["semantic_predicates"]
);
pgrx::extension_sql_file!(
    "../sql/320_queue_policy_status.sql",
    name = "queue_policy_status",
    requires = ["semantic_status_plan"]
);
pgrx::extension_sql_file!(
    "../sql/330_invariants.sql",
    name = "invariants",
    requires = ["queue_policy_status"]
);
pgrx::extension_sql_file!(
    "../sql/340_production_status.sql",
    name = "production_status",
    requires = ["invariants"]
);
pgrx::extension_sql_file!(
    "../sql/350_cleanup_policy.sql",
    name = "cleanup_policy",
    requires = ["production_status"]
);
pgrx::extension_sql_file!(
    "../sql/360_watch_lifecycle.sql",
    name = "watch_lifecycle",
    requires = ["cleanup_policy"]
);
pgrx::extension_sql_file!(
    "../sql/370_watch_portability_status.sql",
    name = "watch_portability_status",
    requires = ["watch_lifecycle"]
);
pgrx::extension_sql_file!(
    "../sql/380_audit_export.sql",
    name = "audit_export",
    requires = ["watch_portability_status"]
);
pgrx::extension_sql_file!(
    "../sql/390_permissions.sql",
    name = "permissions",
    requires = ["audit_export"]
);

#[allow(non_snake_case)]
#[pgrx::pg_guard]
pub extern "C-unwind" fn _PG_init() {
    custom_scan::init();

    // Static workers only register during shared preload, not ordinary SQL library loads
    if unsafe { !pgrx::pg_sys::process_shared_preload_libraries_in_progress } {
        return;
    }

    wake::init_shared_memory();
    infer_now::init_shared_memory();

    for _ in 0..otlet_worker_count() {
        pgrx::bgworkers::BackgroundWorkerBuilder::new("otlet worker")
            .set_function("otlet_worker_main")
            .set_library("otlet")
            .set_restart_time(Some(std::time::Duration::from_secs(2)))
            .enable_spi_access()
            .load();
    }
}

fn otlet_worker_count() -> usize {
    std::env::var("OTLET_WORKER_COUNT")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|count| *count > 0)
        .unwrap_or(1)
        .min(wake::WORKER_LATCH_SLOTS)
}
