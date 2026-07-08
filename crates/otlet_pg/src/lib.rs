#![recursion_limit = "256"]

pgrx::pg_module_magic!();

mod custom_scan;
mod infer_now;
mod job;
mod model;
mod runtime;
mod wake;
mod worker;

pgrx::extension_sql_file!("../sql/01_schema.sql", name = "schema", bootstrap);
pgrx::extension_sql_file!(
    "../sql/02_runtime_models.sql",
    name = "runtime_models",
    requires = ["schema"]
);
pgrx::extension_sql_file!(
    "../sql/03_tasks_scan.sql",
    name = "tasks_scan",
    requires = ["runtime_models"]
);
pgrx::extension_sql_file!(
    "../sql/04_runtime_health.sql",
    name = "runtime_health",
    requires = ["tasks_scan"]
);
pgrx::extension_sql_file!(
    "../sql/05_jobs_lifecycle.sql",
    name = "jobs_lifecycle",
    requires = ["runtime_health"]
);
pgrx::extension_sql_file!(
    "../sql/05_actions_review.sql",
    name = "actions_review",
    requires = ["jobs_lifecycle"]
);
pgrx::extension_sql_file!(
    "../sql/05_eval_labels.sql",
    name = "eval_labels",
    requires = ["actions_review"]
);
pgrx::extension_sql_file!(
    "../sql/06_receipt_trace_status.sql",
    name = "receipt_trace_status",
    requires = ["eval_labels"]
);
pgrx::extension_sql_file!(
    "../sql/07_trace_tokens.sql",
    name = "trace_tokens",
    requires = ["receipt_trace_status"]
);
pgrx::extension_sql_file!(
    "../sql/08_trace_visibility.sql",
    name = "trace_visibility",
    requires = ["trace_tokens"]
);
pgrx::extension_sql_file!(
    "../sql/09_runtime_status.sql",
    name = "runtime_status",
    requires = ["trace_visibility"]
);
pgrx::extension_sql_file!(
    "../sql/10_semantic_stale.sql",
    name = "semantic_stale",
    requires = ["runtime_status"]
);
pgrx::extension_sql_file!(
    "../sql/11_semantic_index.sql",
    name = "semantic_index",
    requires = ["semantic_stale"]
);
pgrx::extension_sql_file!(
    "../sql/12_semantic_join_core.sql",
    name = "semantic_join_core",
    requires = ["semantic_index"]
);
pgrx::extension_sql_file!(
    "../sql/13_semantic_join_plan.sql",
    name = "semantic_join_plan",
    requires = ["semantic_join_core"]
);
pgrx::extension_sql_file!(
    "../sql/17_semantic_predicates.sql",
    name = "semantic_predicates",
    requires = ["semantic_join_plan"]
);
pgrx::extension_sql_file!(
    "../sql/18_semantic_status_plan.sql",
    name = "semantic_status_plan",
    requires = ["semantic_predicates"]
);
pgrx::extension_sql_file!(
    "../sql/20_production_policy.sql",
    name = "production_policy",
    requires = ["semantic_status_plan"]
);
pgrx::extension_sql_file!(
    "../sql/21_watches.sql",
    name = "watches",
    requires = ["production_policy"]
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
