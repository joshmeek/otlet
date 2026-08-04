SELECT to_regnamespace('otlet') IS NULL AS portable_apply_migration_0001 \gset
\if :portable_apply_migration_0001
\ir ../../otlet_pg/sql/migrations/0001_core_schema.sql

CREATE TABLE otlet.portable_schema_migrations (
  version integer PRIMARY KEY,
  file text NOT NULL UNIQUE,
  applied_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO otlet.portable_schema_migrations (version, file)
VALUES (1, '0001_core_schema.sql');
\else
DO $$
BEGIN
  IF to_regclass('otlet.portable_schema_migrations') IS NULL THEN
    RAISE EXCEPTION 'existing schema otlet is not a managed portable install';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM otlet.portable_schema_migrations
    WHERE version = 1
  ) THEN
    RAISE EXCEPTION 'existing schema otlet is not a managed portable install';
  END IF;
END;
$$;
\endif

\set portable_migration_file ../../../otlet_pg/sql/migrations/0002_identity_contract.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0044_source_query_contract.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0003_action_schema.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0004_semantic_schema.sql
\ir migrations/apply.sql

\set portable_migration_file 0005_runtime_models.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0006_tasks_scan.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0007_runtime_health.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0008_job_claims.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0009_portable_schema.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0010_job_attempts.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0011_job_cancellation.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0012_job_terminal_recovery.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0013_action_contract.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0014_portable_result_validation.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0015_action_completion_review.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0016_portable_worker_protocol.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0017_action_execution.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0018_eval_labels.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0019_action_review_status.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0020_inference_receipt_status.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0021_runtime_cache_status.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0022_trace_tokens.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0023_trace_visibility.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0024_runtime_status.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0025_semantic_stale.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0026_semantic_index_admin.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0027_semantic_materialization.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0028_semantic_reads.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0029_semantic_join_core.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0030_semantic_join_reads.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0031_semantic_cost.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0032_semantic_join_plan.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0033_semantic_predicates.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0034_semantic_status_plan.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0045_watch_reconciliation.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0035_queue_policy_status.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0036_invariants.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0037_production_status.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0038_cleanup_policy.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0039_watch_lifecycle.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0040_watch_portability_status.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0041_audit_export.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0042_portable_permissions.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0046_definition_complexity.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0047_runtime_capabilities.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0048_application_invocation.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0049_invocation_provenance.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0050_task_watch_operational_lifecycle.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0051_administrative_change_ledger.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0052_workload_acceptance_contract.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0053_replayable_evaluation.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0054_evaluation_population_lineage.sql
\ir migrations/apply.sql

\set portable_migration_file ../../../otlet_pg/sql/migrations/0055_evaluation_slices_support.sql
\ir migrations/apply.sql

\set portable_migration_file 0043_permissions.sql
\ir migrations/apply.sql
