log "Checking review provenance"
abstention_review_receipt_id="$(psql_value <<'SQL'
SELECT min(receipt_id)
FROM otlet.review_queue
WHERE queue_kind = 'abstention_output'
  AND action_id IS NULL;
SQL
)"
[ -n "$abstention_review_receipt_id" ] || {
  echo "Expected an abstention output for review provenance" >&2
  exit 1
}

review_provenance_contract="$(psql_value \
  -v action_id="$merge_action_id" \
  -v receipt_id="$abstention_review_receipt_id" \
  -v operator_role="$permission_operator_role" <<'SQL'
BEGIN;
CREATE TEMP TABLE review_event_baseline AS
SELECT COALESCE(max(id), 0) AS max_id
FROM otlet.review_events;

UPDATE otlet.actions
SET status = 'proposed', approval_status = 'required', approved_at = NULL, error = NULL
WHERE id = :'action_id'::bigint;
SET LOCAL ROLE :operator_role;
SELECT count(*) AS calls
FROM otlet.approve_action(:'action_id'::bigint, 'provenance approve') \gset review_approve_
RESET ROLE;

UPDATE otlet.actions
SET status = 'proposed', approval_status = 'required', approved_at = NULL, error = NULL
WHERE id = :'action_id'::bigint;
SET LOCAL ROLE :operator_role;
SELECT count(*) AS calls
FROM otlet.reject_action(:'action_id'::bigint, 'rejected', 'provenance reject') \gset review_reject_
RESET ROLE;

UPDATE otlet.actions
SET status = 'proposed', approval_status = 'required', approved_at = NULL, error = NULL
WHERE id = :'action_id'::bigint;
SET LOCAL ROLE :operator_role;
SELECT count(*) AS calls
FROM otlet.defer_action(:'action_id'::bigint, 'provenance defer') \gset review_defer_
RESET ROLE;
CREATE TEMP TABLE review_defer_state AS
SELECT EXISTS (
  SELECT 1 FROM otlet.review_queue WHERE action_id = :'action_id'::bigint
) AS still_queued;

SET LOCAL ROLE :operator_role;
SELECT count(*) AS calls
FROM otlet.correct_action(
  :'action_id'::bigint,
  '{"match":"same_entity","confidence":"high","action_type":"merge_candidate"}'::jsonb,
  'provenance correct'
) \gset review_correct_
RESET ROLE;

SET LOCAL ROLE :operator_role;
SELECT count(*) AS calls
FROM otlet.abstain_review(:'receipt_id'::bigint, 'provenance abstain') \gset review_abstain_
RESET ROLE;

CREATE TEMP TABLE review_test_events AS
SELECT event.*
FROM otlet.review_events event
WHERE event.id > (SELECT max_id FROM review_event_baseline);

CREATE FUNCTION pg_temp.review_history_is_immutable(operation text)
RETURNS boolean
LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    IF operation = 'update' THEN
      UPDATE otlet.review_events
      SET reason = 'changed'
      WHERE id = (SELECT min(id) FROM review_test_events);
    ELSIF operation = 'delete' THEN
      DELETE FROM otlet.review_events
      WHERE id = (SELECT min(id) FROM review_test_events);
    ELSE
      TRUNCATE otlet.review_events;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM = 'otlet review event history is immutable';
  END;
  RETURN false;
END;
$function$;

CREATE TEMP TABLE review_immutability AS
SELECT
  pg_temp.review_history_is_immutable('update') AS update_immutable,
  pg_temp.review_history_is_immutable('delete') AS delete_immutable,
  pg_temp.review_history_is_immutable('truncate') AS truncate_immutable;

SELECT
  (SELECT count(*) = 5 FROM review_test_events)::text || '|' ||
  ((SELECT string_agg(outcome, ',' ORDER BY outcome) FROM review_test_events) =
    'abstain,approve,correct,defer,reject')::text || '|' ||
  (SELECT bool_and(
    reviewer_identity = session_user::text
    AND reviewer_role = :'operator_role'
  ) FROM review_test_events)::text || '|' ||
  (SELECT bool_and(
    receipt_id IS NOT NULL
    AND model_name <> ''
    AND model_artifact_hash <> ''
    AND prompt_hash IS NOT NULL
    AND output_schema_hash <> ''
    AND output_hash <> ''
    AND reviewed_at IS NOT NULL
  ) FROM review_test_events)::text || '|' ||
  (SELECT bool_and(source_freshness IN ('fresh', 'stale', 'unavailable')) FROM review_test_events)::text || '|' ||
  (SELECT count(DISTINCT reason) = 5 FROM review_test_events)::text || '|' ||
  (SELECT still_queued FROM review_defer_state)::text || '|' ||
  (NOT EXISTS (
    SELECT 1 FROM otlet.review_queue WHERE receipt_id = :'receipt_id'::bigint
  ))::text || '|' ||
  ((SELECT count(*) FROM otlet.audit_review_event_export audit
    WHERE audit.review_event_id IN (SELECT id FROM review_test_events)) = 5)::text || '|' ||
  (SELECT update_immutable AND delete_immutable AND truncate_immutable FROM review_immutability)::text || '|' ||
  (SELECT bool_and(position('reviewer' IN pg_get_function_arguments(function_oid)) = 0)
   FROM unnest(ARRAY[
     'otlet.approve_action(bigint,text)'::regprocedure::oid,
     'otlet.reject_action(bigint,text,text)'::regprocedure::oid,
     'otlet.correct_action(bigint,jsonb,text)'::regprocedure::oid,
     'otlet.defer_action(bigint,text)'::regprocedure::oid,
     'otlet.abstain_review(bigint,text)'::regprocedure::oid
   ]) function_oid)::text;
ROLLBACK;
SQL
)"
echo "review_provenance_contract=$review_provenance_contract"
[ "$review_provenance_contract" = "true|true|true|true|true|true|true|true|true|true|true" ] || {
  echo "Expected attributable immutable review provenance, got $review_provenance_contract" >&2
  exit 1
}

expect_permission_denied \
  "$permission_operator_role" \
  "INSERT INTO otlet.review_events DEFAULT VALUES" \
  "operator caller-supplied review provenance"
