struct ShapedInput {
    input: Value,
    bytes: i64,
    original_bytes: i64,
    input_truncated: bool,
    applied: bool,
}

fn shaped_model_input(input: Value) -> ShapedInput {
    let bytes = input.to_string().len().min(i64::MAX as usize) as i64;
    let original_bytes = input
        .get("original_shaped_input_bytes")
        .and_then(Value::as_i64)
        .unwrap_or(bytes);
    let input_truncated = input
        .get("_otlet_input_truncated")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    ShapedInput {
        input,
        bytes,
        original_bytes,
        input_truncated,
        applied: true,
    }
}

fn effective_instruction(instruction: &str, decision_contract: &Value) -> String {
    let prefix = decision_contract
        .get("prompt_prefix")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if prefix.is_empty() {
        instruction.to_owned()
    } else {
        format!("{prefix}{instruction}")
    }
}

fn validate_output(schema: &Value, output: &Value) -> Result<(), String> {
    let validator =
        jsonschema::validator_for(schema).map_err(|err| format!("invalid output schema: {err}"))?;
    validator
        .validate(output)
        .map_err(|err| format!("output schema validation failed: {err}"))
}

fn validate_output_schema(schema: &Value) -> Result<(), String> {
    jsonschema::validator_for(schema)
        .map(|_| ())
        .map_err(|err| format!("invalid output schema: {err}"))
}

fn trim_error(text: &str) -> String {
    text.chars().take(2000).collect()
}

fn elapsed_ms(start: Instant) -> i64 {
    start.elapsed().as_millis().min(i64::MAX as u128) as i64
}

fn u64_to_i64_saturating(value: u64) -> i64 {
    value.min(i64::MAX as u64) as i64
}

fn worker_memory_budget_policy(max_worker_rss_bytes: u64) -> &'static str {
    if max_worker_rss_bytes > 0 {
        "max_worker_rss_bytes_fail_closed_no_late_materialization"
    } else {
        "unbounded_worker_rss_reporting_only"
    }
}

fn enforce_worker_rss_budget(
    sample: &ProcessMemorySample,
    max_worker_rss_bytes: u64,
) -> Result<(), ModelError> {
    if max_worker_rss_bytes == 0 {
        return Ok(());
    }
    if sample.rss_bytes <= 0 {
        return Err(ModelError::clean_failure(
            format!(
                "linked worker RSS budget could not be enforced: rss sample unavailable policy={} max_worker_rss_bytes={}",
                sample.policy, max_worker_rss_bytes
            ),
            "worker_rss_budget_before_generation",
            "worker_rss_sample_unavailable",
        ));
    }
    if sample.rss_bytes as u64 > max_worker_rss_bytes {
        return Err(ModelError::clean_failure(
            format!(
                "linked worker RSS budget exceeded: rss_bytes={} max_worker_rss_bytes={} policy={}",
                sample.rss_bytes,
                max_worker_rss_bytes,
                worker_memory_budget_policy(max_worker_rss_bytes)
            ),
            "worker_rss_budget_before_generation",
            "worker_rss_budget_exceeded",
        ));
    }
    Ok(())
}

fn process_memory_sample() -> ProcessMemorySample {
    match fs::read_to_string("/proc/self/status") {
        Ok(status) => {
            let rss_bytes = proc_status_kib(&status, "VmRSS:").unwrap_or(0);
            let virtual_bytes = proc_status_kib(&status, "VmSize:").unwrap_or(0);
            let policy = if rss_bytes > 0 || virtual_bytes > 0 {
                "linux_proc_self_status_vmrss_vmsize_sampled_after_worker_run"
            } else {
                "linux_proc_self_status_missing_vmrss_vmsize"
            };
            ProcessMemorySample {
                rss_bytes,
                virtual_bytes,
                policy: policy.to_owned(),
            }
        }
        Err(_) => ProcessMemorySample {
            rss_bytes: 0,
            virtual_bytes: 0,
            policy: "proc_self_status_unavailable_non_linux_or_permission_denied".to_owned(),
        },
    }
}

fn proc_status_kib(status: &str, label: &str) -> Option<i64> {
    let line = status.lines().find(|line| line.starts_with(label))?;
    let kib = line.split_whitespace().nth(1)?.parse::<u64>().ok()?;
    Some(u64_to_i64_saturating(kib.saturating_mul(1024)))
}

fn hash_json(value: &Value) -> String {
    hash_text(&value.to_string())
}

fn hash_text(text: &str) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn model_actions(json: &Value) -> Result<Value, String> {
    let Value::Object(object) = json else {
        return Err("model JSON must be an object".to_owned());
    };
    if let Some(extra_key) = object.keys().find(|key| *key != "output" && *key != "actions") {
        return Err(format!(
            "model JSON unsupported top-level key: {extra_key}"
        ));
    }
    let actions = json
        .get("actions")
        .cloned()
        .ok_or_else(|| "model JSON missing actions".to_owned())?;
    let Value::Array(actions) = actions else {
        return Err("model JSON actions must be an array".to_owned());
    };

    let mut normalized = Vec::with_capacity(actions.len());
    for action in actions {
        let Value::Object(object) = action else {
            return Err("model JSON actions must contain objects".to_owned());
        };
        if let Some(extra_key) = object.keys().find(|key| *key != "type" && *key != "body") {
            return Err(format!(
                "model JSON action unsupported key: {extra_key}"
            ));
        }

        let Some(action_type) = object.get("type").and_then(Value::as_str) else {
            return Err("model JSON actions must contain type".to_owned());
        };
        if action_type.trim().is_empty() {
            return Err("model JSON action type must not be empty".to_owned());
        }

        let Some(body) = object.get("body") else {
            return Err("model JSON actions must contain body".to_owned());
        };
        if !body.is_object() {
            return Err("model JSON action body must be an object".to_owned());
        }

        normalized.push(Value::Object(object));
    }

    Ok(Value::Array(normalized))
}

fn parse_model_json(raw_output: &str) -> Result<(Value, String), String> {
    let trimmed = raw_output.trim();
    if trimmed.starts_with("```") || trimmed.ends_with("```") {
        return Err(format!(
            "invalid model JSON: markdown fences are not allowed: {}",
            trim_error(raw_output)
        ));
    }

    let value = serde_json::from_str::<Value>(trimmed)
        .map_err(|err| format!("invalid model JSON: {err}: {}", trim_error(raw_output)))?;
    let Value::Object(object) = &value else {
        return Err("model JSON must be an object".to_owned());
    };
    if !object.contains_key("output") {
        return Err("model JSON missing output".to_owned());
    }
    if !object.contains_key("actions") {
        return Err("model JSON missing actions".to_owned());
    }
    if object
        .get("output")
        .and_then(|output| output.get("actions"))
        .is_some()
    {
        return Err("model JSON output must not contain actions".to_owned());
    }

    Ok((value, trimmed.to_owned()))
}

#[cfg(test)]
mod output_envelope_tests {
    use super::*;

    #[test]
    fn parse_model_json_rejects_markdown_fences() {
        let raw = "```json\n{\"output\":{\"status\":\"ok\"},\"actions\":[]}\n```";

        assert_eq!(
            parse_model_json(raw).unwrap_err(),
            format!("invalid model JSON: markdown fences are not allowed: {raw}")
        );
    }

    #[test]
    fn parse_model_json_rejects_nested_actions() {
        let raw = "{\"output\":{\"status\":\"ok\",\"actions\":[]},\"actions\":[]}";

        assert_eq!(
            parse_model_json(raw).unwrap_err(),
            "model JSON output must not contain actions"
        );
    }

    #[test]
    fn model_actions_rejects_extra_top_level_keys() {
        let (json, _) =
            parse_model_json("{\"output\":{\"status\":\"ok\"},\"actions\":[],\"extra\":true}")
                .unwrap();

        assert_eq!(
            model_actions(&json).unwrap_err(),
            "model JSON unsupported top-level key: extra"
        );
    }

    #[test]
    fn model_actions_rejects_non_object_entries() {
        let (json, _) =
            parse_model_json("{\"output\":{\"status\":\"ok\"},\"actions\":[\"bad\"]}").unwrap();

        assert_eq!(
            model_actions(&json).unwrap_err(),
            "model JSON actions must contain objects"
        );
    }
}
