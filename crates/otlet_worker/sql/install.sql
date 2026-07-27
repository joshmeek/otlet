\set ON_ERROR_STOP on

BEGIN;
\ir ../../otlet_pg/sql/010_core_schema.sql
\ir ../../otlet_pg/sql/020_identity_contract.sql
\ir ../../otlet_pg/sql/030_action_schema.sql
\ir ../../otlet_pg/sql/040_semantic_schema.sql
\ir 050_runtime_models.sql
\ir ../../otlet_pg/sql/060_tasks_scan.sql
\ir ../../otlet_pg/sql/070_runtime_health.sql
\ir ../../otlet_pg/sql/080_job_claims.sql
\ir ../../otlet_pg/sql/085_portable_schema.sql
\ir ../../otlet_pg/sql/090_job_attempts.sql
\ir ../../otlet_pg/sql/100_job_cancellation.sql
\ir ../../otlet_pg/sql/110_job_terminal_recovery.sql
\ir ../../otlet_pg/sql/120_action_contract.sql
\ir ../../otlet_pg/sql/125_portable_result_validation.sql
\ir ../../otlet_pg/sql/130_action_completion_review.sql
\ir ../../otlet_pg/sql/135_portable_worker_protocol.sql
\ir ../../otlet_pg/sql/140_action_execution.sql
\ir ../../otlet_pg/sql/150_eval_labels.sql
\ir ../../otlet_pg/sql/160_action_review_status.sql
\ir ../../otlet_pg/sql/170_inference_receipt_status.sql
\ir ../../otlet_pg/sql/385_portable_permissions.sql
\ir permissions.sql
COMMIT;
