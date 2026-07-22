\set ON_ERROR_STOP on

BEGIN;
\ir ../crates/otlet_pg/sql/010_core_schema.sql
\ir ../crates/otlet_pg/sql/020_identity_contract.sql
\ir ../crates/otlet_pg/sql/030_action_schema.sql
\ir ../crates/otlet_pg/sql/040_semantic_schema.sql
\ir 050_runtime_models.sql
\ir ../crates/otlet_pg/sql/060_tasks_scan.sql
\ir ../crates/otlet_pg/sql/070_runtime_health.sql
\ir ../crates/otlet_pg/sql/075_database_health.sql
\ir ../crates/otlet_pg/sql/080_job_claims.sql
\ir ../crates/otlet_pg/sql/085_portable_schema.sql
\ir ../crates/otlet_pg/sql/090_job_attempts.sql
\ir ../crates/otlet_pg/sql/100_job_cancellation.sql
\ir ../crates/otlet_pg/sql/110_job_terminal_recovery.sql
\ir ../crates/otlet_pg/sql/120_action_contract.sql
\ir ../crates/otlet_pg/sql/125_portable_result_validation.sql
\ir ../crates/otlet_pg/sql/130_action_completion_review.sql
\ir ../crates/otlet_pg/sql/135_portable_worker_protocol.sql
\ir ../crates/otlet_pg/sql/140_action_execution.sql
\ir ../crates/otlet_pg/sql/150_eval_labels.sql
\ir ../crates/otlet_pg/sql/155_workload_evaluation.sql
\ir ../crates/otlet_pg/sql/160_action_review_status.sql
\ir ../crates/otlet_pg/sql/170_inference_receipt_status.sql
\ir ../crates/otlet_pg/sql/175_decision_exports.sql
\ir ../crates/otlet_pg/sql/385_portable_permissions.sql
\ir permissions.sql
COMMIT;
