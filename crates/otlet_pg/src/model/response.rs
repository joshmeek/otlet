struct FnvWriter {
    hash: u64,
}

impl FnvWriter {
    const fn new() -> Self {
        Self {
            hash: 0xcbf2_9ce4_8422_2325_u64,
        }
    }

    fn write_bytes(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.hash ^= u64::from(*byte);
            self.hash = self.hash.wrapping_mul(0x0100_0000_01b3);
        }
    }
}

fn hash_json(value: &Value) -> String {
    serde_json::to_vec(value)
        .map_or_else(|_| hash_text(&value.to_string()), |bytes| hash_bytes(&bytes))
}

fn hash_text(text: &str) -> String {
    hash_text_parts(&[text])
}

fn hash_text_parts(parts: &[&str]) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(part.as_bytes());
    }
    format!("{:x}", hasher.finalize())
}

fn hash_bytes(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn hash_bytes_parts_u64(parts: &[&[u8]]) -> u64 {
    let mut writer = FnvWriter::new();
    for part in parts {
        writer.write_bytes(part);
    }
    writer.hash
}

fn model_actions(actions: Value) -> Result<Value, String> {
    let Value::Array(actions) = actions else {
        return Err("model JSON actions must be an array".to_owned());
    };

    let mut normalized = Vec::with_capacity(actions.len());
    for action in actions {
        let Value::Object(object) = &action else {
            return Err("model JSON actions must contain objects".to_owned());
        };
        if object.keys().any(|key| key != "type" && key != "body") {
            return Err("model JSON action has unsupported key".to_owned());
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

        normalized.push(action);
    }

    Ok(Value::Array(normalized))
}

fn parse_model_json(raw_output: &str) -> Result<Value, String> {
    let trimmed = raw_output.trim();
    if trimmed.starts_with("```") || trimmed.ends_with("```") {
        return Err("invalid model JSON: markdown fences are not allowed".to_owned());
    }

    let value = serde_json::from_str::<Value>(trimmed)
        .map_err(|err| format!("invalid model JSON: {err}"))?;
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

    Ok(value)
}

#[cfg(test)]
mod output_tests {
    use super::*;

    fn contract_test_job() -> Job {
        let properties = (0..8)
            .map(|index| (format!("field_{index}"), json!({"type": "string"})))
            .collect::<serde_json::Map<_, _>>();
        Job {
            id: 1,
            task_name: "contract_test".to_owned(),
            subject_id: "subject".to_owned(),
            instruction: "classify the record ".repeat(8),
            output_schema: json!({"type": "object", "properties": properties}),
            input: json!({"value": "test"}),
            input_content_hash: "content".to_owned(),
            artifact_path: "/tmp/model.gguf".to_owned(),
            artifact_hash: "artifact".to_owned(),
            artifact_identity: json!({"sha256": "artifact", "bytes": 1}),
            model_name: "test_model".to_owned(),
            runtime_options: json!({"reasoning": "off"}),
            input_shaping: json!({"include": ["value"]}),
            decision_contract: json!({"answer_field": "decision"}),
            max_attempt_ms: 30_000,
            claim_token: "test-claim-token".to_owned(),
        }
    }

    #[test]
    fn task_contract_cache_requires_exact_identity() {
        let job = contract_test_job();
        let digests = Arc::new(build_task_contract_digests(&job));
        let mut cache = TaskContractCache::new();
        cache.insert(&job, Arc::clone(&digests));
        assert!(Arc::ptr_eq(&cache.get(&job).unwrap(), &digests));

        let mut changed = contract_test_job();
        changed.runtime_options = json!({"reasoning": "on"});
        assert!(cache.get(&changed).is_none());
        changed = contract_test_job();
        changed.output_schema = json!({"type": "string"});
        assert!(cache.get(&changed).is_none());
        changed = contract_test_job();
        changed.input_shaping = json!({"include": ["other"]});
        assert!(cache.get(&changed).is_none());
        changed = contract_test_job();
        changed.decision_contract = json!({"answer_field": "other"});
        assert!(cache.get(&changed).is_none());
        changed = contract_test_job();
        changed.instruction.push_str(" changed");
        assert!(cache.get(&changed).is_none());
        changed = contract_test_job();
        changed.model_name = "other_model".to_owned();
        assert!(cache.get(&changed).is_none());
        changed = contract_test_job();
        changed.artifact_path = "/tmp/other.gguf".to_owned();
        assert!(cache.get(&changed).is_none());
        changed = contract_test_job();
        changed.artifact_hash = "other_artifact".to_owned();
        assert!(cache.get(&changed).is_none());
    }

    #[test]
    fn task_contract_cache_bounds_entries_and_preserves_lru_order() {
        let mut cache = TaskContractCache::new();
        for index in 0..TASK_CONTRACT_CACHE_MAX_ENTRIES {
            let mut job = contract_test_job();
            job.task_name = format!("task_{index}");
            let digests = Arc::new(build_task_contract_digests(&job));
            cache.insert(&job, digests);
        }
        let mut first = contract_test_job();
        first.task_name = "task_0".to_owned();
        assert!(cache.get(&first).is_some());

        let mut overflow = contract_test_job();
        overflow.task_name = "task_overflow".to_owned();
        let digests = Arc::new(build_task_contract_digests(&overflow));
        cache.insert(&overflow, digests);

        assert_eq!(cache.entries.len(), TASK_CONTRACT_CACHE_MAX_ENTRIES);
        assert!(cache.entries.iter().any(|entry| entry.task_name == "task_0"));
        assert!(!cache.entries.iter().any(|entry| entry.task_name == "task_1"));
        assert!(
            cache
                .entries
                .iter()
                .any(|entry| entry.task_name == "task_overflow")
        );
    }

    #[test]
    fn task_contract_cache_reuses_prefix_and_invalid_option_result() {
        let mut job = contract_test_job();
        let digests = build_task_contract_digests(&job);
        let rendered = cached_rendered_schema(&job.output_schema, &digests.output_schema_hash);
        let first = cached_prompt_prefix(
            &digests,
            digests.runtime_options.as_ref().unwrap(),
            &digests.instruction,
            &rendered,
        );
        let second = cached_prompt_prefix(
            &digests,
            digests.runtime_options.as_ref().unwrap(),
            &digests.instruction,
            &rendered,
        );
        assert!(Arc::ptr_eq(&first, &second));

        job.runtime_options = json!({"threads": "invalid"});
        let invalid = Arc::new(build_task_contract_digests(&job));
        assert!(invalid.runtime_options.is_err());
        let mut cache = TaskContractCache::new();
        cache.insert(&job, Arc::clone(&invalid));
        assert!(cache.get(&job).unwrap().runtime_options.is_err());
    }

    #[test]
    fn shaped_model_prompt_preserves_prompt_hashes_and_metadata() {
        let input = json!({
            "_otlet_input_truncated": true,
            "original_shaped_input_bytes": 4096,
            "text": "hello"
        });
        let prefix = "prompt-prefix\n";
        let serialized = serde_json::to_string(&input).unwrap();
        let shaped = shaped_model_prompt(&input, prefix);

        assert_eq!(
            shaped.full,
            format!("{prefix}{serialized}{PROMPT_BODY_AFTER_INPUT}")
        );
        assert_eq!(shaped.prompt_hash, hash_text(&shaped.full));
        assert_eq!(shaped.input_hash, hash_text(&serialized));
        assert_eq!(shaped.bytes, serialized.len() as i64);
        assert_eq!(shaped.original_bytes, 4096);
        assert!(shaped.input_truncated);
    }

    #[test]
    fn digest_cache_preserves_lru_order_when_access_clock_exhausts() {
        let schema = json!({"type": "object"});
        let mut cache = DigestCache::new();
        cache.insert("old", &schema, 1, 2);
        cache.insert("new", &schema, 2, 2);
        cache.entries.get_mut("old").unwrap().last_access = 1;
        cache.entries.get_mut("new").unwrap().last_access = u64::MAX;
        cache.access_clock = u64::MAX;

        assert_eq!(cache.get("new", &schema), Some(2));
        cache.insert("third", &schema, 3, 2);

        assert!(!cache.entries.contains_key("old"));
        assert!(cache.entries.contains_key("new"));
        assert!(cache.entries.contains_key("third"));
    }

    #[test]
    fn parse_errors_do_not_copy_raw_output() {
        let sentinel = "SECRET-🙂-SOURCE-VALUE";
        let markdown = parse_model_json(&format!("```json\n{sentinel}\n```"))
            .expect_err("markdown must fail");
        let invalid = parse_model_json(&format!("{{\"output\":\"{sentinel}\""))
            .expect_err("invalid JSON must fail");

        assert!(!markdown.contains(sentinel));
        assert!(!invalid.contains(sentinel));
    }

    #[test]
    fn schema_errors_do_not_copy_output_values() {
        let sentinel = "SECRET-SCHEMA-SOURCE-VALUE";
        let schema = json!({
            "type": "object",
            "properties": {"status": {"enum": ["ok"]}},
            "required": ["status"]
        });
        let output = json!({"status": sentinel});
        let error = validate_output(&schema, "safe-error-test", &output)
            .expect_err("invalid output must fail");

        assert_eq!(error, "output schema validation failed");
        assert!(!error.contains(sentinel));
    }

    #[test]
    fn linux_memory_parsers_preserve_units_and_counters() {
        let status = "VmRSS:\t  1234 kB\nVmSize:\t5678 kB\nVmSwap:\t9 kB\n";
        let stat = "123 (otlet worker) S 1 2 3 4 5 6 7 8 99 10";
        let io = "rchar: 10\nread_bytes: 4096\n";
        let pressure = "some avg10=0.00 avg60=0.01 avg300=0.02 total=12345\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=678\n";

        assert_eq!(proc_kib(status, "VmRSS:"), Some(1_263_616));
        assert_eq!(proc_kib(status, "VmSwap:"), Some(9_216));
        assert_eq!(proc_stat_major_faults(stat), Some(99));
        assert_eq!(keyed_i64(io, "read_bytes:"), Some(4096));
        assert_eq!(psi_total_us(pressure, "some"), Some(12_345));
        assert_eq!(psi_total_us(pressure, "full"), Some(678));
        assert_eq!(parse_memory_value("max\n"), Some(0));
        assert_eq!(parse_memory_value("1048576\n"), Some(1_048_576));
        assert_eq!(cgroup_v2_relative("0::/postgres.slice\n"), Some("/postgres.slice"));
    }

    #[test]
    fn memory_counter_deltas_do_not_underflow() {
        assert_eq!(counter_delta(10, 25), 15);
        assert_eq!(counter_delta(25, 10), 0);
    }
}
