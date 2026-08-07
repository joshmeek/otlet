#[cfg(test)]
mod tests {
    use super::{
        CancelProbe, JsonCompletion, ProcessMemorySample, PromptPrefixState,
        ModelError, RequestMemoryAdmission, linked_attempt_deadline, linked_attempt_timed_out,
        linked_cached_prompt_prefix_tokens, linked_evict_prompt_prefix_states,
        linked_physical_context_window_tokens, linked_prompt_batch_tokens,
        linked_prompt_prefix_cache_bytes, model_context_budget, trim_model_output,
        validate_linked_token_budget, validate_model_context_budget,
    };
    use crate::model::{
        LINKED_CONTEXT_WINDOW_QUANTUM_TOKENS, LINKED_CONTEXT_WINDOW_TOKENS,
        LINKED_MAX_TOKEN_PIECE_BYTES, LINKED_PROMPT_PREFIX_STATE_MAX_BYTES,
        LINKED_PROMPT_PREFIX_STATE_MAX_ENTRIES,
    };
    use serde_json::json;
    use std::mem::size_of;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    fn prompt_prefix_state(hash: &str, prefix: &str, tokens: &[i32]) -> PromptPrefixState {
        PromptPrefixState {
            hash: hash.to_owned(),
            prefix: Arc::from(prefix),
            tokens: Arc::from(tokens),
            state: vec![0],
        }
    }

    #[test]
    fn prompt_prefix_token_cache_requires_exact_prefix_and_preserves_tokens() {
        let expected = Arc::<[i32]>::from([1, 2, 3]);
        let mut states = vec![
            prompt_prefix_state("other", "other prefix", &[9]),
            PromptPrefixState {
                hash: "wanted".to_owned(),
                prefix: Arc::from("exact prefix"),
                tokens: Arc::clone(&expected),
                state: vec![0],
            },
        ];

        let hit = linked_cached_prompt_prefix_tokens(&mut states, "wanted", "exact prefix")
            .expect("exact prefix should hit");
        assert!(Arc::ptr_eq(&hit, &expected));
        assert_eq!(hit.as_ref(), [1, 2, 3]);
        assert_eq!(states[0].prefix.as_ref(), "exact prefix");
        assert!(linked_cached_prompt_prefix_tokens(&mut states, "wanted", "collision").is_none());
        assert!(
            linked_cached_prompt_prefix_tokens(&mut states, "changed", "exact prefix").is_none()
        );
    }

    #[test]
    fn prompt_prefix_token_cache_uses_existing_entry_and_byte_bounds() {
        let mut states = (0..=LINKED_PROMPT_PREFIX_STATE_MAX_ENTRIES)
            .map(|index| {
                prompt_prefix_state(
                    &format!("hash_{index}"),
                    &format!("prefix_{index}"),
                    &[index as i32],
                )
            })
            .collect::<Vec<_>>();
        let expected_bytes: usize = states
            .iter()
            .map(|entry| entry.prefix.len() + entry.tokens.len() * size_of::<i32>() + 1)
            .sum();
        assert_eq!(linked_prompt_prefix_cache_bytes(&states), expected_bytes);

        linked_evict_prompt_prefix_states(&mut states);
        assert_eq!(states.len(), LINKED_PROMPT_PREFIX_STATE_MAX_ENTRIES);
        assert_eq!(states[0].hash, "hash_0");
        assert_eq!(states.last().unwrap().hash, "hash_3");
    }

    #[test]
    fn json_completion_is_invariant_across_bounded_splits() {
        let escaped = br#"{"text":"quoted\" brace }","nested":{"ok":true}}"#;
        let unicode = r#"{"unicode":"é🙂","combining":"é"}"#.as_bytes();
        let invalid_utf8 = &[b'{', b'"', 0xf0, 0x28, 0x8c, 0x28, b'"', b'}'];
        let cases = [
            (b"".as_slice(), None),
            (b"{".as_slice(), None),
            (b"}".as_slice(), Some(0)),
            (b"{} trailing".as_slice(), Some(2)),
            (b"{}{}".as_slice(), Some(2)),
            (br#"{"unterminated":"canary"#.as_slice(), None),
            (escaped.as_slice(), Some(escaped.len())),
            (unicode, Some(unicode.len())),
            (invalid_utf8.as_slice(), Some(invalid_utf8.len())),
        ];

        for (input, expected) in cases {
            for split in 0..=input.len() {
                let mut completion = JsonCompletion::new();
                let actual = completion
                    .observe(&input[..split])
                    .or_else(|| completion.observe(&input[split..]));
                assert_eq!(actual, expected, "split {split} for {input:?}");
                assert!(actual.is_none_or(|end| end <= input.len()));
            }

            let mut completion = JsonCompletion::new();
            let actual = input
                .iter()
                .find_map(|byte| completion.observe(std::slice::from_ref(byte)));
            assert_eq!(actual, expected, "byte splits for {input:?}");
        }
    }

    #[test]
    fn trim_model_output_reuses_clean_allocation_and_trims_padding() {
        let clean = "{\"output\":{},\"actions\":[]}".to_owned();
        let clean_ptr = clean.as_ptr();
        let reused = trim_model_output(clean);
        assert_eq!(reused.as_ptr(), clean_ptr);
        assert_eq!(
            trim_model_output(format!("  {reused}\n")),
            "{\"output\":{},\"actions\":[]}"
        );
    }

    #[test]
    fn attempt_deadline_preserves_disabled_expired_and_future_states() {
        let now = Instant::now();
        assert!(linked_attempt_deadline(now, 0).is_none());
        assert!(linked_attempt_timed_out(linked_attempt_deadline(
            now - Duration::from_millis(2),
            1
        )));
        assert!(!linked_attempt_timed_out(linked_attempt_deadline(
            now, 60_000
        )));
    }

    #[test]
    fn cancellation_probe_reschedules_after_becoming_due() {
        let mut probe = CancelProbe {
            next_check: Instant::now() - Duration::from_millis(1),
        };
        assert!(probe.due());
        assert!(!probe.due());
    }

    #[test]
    fn model_context_budget_defaults_bounds_and_preserves_overflow_reasons() {
        let defaults = crate::runtime::RuntimeOptions::default();
        let legacy = model_context_budget(&json!({}), &defaults)
            .unwrap_or_else(|err| panic!("{}", err.message));
        assert_eq!(legacy.tested, LINKED_CONTEXT_WINDOW_TOKENS);
        assert_eq!(legacy.requested, None);
        assert_eq!(legacy.effective, LINKED_CONTEXT_WINDOW_TOKENS);
        assert_eq!(legacy.physical, LINKED_CONTEXT_WINDOW_TOKENS);

        let options = crate::runtime::parse_runtime_options(&json!({
            "context_window_tokens": 1024,
            "max_tokens": 25
        }))
        .unwrap();
        let bounded = model_context_budget(&json!({"context_window_tokens": 2048}), &options)
            .unwrap_or_else(|err| panic!("{}", err.message));
        assert_eq!(
            (bounded.tested, bounded.requested, bounded.effective),
            (2048, Some(1024), 1024)
        );
        assert_eq!(bounded.physical, 2048);
        assert_eq!(linked_physical_context_window_tokens(1), 256);
        assert_eq!(linked_physical_context_window_tokens(256), 256);
        assert_eq!(linked_physical_context_window_tokens(2049), 2304);
        assert_eq!(
            linked_physical_context_window_tokens(LINKED_CONTEXT_WINDOW_TOKENS),
            LINKED_CONTEXT_WINDOW_TOKENS
        );
        assert_eq!(LINKED_CONTEXT_WINDOW_QUANTUM_TOKENS, 256);
        assert!(validate_linked_token_budget(999, options.max_tokens, 1024).is_ok());
        assert_eq!(
            validate_linked_token_budget(1000, options.max_tokens, 1024)
                .err()
                .and_then(|err| err.trace_summary)
                .and_then(|trace| trace.get("stop_reason").cloned()),
            Some(json!("prompt_and_generation_exceed_context_window"))
        );

        let requested_too_large = crate::runtime::parse_runtime_options(&json!({
            "context_window_tokens": 2049
        }))
        .unwrap();
        let rejected_budget = model_context_budget(
                &json!({"context_window_tokens": 2048}),
                &requested_too_large
            )
            .unwrap_or_else(|err| panic!("{}", err.message));
        assert_eq!(rejected_budget.effective, 2048);
        let rejected = validate_model_context_budget(rejected_budget)
            .err()
            .expect("oversized request must fail");
        assert_eq!(
            rejected
            .trace_summary
            .as_ref()
            .and_then(|trace| trace.get("stop_reason").cloned()),
            Some(json!("requested_context_window_exceeds_model_limit"))
        );
        let status = crate::runtime::runtime_option_status(
            &json!({"context_window_tokens": 2049}),
            2048,
            2048,
        );
        let fingerprint = json!({
            "output_contract": {
                "context": {
                    "tested_context_window_tokens": 2048,
                    "requested_context_window_tokens": 2049,
                    "effective_context_window_tokens": 2048,
                    "physical_context_window_tokens": 2048
                }
            }
        });
        let rejected = rejected.with_runtime_evidence(
            &status,
            "model",
            &fingerprint,
            "runtime",
            "output",
        );
        let trace = rejected.trace_summary.expect("runtime evidence must be recorded");
        assert_eq!(
            trace.pointer(
                "/runtime_options_status/context_window/requested_context_window_tokens"
            ).and_then(serde_json::Value::as_u64),
            Some(2049)
        );
        assert_eq!(
            trace.pointer(
                "/runtime_fingerprint/output_contract/context/effective_context_window_tokens"
            ).and_then(serde_json::Value::as_u64),
            Some(2048)
        );
    }

    #[test]
    fn request_memory_admission_projects_prompt_and_decode_before_work() {
        let sample = ProcessMemorySample {
            rss_bytes: 100,
            ..ProcessMemorySample::default()
        };
        let allowed = RequestMemoryAdmission::new("hello".len(), 3, 7, 0, &sample, u64::MAX);
        let projected_prompt = "hello".len() + 3 * size_of::<llama_cpp_sys_4::llama_token>();
        let projected_decode = 7 * LINKED_MAX_TOKEN_PIECE_BYTES
            + LINKED_MAX_TOKEN_PIECE_BYTES
            + linked_prompt_batch_tokens() * 16;
        assert_eq!(allowed.projected_prompt_bytes, projected_prompt as i64);
        assert_eq!(allowed.projected_decode_bytes, projected_decode as i64);
        assert_eq!(allowed.decision, "allowed");

        let rejected = RequestMemoryAdmission::new(
            "hello".len(),
            3,
            7,
            0,
            &sample,
            (100 + projected_prompt + projected_decode - 1) as u64,
        );
        assert!(rejected.rejected());
        assert_eq!(
            rejected.reason,
            "prompt_decode_projection_exceeds_worker_rss_budget"
        );

        let prefix_rejected = RequestMemoryAdmission::new(
            "hello".len(),
            3,
            7,
            LINKED_PROMPT_PREFIX_STATE_MAX_BYTES,
            &sample,
            (100
                + projected_prompt
                + projected_decode
                + LINKED_PROMPT_PREFIX_STATE_MAX_BYTES
                - 1) as u64,
        );
        assert_eq!(
            prefix_rejected.projected_prompt_prefix_state_bytes,
            LINKED_PROMPT_PREFIX_STATE_MAX_BYTES as i64
        );
        assert!(prefix_rejected.rejected());

        let error = ModelError::new("failed").with_memory_trace(json!({"decision": "allowed"}));
        assert_eq!(
            error
                .trace_summary
                .and_then(|trace| trace.get("memory").cloned()),
            Some(json!({"decision": "allowed"}))
        );
    }
}
