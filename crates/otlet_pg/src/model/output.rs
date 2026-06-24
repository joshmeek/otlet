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
    let actions = json
        .get("actions")
        .cloned()
        .unwrap_or_else(|| Value::Array(Vec::new()));
    let Value::Array(actions) = actions else {
        return Err("model JSON actions must be an array".to_owned());
    };

    let mut normalized = Vec::with_capacity(actions.len());
    for action in actions {
        let Value::Object(mut object) = action else {
            return Err("model JSON actions must contain objects".to_owned());
        };
        if !object.contains_key("type") {
            if let Some(alias) = object.remove("action") {
                object.insert("type".to_owned(), alias);
            }
        }
        normalized.push(Value::Object(object));
    }

    Ok(Value::Array(normalized))
}

fn normalize_model_envelope(mut json: Value) -> Result<Value, String> {
    if json.get("actions").is_some() {
        return Ok(json);
    }

    let Some(output) = json.get_mut("output") else {
        return Ok(json);
    };
    let Value::Object(output_object) = output else {
        return Ok(json);
    };
    let Some(actions) = output_object.remove("actions") else {
        return Ok(json);
    };
    if !actions.is_array() {
        return Err("model JSON actions must be an array".to_owned());
    }
    let Value::Object(root) = &mut json else {
        return Ok(json);
    };
    root.insert("actions".to_owned(), actions);

    Ok(json)
}

fn parse_model_json(raw_output: &str) -> Result<(Value, String), String> {
    let mut parsed = None;

    // Scan model chatter until it can emit clean JSON only
    for (index, _) in raw_output.char_indices().filter(|(_, ch)| *ch == '{') {
        let rest = &raw_output[index..];
        let mut values = serde_json::Deserializer::from_str(rest).into_iter::<Value>();

        if let Some(Ok(value)) = values.next() {
            if value.get("output").is_some() {
                parsed = Some((value, rest[..values.byte_offset()].to_owned()));
            }
        }
    }

    parsed.ok_or_else(|| format!("invalid model JSON: {}", trim_error(raw_output)))
}
