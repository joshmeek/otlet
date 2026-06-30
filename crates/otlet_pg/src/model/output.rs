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
        return Err(ModelError::new(format!(
            "linked worker RSS budget could not be enforced: rss sample unavailable policy={} max_worker_rss_bytes={}",
            sample.policy, max_worker_rss_bytes
        )));
    }
    if sample.rss_bytes as u64 > max_worker_rss_bytes {
        return Err(ModelError::new(format!(
            "linked worker RSS budget exceeded: rss_bytes={} max_worker_rss_bytes={} policy={}",
            sample.rss_bytes,
            max_worker_rss_bytes,
            worker_memory_budget_policy(max_worker_rss_bytes)
        )));
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
        let mut object = match action {
            Value::Object(mut object) => {
                if object.len() == 1 && object.contains_key("action") {
                    match object.remove("action") {
                        Some(Value::Object(inner)) => inner,
                        _ => return Err("model JSON action wrapper must contain object".to_owned()),
                    }
                } else {
                    object
                }
            }
            Value::String(text) => {
                let parsed = serde_json::from_str::<Value>(&text)
                    .map_err(|_| "model JSON action string must contain JSON object".to_owned())?;
                let Value::Object(object) = parsed else {
                    return Err("model JSON action string must contain JSON object".to_owned());
                };
                object
            }
            _ => return Err("model JSON actions must contain objects".to_owned()),
        };
        if !object.contains_key("type") {
            if let Some(action_type) = object.remove("action_type") {
                object.insert("type".to_owned(), action_type);
            }
        }
        if !object.contains_key("type") {
            return Err("model JSON actions must contain type".to_owned());
        }
        normalized.push(Value::Object(object));
    }

    Ok(Value::Array(normalized))
}

fn parse_model_json(raw_output: &str) -> Result<(Value, String), String> {
    let mut output_object: Option<(Value, String)> = None;
    let mut actions_object: Option<(Value, String)> = None;

    // Scan model chatter until it can emit clean JSON only
    for (index, _) in raw_output.char_indices().filter(|(_, ch)| *ch == '{') {
        let rest = &raw_output[index..];
        let mut values = serde_json::Deserializer::from_str(rest).into_iter::<Value>();

        if let Some(Ok(value)) = values.next() {
            let raw_json = rest[..values.byte_offset()].to_owned();
            if value.get("output").is_some() && value.get("actions").is_some() {
                return Ok((value, raw_json));
            }
            if value.get("output").is_some() {
                let mut output_value = value["output"].clone();
                if let Some(actions) = output_value.get("actions").cloned() {
                    if let Value::Object(object) = &mut output_value {
                        object.remove("actions");
                    }
                    return Ok((
                        json!({
                            "output": output_value,
                            "actions": actions,
                        }),
                        raw_json,
                    ));
                }
            }
            if value.get("output").is_some() && output_object.is_none() {
                output_object = Some((value.clone(), raw_json.clone()));
            }
            if value.get("actions").is_some() && actions_object.is_none() {
                actions_object = Some((value, raw_json));
            }
            if let (Some((output, output_raw)), Some((actions, actions_raw))) =
                (&output_object, &actions_object)
            {
                let mut output_value = output["output"].clone();
                if let Value::Object(object) = &mut output_value {
                    object.remove("actions");
                }
                return Ok((
                    json!({
                        "output": output_value,
                        "actions": actions["actions"].clone(),
                    }),
                    format!("{output_raw}\n{actions_raw}"),
                ));
            }
        }
    }

    Err(format!("invalid model JSON: {}", trim_error(raw_output)))
}
