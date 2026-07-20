fn linked_prompt_prefix_reusable(
    tokens: &[llama_cpp_sys_4::llama_token],
    prefix_tokens: &[llama_cpp_sys_4::llama_token],
) -> bool {
    !prefix_tokens.is_empty() && prefix_tokens.len() < tokens.len() && tokens.starts_with(prefix_tokens)
}

fn linked_cached_prompt_prefix_tokens(
    states: &mut Vec<PromptPrefixState>,
    prompt_prefix_hash: &str,
    prompt_prefix: &str,
) -> Option<Arc<[llama_cpp_sys_4::llama_token]>> {
    let index = states.iter().position(|entry| {
        entry.hash == prompt_prefix_hash && entry.prefix.as_ref() == prompt_prefix
    })?;
    let tokens = Arc::clone(&states[index].tokens);
    if index != 0 {
        let entry = states.remove(index);
        states.insert(0, entry);
    }
    Some(tokens)
}

fn linked_restore_prompt_prefix_state(
    cache: &mut LinkedCache,
    prompt_prefix_hash: &str,
    prompt_prefix_tokens: &[llama_cpp_sys_4::llama_token],
) -> Option<usize> {
    let index = cache
        .prompt_prefix_states
        .iter()
        .position(|entry| {
            entry.hash == prompt_prefix_hash
                && entry.tokens.as_ref() == prompt_prefix_tokens
                && !entry.state.is_empty()
        })?;

    linked_clear_context(cache.context.ptr);
    let state_len = cache.prompt_prefix_states[index].state.len();
    let restored = unsafe {
        llama_cpp_sys_4::llama_state_seq_set_data(
            cache.context.ptr,
            cache.prompt_prefix_states[index].state.as_ptr(),
            state_len,
            0,
        )
    };
    if restored != state_len {
        cache.prompt_prefix_states.remove(index);
        cache.kv_tokens.clear();
        linked_clear_context(cache.context.ptr);
        return None;
    }

    if index != 0 {
        let entry = cache.prompt_prefix_states.remove(index);
        cache.prompt_prefix_states.insert(0, entry);
    }

    cache.kv_tokens.clear();
    cache.kv_tokens.extend_from_slice(prompt_prefix_tokens);
    Some(state_len)
}

struct SavedPromptPrefix {
    strategy: &'static str,
    state_bytes: usize,
}

fn linked_save_prompt_prefix_state(
    cache: &mut LinkedCache,
    prompt_prefix_hash: &str,
    prompt_prefix: &str,
    prompt_prefix_tokens: Arc<[llama_cpp_sys_4::llama_token]>,
) -> SavedPromptPrefix {
    let state_size =
        unsafe { llama_cpp_sys_4::llama_state_seq_get_size(cache.context.ptr, 0) };
    if state_size == 0 {
        linked_remove_prompt_prefix_state(cache, prompt_prefix_hash);
        return SavedPromptPrefix {
            strategy: "prefix_state_unavailable",
            state_bytes: 0,
        };
    }
    if state_size > LINKED_PROMPT_PREFIX_STATE_MAX_BYTES {
        linked_remove_prompt_prefix_state(cache, prompt_prefix_hash);
        return SavedPromptPrefix {
            strategy: "prefix_state_too_large",
            state_bytes: 0,
        };
    }

    let mut state = vec![0_u8; state_size];
    let written = unsafe {
        llama_cpp_sys_4::llama_state_seq_get_data(
            cache.context.ptr,
            state.as_mut_ptr(),
            state.len(),
            0,
        )
    };
    if written != state.len() {
        linked_remove_prompt_prefix_state(cache, prompt_prefix_hash);
        return SavedPromptPrefix {
            strategy: "prefix_state_save_failed",
            state_bytes: 0,
        };
    }

    linked_remove_prompt_prefix_state(cache, prompt_prefix_hash);
    cache.prompt_prefix_states.insert(
        0,
        PromptPrefixState {
            hash: prompt_prefix_hash.to_owned(),
            prefix: Arc::from(prompt_prefix),
            tokens: prompt_prefix_tokens,
            state,
        },
    );
    linked_evict_prompt_prefix_states(&mut cache.prompt_prefix_states);
    SavedPromptPrefix {
        strategy: "prefix_state_saved",
        state_bytes: state_size,
    }
}

fn linked_remove_prompt_prefix_state(cache: &mut LinkedCache, prompt_prefix_hash: &str) {
    cache
        .prompt_prefix_states
        .retain(|entry| entry.hash != prompt_prefix_hash);
}

fn linked_evict_prompt_prefix_states(states: &mut Vec<PromptPrefixState>) {
    while states.len() > LINKED_PROMPT_PREFIX_STATE_MAX_ENTRIES
        || linked_prompt_prefix_cache_bytes(states) > LINKED_PROMPT_PREFIX_STATE_MAX_BYTES
    {
        if states.pop().is_none() {
            break;
        }
    }
}

fn linked_prompt_prefix_cache_bytes(states: &[PromptPrefixState]) -> usize {
    states
        .iter()
        .map(|entry| {
            entry
                .tokens
                .len()
                .saturating_mul(std::mem::size_of::<llama_cpp_sys_4::llama_token>())
                .saturating_add(entry.prefix.len())
                .saturating_add(entry.state.len())
        })
        .sum()
}

/// Keeps the longest common prefix between the tokens already decoded into the
/// context memory and the new prompt, removes everything past it, and returns
/// how many prompt tokens can be skipped. At least one prompt token is always
/// re-decoded so generation has fresh logits. `kv_tokens` is truncated to the
/// retained prefix before any new decode happens, so a failed decode later can
/// never leave it claiming tokens the memory does not hold.
fn linked_reuse_prompt_prefix(
    context: *mut llama_cpp_sys_4::llama_context,
    kv_tokens: &mut Vec<llama_cpp_sys_4::llama_token>,
    tokens: &[llama_cpp_sys_4::llama_token],
) -> usize {
    let mut common = kv_tokens
        .iter()
        .zip(tokens.iter())
        .take_while(|(kept, new)| kept == new)
        .count();
    if common >= tokens.len() {
        common = tokens.len().saturating_sub(1);
    }

    if common == 0 {
        linked_clear_context(context);
        kv_tokens.clear();
        return 0;
    }

    let removed = unsafe {
        let memory = llama_cpp_sys_4::llama_get_memory(context);
        if memory.is_null() {
            false
        } else {
            // Remove from the divergence point onward; this also clears any
            // stale generated tokens from the previous run.
            llama_cpp_sys_4::llama_memory_seq_rm(memory, 0, usize_to_i32_saturating(common), -1)
        }
    };
    if !removed {
        linked_clear_context(context);
        kv_tokens.clear();
        return 0;
    }

    kv_tokens.truncate(common);
    common
}

