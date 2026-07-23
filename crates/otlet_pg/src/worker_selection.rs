fn process_direct_job(job: &Job) -> JobProcessResult {
    if let Some(result) = guard_job_lease(job, job.model_name.as_str(), "direct") {
        return result;
    }
    match run_job(job) {
        Ok(run) => {
            let mut result = JobProcessResult::from_run(false, &run);
            if job
                .decision_contract
                .get("enforce_on_direct")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                let (accepted, _) =
                    accepted_by_direct_decision(&run.output, &job.decision_contract);
                if !accepted {
                    result.completed =
                        reject_direct_attempt(job, run, "direct_rejected_by_decision_contract");
                    if !result.completed {
                        result.failure_message =
                            Some("direct_rejected_by_decision_contract".to_owned());
                    }
                    return result;
                }
            }
            let (completed, semantic_materialized) = accept_attempt_with_model(
                job,
                job.model_name.as_str(),
                run,
                "direct",
                "accepted_by_direct_task",
            );
            result.completed = completed;
            result.semantic_materialized = semantic_materialized;
            if !result.completed {
                result.failure_message = Some("complete_job_produced_no_output".to_owned());
            }
            result
        }
        Err(err) => {
            let selection_reason = failure_selection_reason(&err, "direct_attempt_failed");
            fail_attempt_result_with_model(
                job,
                job.model_name.as_str(),
                &err,
                "direct",
                selection_reason,
            )
        }
    }
}

/// Same field defaults and accept rules as the former `direct_accept_field_checks`
/// + `accepted_by_policy` path, without allocating a temporary accept-checks object.
fn accepted_by_direct_decision(output: &Value, decision_contract: &Value) -> (bool, &'static str) {
    static DEFAULT_ABSTAIN: LazyLock<Value> = LazyLock::new(|| serde_json::json!(["unclear"]));
    static EMPTY_CONFIDENCE: LazyLock<Value> = LazyLock::new(|| serde_json::json!([]));

    // Defaults match the old json!({... unwrap_or ...}) materialization; empty
    // field names still skip checks via the same filters as accepted_by_policy.
    let confidence_field = decision_contract
        .get("confidence_field")
        .and_then(Value::as_str)
        .unwrap_or("confidence");
    if !confidence_field.is_empty() {
        let Some(confidence) = output.get(confidence_field).and_then(Value::as_str) else {
            return (false, "missing_confidence_field");
        };
        let accepted_confidence = decision_contract
            .get("accepted_confidence")
            .unwrap_or(&EMPTY_CONFIDENCE);
        if !value_string_array_allows(accepted_confidence, confidence) {
            return (false, "confidence_below_policy");
        }
    }

    let answer_field = decision_contract
        .get("answer_field")
        .and_then(Value::as_str)
        .unwrap_or("match");
    if answer_field.is_empty() {
        return (true, "accepted_by_policy");
    }
    let Some(answer) = output.get(answer_field).and_then(Value::as_str) else {
        return (false, "missing_decision_field");
    };
    let abstain_values = decision_contract
        .get("abstain_values")
        .unwrap_or(&DEFAULT_ABSTAIN);
    if value_string_array_contains(abstain_values, answer) {
        return (false, "abstained_output");
    }

    (true, "accepted_by_policy")
}

fn value_string_array_allows(items: &Value, expected: &str) -> bool {
    let Some(items) = items.as_array() else {
        return true;
    };
    let mut has_strings = false;
    for item in items.iter().filter_map(Value::as_str) {
        has_strings = true;
        if item == expected {
            return true;
        }
    }
    !has_strings
}

fn value_string_array_contains(items: &Value, expected: &str) -> bool {
    items.as_array().is_some_and(|items| {
        items
            .iter()
            .filter_map(Value::as_str)
            .any(|item| item == expected)
    })
}

fn process_selected_job(job: &Job, policy: &ModelSelectionPolicy) -> JobProcessResult {
    // Run cheap model without cloning the full Job; SPI helpers take model_name.
    let cheap_name = policy.cheap.name.as_str();
    if let Some(result) = guard_job_lease(job, cheap_name, "cheap") {
        return result;
    }
    match run_job_with_model(job, &policy.cheap) {
        Ok(run) => {
            let (accepted, reason) = accepted_by_policy(&run.output, &policy.accept_field_checks);
            if accepted {
                let mut result = JobProcessResult::from_run(false, &run);
                let (completed, semantic_materialized) =
                    accept_attempt_with_model(job, cheap_name, run, "cheap", reason);
                result.completed = completed;
                result.semantic_materialized = semantic_materialized;
                if !result.completed {
                    result.failure_message = Some("complete_job_produced_no_output".to_owned());
                }
                return result;
            }
            let mut result = JobProcessResult::from_run(false, &run);
            if !record_rejected_attempt_with_model(job, cheap_name, run, "cheap", reason) {
                let err = ModelError::new("rejected_attempt_receipt_failed");
                return fail_attempt_result_with_model(
                    job,
                    cheap_name,
                    &err,
                    "cheap",
                    "rejected_receipt_failed",
                );
            }
            result.strong_fallback = Some("escalated_after_cheap_rejection");
            result
        }
        Err(err) if err.message == "canceled" => {
            fail_attempt_result_with_model(job, cheap_name, &err, "cheap", "canceled")
        }
        Err(err) if err.raw_output.is_some() => {
            let mut result = JobProcessResult::from_error(false, &err);
            if !record_failed_model_attempt_with_model(
                job,
                cheap_name,
                &err,
                "cheap",
                "schema_validation_failed",
            ) {
                return fail_attempt_result_with_model(
                    job,
                    cheap_name,
                    &err,
                    "cheap",
                    "failed_attempt_receipt_failed",
                );
            }
            result.strong_fallback = Some("escalated_after_cheap_schema_failure");
            result
        }
        Err(err) => {
            let selection_reason = failure_selection_reason(&err, "cheap_runtime_failed");
            fail_attempt_result_with_model(job, cheap_name, &err, "cheap", selection_reason)
        }
    }
}

fn run_strong_attempt_with_model(
    job: &Job,
    strong: &crate::job::JobModel,
    reason: &str,
) -> JobProcessResult {
    if let Some(result) = guard_job_lease(job, strong.name.as_str(), "strong") {
        return result;
    }
    match run_job_with_model(job, strong) {
        Ok(run) => {
            let mut result = JobProcessResult::from_run(false, &run);
            let (completed, semantic_materialized) =
                accept_attempt_with_model(job, strong.name.as_str(), run, "strong", reason);
            result.completed = completed;
            result.semantic_materialized = semantic_materialized;
            if !result.completed {
                result.failure_message = Some("complete_job_produced_no_output".to_owned());
            }
            result
        }
        Err(err) => {
            let selection_reason = failure_selection_reason(&err, "strong_attempt_failed");
            fail_attempt_result_with_model(
                job,
                strong.name.as_str(),
                &err,
                "strong",
                selection_reason,
            )
        }
    }
}

fn guard_job_lease(job: &Job, model_name: &str, selection_role: &str) -> Option<JobProcessResult> {
    match renew_job_lease(job) {
        Ok(false) => None,
        Ok(true) => {
            let err = ModelError::new("canceled");
            Some(fail_attempt_result_with_model(
                job,
                model_name,
                &err,
                selection_role,
                "canceled",
            ))
        }
        Err(message) => {
            pgrx::warning!(
                "otlet worker skipped job {} after lease fence failure: {}",
                job.id,
                message
            );
            let err = ModelError::new(message);
            Some(JobProcessResult::failed_with(&err))
        }
    }
}

fn renew_job_lease(job: &Job) -> Result<bool, String> {
    let result: pgrx::spi::Result<Option<bool>> = BackgroundWorker::transaction(|| {
        pgrx::Spi::connect_mut(|client| {
            let args = [job.id.into(), job.claim_token.as_str().into()];
            let rows = client.update(
                "SELECT status FROM otlet.renew_job_lease($1, $2) LIMIT 1",
                Some(1),
                &args,
            )?;
            if rows.is_empty() {
                return Ok(None);
            }
            Ok(rows
                .first()
                .get::<String>(1)?
                .map(|status| status == "cancel_requested"))
        })
    });

    match result {
        Ok(Some(canceled)) => Ok(canceled),
        Ok(None) => Err("job lease fence lost: claim token is no longer active".to_owned()),
        Err(err) => Err(format!("job lease renewal failed: {err}")),
    }
}

fn failure_selection_reason<'reason>(err: &ModelError, fallback: &'reason str) -> &'reason str {
    if err.message == "attempt_timeout" {
        "attempt_timeout"
    } else {
        fallback
    }
}

fn accepted_by_policy(output: &Value, accept_field_checks: &Value) -> (bool, &'static str) {
    // Same field readers as accepted_by_direct_decision; policy JSON uses empty
    // arrays (no LazyLock defaults) so confidence/answer empty-field filters
    // and missing accepted_confidence allow-all still match prior behavior.
    if let Some(confidence_field) = accept_field_checks
        .get("confidence_field")
        .and_then(Value::as_str)
        .filter(|field| !field.is_empty())
    {
        let Some(confidence) = output.get(confidence_field).and_then(Value::as_str) else {
            return (false, "missing_confidence_field");
        };
        let accepted_confidence = accept_field_checks
            .get("accepted_confidence")
            .unwrap_or(&Value::Null);
        if !value_string_array_allows(accepted_confidence, confidence) {
            return (false, "confidence_below_policy");
        }
    }

    let Some(answer_field) = accept_field_checks
        .get("answer_field")
        .and_then(Value::as_str)
        .filter(|field| !field.is_empty())
    else {
        return (true, "accepted_by_policy");
    };
    let Some(answer) = output.get(answer_field).and_then(Value::as_str) else {
        return (false, "missing_decision_field");
    };
    let abstain_values = accept_field_checks
        .get("abstain_values")
        .unwrap_or(&Value::Null);
    if value_string_array_contains(abstain_values, answer) {
        return (false, "abstained_output");
    }

    (true, "accepted_by_policy")
}
