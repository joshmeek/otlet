#[cfg(test)]
mod tests {
    use super::{
        CancelProbe, JsonCompletion, PromptPrefixState, linked_attempt_deadline,
        linked_attempt_timed_out, linked_cached_prompt_prefix_tokens,
        linked_evict_prompt_prefix_states, linked_prompt_prefix_cache_bytes, trim_model_output,
    };
    use crate::model::LINKED_PROMPT_PREFIX_STATE_MAX_ENTRIES;
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
        assert!(linked_cached_prompt_prefix_tokens(&mut states, "changed", "exact prefix").is_none());
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
    fn json_completion_accepts_utf8_split_across_pieces() {
        let mut completion = JsonCompletion::new();
        let prefix = b"{\"text\":\"";
        let split_utf8 = [0xe2, 0x82, 0xac];
        let suffix = b"\"} trailing";

        assert_eq!(completion.observe(prefix), None);
        assert_eq!(completion.observe(&split_utf8), None);
        assert_eq!(
            completion.observe(suffix),
            Some(prefix.len() + split_utf8.len() + 2)
        );
    }

    #[test]
    fn json_completion_keeps_escape_state_across_pieces() {
        let mut completion = JsonCompletion::new();
        let prefix = b"{\"text\":\"quoted\\";
        let suffix = b"\"\"}";

        assert_eq!(completion.observe(prefix), None);
        assert_eq!(
            completion.observe(suffix),
            Some(prefix.len() + suffix.len())
        );
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
}

