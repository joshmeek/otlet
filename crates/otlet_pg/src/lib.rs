#![recursion_limit = "256"]

pgrx::pg_module_magic!();

mod custom_scan;
mod infer_now;
mod job;
mod model;
mod runtime;
mod wake;
mod worker;

pgrx::extension_sql_file!(
    "../sql/migrations/0001_core_schema.sql",
    name = "schema",
    bootstrap
);
pgrx::extension_sql_file!(
    "../sql/migrations/0002_identity_contract.sql",
    name = "identity_contract",
    requires = ["schema"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0044_source_query_contract.sql",
    name = "source_query_contract",
    requires = ["identity_contract"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0003_action_schema.sql",
    name = "action_schema",
    requires = ["source_query_contract"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0004_semantic_schema.sql",
    name = "semantic_schema",
    requires = ["action_schema"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0005_runtime_models.sql",
    name = "runtime_models",
    requires = ["semantic_schema"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0006_tasks_scan.sql",
    name = "tasks_scan",
    requires = ["runtime_models"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0007_runtime_health.sql",
    name = "runtime_health",
    requires = ["tasks_scan"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0008_job_claims.sql",
    name = "job_claims",
    requires = ["runtime_health"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0009_portable_schema.sql",
    name = "portable_schema",
    requires = ["job_claims"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0010_job_attempts.sql",
    name = "job_attempts",
    requires = ["portable_schema"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0011_job_cancellation.sql",
    name = "job_cancellation",
    requires = ["job_attempts"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0012_job_terminal_recovery.sql",
    name = "job_terminal_recovery",
    requires = ["job_cancellation"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0013_action_contract.sql",
    name = "action_contract",
    requires = ["job_terminal_recovery"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0014_portable_result_validation.sql",
    name = "portable_result_validation",
    requires = ["action_contract"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0015_action_completion_review.sql",
    name = "action_completion_review",
    requires = ["portable_result_validation"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0016_portable_worker_protocol.sql",
    name = "portable_worker_protocol",
    requires = ["action_completion_review"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0017_action_execution.sql",
    name = "action_execution",
    requires = ["portable_worker_protocol"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0018_eval_labels.sql",
    name = "eval_labels",
    requires = ["action_execution"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0019_action_review_status.sql",
    name = "action_review_status",
    requires = ["eval_labels"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0020_inference_receipt_status.sql",
    name = "inference_receipt_status",
    requires = ["action_review_status"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0021_runtime_cache_status.sql",
    name = "runtime_cache_status",
    requires = ["inference_receipt_status"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0022_trace_tokens.sql",
    name = "trace_tokens",
    requires = ["runtime_cache_status"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0023_trace_visibility.sql",
    name = "trace_visibility",
    requires = ["trace_tokens"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0024_runtime_status.sql",
    name = "runtime_status",
    requires = ["trace_visibility"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0025_semantic_stale.sql",
    name = "semantic_stale",
    requires = ["runtime_status"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0026_semantic_index_admin.sql",
    name = "semantic_index_admin",
    requires = ["semantic_stale"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0027_semantic_materialization.sql",
    name = "semantic_materialization",
    requires = ["semantic_index_admin"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0028_semantic_reads.sql",
    name = "semantic_reads",
    requires = ["semantic_materialization"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0029_semantic_join_core.sql",
    name = "semantic_join_core",
    requires = ["semantic_reads"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0030_semantic_join_reads.sql",
    name = "semantic_join_reads",
    requires = ["semantic_join_core"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0031_semantic_cost.sql",
    name = "semantic_cost",
    requires = ["semantic_join_reads"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0032_semantic_join_plan.sql",
    name = "semantic_join_plan",
    requires = ["semantic_cost"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0033_semantic_predicates.sql",
    name = "semantic_predicates",
    requires = ["semantic_join_plan"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0034_semantic_status_plan.sql",
    name = "semantic_status_plan",
    requires = ["semantic_predicates"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0045_watch_reconciliation.sql",
    name = "watch_reconciliation",
    requires = ["semantic_status_plan"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0035_queue_policy_status.sql",
    name = "queue_policy_status",
    requires = ["watch_reconciliation"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0036_invariants.sql",
    name = "invariants",
    requires = ["queue_policy_status"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0037_production_status.sql",
    name = "production_status",
    requires = ["invariants"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0038_cleanup_policy.sql",
    name = "cleanup_policy",
    requires = ["production_status"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0039_watch_lifecycle.sql",
    name = "watch_lifecycle",
    requires = ["cleanup_policy"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0040_watch_portability_status.sql",
    name = "watch_portability_status",
    requires = ["watch_lifecycle"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0041_audit_export.sql",
    name = "audit_export",
    requires = ["watch_portability_status"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0042_portable_permissions.sql",
    name = "portable_permissions",
    requires = ["audit_export"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0046_definition_complexity.sql",
    name = "definition_complexity",
    requires = ["portable_permissions"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0047_runtime_capabilities.sql",
    name = "runtime_capabilities",
    requires = ["definition_complexity"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0048_application_invocation.sql",
    name = "application_invocation",
    requires = ["runtime_capabilities"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0049_invocation_provenance.sql",
    name = "invocation_provenance",
    requires = ["application_invocation"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0050_task_watch_operational_lifecycle.sql",
    name = "task_watch_operational_lifecycle",
    requires = ["invocation_provenance"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0051_administrative_change_ledger.sql",
    name = "administrative_change_ledger",
    requires = ["task_watch_operational_lifecycle"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0052_workload_acceptance_contract.sql",
    name = "workload_acceptance_contract",
    requires = ["administrative_change_ledger"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0053_replayable_evaluation.sql",
    name = "replayable_evaluation",
    requires = ["workload_acceptance_contract"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0054_evaluation_population_lineage.sql",
    name = "evaluation_population_lineage",
    requires = ["replayable_evaluation"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0055_evaluation_slices_support.sql",
    name = "evaluation_slices_support",
    requires = ["evaluation_population_lineage"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0056_label_provenance_quality.sql",
    name = "label_provenance_quality",
    requires = ["evaluation_slices_support"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0057_production_model_qualification.sql",
    name = "production_model_qualification",
    requires = ["label_provenance_quality"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0058_promotion_shadow_rollback.sql",
    name = "promotion_shadow_rollback",
    requires = ["production_model_qualification"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0059_quality_data_drift.sql",
    name = "quality_data_drift",
    requires = ["promotion_shadow_rollback"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0060_review_economics.sql",
    name = "review_economics",
    requires = ["quality_data_drift"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0061_model_license_use_policy.sql",
    name = "model_license_use_policy",
    requires = ["review_economics"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0062_model_artifact_lifecycle.sql",
    name = "model_artifact_lifecycle",
    requires = ["model_license_use_policy"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0043_permissions.sql",
    name = "permissions",
    requires = ["model_artifact_lifecycle"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0063_failure_retry_taxonomy.sql",
    name = "failure_retry_taxonomy",
    requires = ["permissions"]
);
pgrx::extension_sql_file!(
    "../sql/migrations/0064_candidate_set_coverage.sql",
    name = "candidate_set_coverage",
    requires = ["failure_retry_taxonomy"]
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
