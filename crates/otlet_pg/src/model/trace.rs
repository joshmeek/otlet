fn generation_trace_summary(
    context: &RunContext,
    metrics: &ModelMetrics,
    raw_output_hash: &str,
) -> Value {
    let tokens_per_second = if metrics.generate_ms > 0 {
        Some((metrics.generated_tokens as f64 * 1000.0) / metrics.generate_ms as f64)
    } else {
        None
    };
    let steady_decode_ms = metrics.generate_ms.saturating_sub(metrics.first_token_ms);
    let steady_tokens = metrics.generated_tokens.saturating_sub(1);
    let steady_tokens_per_second = if steady_decode_ms > 0 && steady_tokens > 0 {
        Some((steady_tokens as f64 * 1000.0) / steady_decode_ms as f64)
    } else {
        None
    };
    let summary = json!({
        "trace_version": "otlet_generation_trace_v1",
        "prompt_hash": context.prompt_hash,
        "input_hash": context.input_hash,
        "row_identity": context.row_identity,
        "mvcc": context.mvcc,
        "output_schema_hash": context.output_schema_hash,
        "runtime_options_hash": context.runtime_options_hash,
        "runtime_options_status": context.runtime_options_status,
        "model_fingerprint_hash": context.model_fingerprint_hash,
        "raw_output_hash": raw_output_hash,
        "prompt_tokens": metrics.prompt_tokens,
        "prompt_cached_tokens_before": metrics.prompt_cached_tokens_before,
        "prompt_reused_tokens": metrics.prompt_reused_tokens,
        "prompt_decoded_tokens": metrics.prompt_decoded_tokens,
        "generated_tokens": metrics.generated_tokens,
        "tokenize_ms": metrics.tokenize_ms,
        "prompt_decode_ms": metrics.prompt_decode_ms,
        "first_token_ms": metrics.first_token_ms,
        "ttft_ms": metrics.ttft_ms,
        "steady_decode_ms": steady_decode_ms,
        "generate_ms": metrics.generate_ms,
        "tokens_per_second": tokens_per_second,
        "steady_tokens_per_second": steady_tokens_per_second,
        "model_memory_bytes": metrics.model_memory_bytes,
        "model_parameters": metrics.model_parameters,
        "context_window_tokens": metrics.context_window_tokens,
        "worker_process_rss_bytes": metrics.worker_process_rss_bytes,
        "worker_process_virtual_bytes": metrics.worker_process_virtual_bytes,
        "model_cache_hit": metrics.cache_hit,
        "inference_cache_hit": metrics.inference_cache_hit,
        "schema_validation_status": "passed",
        "schema_force": "post_generation_json_schema_validation",
        "stop_reason": metrics.stop_reason,
        "decode_constraint": LINKED_DECODE_CONSTRAINT,
        "decode_constraint_reason": LINKED_DECODE_CONSTRAINT_REASON,
        "probability_summary": metrics.probability_summary,
        "detailed_trace": metrics.detailed_trace,
        "decision": {
            "contract_hash": context.decision_contract_hash,
            "preset_name": context.decision_preset_name,
            "preset_contract_hash": context.decision_preset_contract_hash
        },
        "cache": {
            "key_basis": context.inference_cache_key_basis,
            "entries": metrics.inference_cache_entries,
            "bytes": metrics.inference_cache_bytes,
            "max_entries": metrics.inference_cache_max_entries,
            "max_bytes": metrics.inference_cache_max_bytes,
            "evictions": metrics.inference_cache_evictions,
            "eviction_reason": metrics.inference_cache_eviction_reason,
            "invalidation_reason": metrics.inference_cache_invalidation_reason
        },
        "memory": {
            "model_device_policy": metrics.model_device_policy,
            "memory_accounting_policy": metrics.memory_accounting_policy,
            "worker_memory_sample_policy": metrics.worker_memory_sample_policy,
            "worker_memory_budget_bytes": metrics.worker_memory_budget_bytes,
            "worker_memory_budget_policy": metrics.worker_memory_budget_policy
        },
        "input_shaping": {
            "shaped_input_bytes": context.shaped_input_bytes,
            "original_shaped_input_bytes": context.original_shaped_input_bytes,
            "max_shaped_input_bytes": context.max_shaped_input_bytes,
            "input_truncated": context.input_truncated,
            "applied": context.input_shaping_applied
        },
        "policies": {
            "worker_handoff": "shared_memory_xact_commit_latch",
            "stale_policy": "fail_closed_no_silent_stale_results",
            "cancellation_check_policy": LINKED_CANCELLATION_POLICY,
            "prompt_decode_cancellation_boundary": LINKED_PROMPT_DECODE_CANCELLATION_BOUNDARY
        }
    });
    summary
}

#[derive(Default)]
struct ProbabilityTrace {
    max_tokens: i64,
    sampled_tokens: i64,
    skipped_tokens: i64,
    chosen_probability_sum: f64,
    min_chosen_probability: f64,
    top_probability_sum: f64,
    top1_count: i64,
    worst_rank: i64,
    margin_to_top_sum: f64,
}

impl ProbabilityTrace {
    fn new(options: &crate::runtime::RuntimeOptions) -> Self {
        let max_tokens = if options.generation_trace {
            PROBABILITY_TRACE_MAX_TOKENS.min(options.generation_trace_max_tokens as i64)
        } else {
            0
        };
        Self {
            max_tokens,
            ..Self::default()
        }
    }

    fn wants_sample(&self) -> bool {
        self.max_tokens > 0 && self.sampled_tokens + self.skipped_tokens < self.max_tokens
    }

    fn observe(&mut self, sample: Option<&ProbabilitySample>) {
        if self.max_tokens > 0 && self.sampled_tokens + self.skipped_tokens >= self.max_tokens {
            self.skipped_tokens += 1;
            return;
        }
        let Some(sample) = sample else {
            self.skipped_tokens += 1;
            return;
        };
        self.sampled_tokens += 1;
        self.chosen_probability_sum += sample.chosen_probability;
        self.top_probability_sum += sample.top_probability;
        self.margin_to_top_sum += sample.top_logit - sample.chosen_logit;
        self.worst_rank = self.worst_rank.max(sample.rank);
        if sample.rank == 1 {
            self.top1_count += 1;
        }
        if self.min_chosen_probability == 0.0
            || sample.chosen_probability < self.min_chosen_probability
        {
            self.min_chosen_probability = sample.chosen_probability;
        }
    }

    fn summary(&self) -> Value {
        if self.max_tokens == 0 {
            return probability_unavailable("probability_trace_disabled_unless_generation_trace");
        }
        if self.sampled_tokens == 0 {
            return probability_unavailable("llama_logits_unavailable");
        }
        json!({
            "status": "available",
            "method": "chosen_token_softmax_from_llama_logits",
            "sampled_tokens": self.sampled_tokens,
            "max_sampled_tokens": self.max_tokens,
            "skipped_tokens": self.skipped_tokens,
            "avg_chosen_probability": rounded_probability(
                self.chosen_probability_sum / self.sampled_tokens as f64
            ),
            "min_chosen_probability": rounded_probability(self.min_chosen_probability),
            "avg_top_probability": rounded_probability(
                self.top_probability_sum / self.sampled_tokens as f64
            ),
            "top1_rate": rounded_probability(self.top1_count as f64 / self.sampled_tokens as f64),
            "worst_rank": self.worst_rank,
            "avg_margin_to_top_logit": rounded_probability(
                self.margin_to_top_sum / self.sampled_tokens as f64
            )
        })
    }
}

struct ProbabilitySample {
    chosen_probability: f64,
    chosen_logprob: f64,
    top_probability: f64,
    chosen_logit: f64,
    top_logit: f64,
    rank: i64,
    top_alternatives: Vec<TokenAlternative>,
}

#[derive(Clone)]
struct TokenAlternative {
    token_id: i64,
    token_text: String,
    logit: f64,
    probability: f64,
    logprob: f64,
    rank: i64,
}

unsafe fn probability_sample(
    context: *mut llama_cpp_sys_4::llama_context,
    vocab: *const llama_cpp_sys_4::llama_vocab,
    token: llama_cpp_sys_4::llama_token,
    top_k: u64,
) -> Option<ProbabilitySample> {
    unsafe {
        if context.is_null() || vocab.is_null() || token < 0 {
            return None;
        }
        let vocab_tokens = llama_cpp_sys_4::llama_vocab_n_tokens(vocab);
        if vocab_tokens <= 0 || token >= vocab_tokens {
            return None;
        }
        let logits = llama_cpp_sys_4::llama_get_logits_ith(context, -1);
        if logits.is_null() {
            return None;
        }
        let chosen_logit = *logits.add(token as usize) as f64;
        if !chosen_logit.is_finite() {
            return None;
        }

        let mut top_logit = f64::NEG_INFINITY;
        let mut denominator = 0.0_f64;
        let mut rank = 1_i64;
        let mut top: Vec<(i64, f64)> = Vec::new();
        let track_top = top_k > 0;
        for index in 0..vocab_tokens as usize {
            let logit = *logits.add(index) as f64;
            if !logit.is_finite() {
                continue;
            }
            if logit > chosen_logit {
                rank += 1;
            }
            if logit > top_logit {
                denominator = denominator * (top_logit - logit).exp() + 1.0;
                top_logit = logit;
            } else {
                denominator += (logit - top_logit).exp();
            }
            if track_top {
                push_top_logit(&mut top, top_k as usize, index as i64, logit);
            }
        }
        if !top_logit.is_finite() || denominator <= 0.0 || !denominator.is_finite() {
            return None;
        }

        let chosen_probability = ((chosen_logit - top_logit).exp() / denominator).max(0.0);
        let top_alternatives = if track_top {
            top.into_iter()
                .enumerate()
                .map(|(index, (token_id, logit))| {
                    let probability = ((logit - top_logit).exp() / denominator).max(0.0);
                    TokenAlternative {
                        token_id,
                        token_text: linked_token_to_piece(
                            vocab,
                            token_id as llama_cpp_sys_4::llama_token,
                        ),
                        logit: rounded_probability(logit),
                        probability: rounded_probability(probability),
                        logprob: rounded_probability(if probability > 0.0 {
                            probability.ln()
                        } else {
                            f64::NEG_INFINITY
                        }),
                        rank: index as i64 + 1,
                    }
                })
                .collect()
        } else {
            Vec::new()
        };

        Some(ProbabilitySample {
            chosen_probability,
            chosen_logprob: if chosen_probability > 0.0 {
                chosen_probability.ln()
            } else {
                f64::NEG_INFINITY
            },
            top_probability: 1.0 / denominator,
            chosen_logit,
            top_logit,
            rank,
            top_alternatives,
        })
    }
}

fn push_top_logit(top: &mut Vec<(i64, f64)>, limit: usize, token_id: i64, logit: f64) {
    if limit == 0 {
        return;
    }
    let insert_at = top.iter().position(|(_, existing)| logit > *existing);
    match insert_at {
        Some(index) => top.insert(index, (token_id, logit)),
        None if top.len() < limit => top.push((token_id, logit)),
        None => {}
    }
    top.truncate(limit);
}

struct DetailedGenerationTrace {
    enabled: bool,
    max_tokens: u64,
    top_k: u64,
    steps: Vec<Value>,
    skipped_tokens: u64,
    chosen_token_ids: Vec<i64>,
    chosen_text: String,
}

impl DetailedGenerationTrace {
    fn new(options: &crate::runtime::RuntimeOptions) -> Self {
        Self {
            enabled: options.generation_trace,
            max_tokens: options.generation_trace_max_tokens,
            top_k: options.generation_trace_top_k,
            steps: Vec::new(),
            skipped_tokens: 0,
            chosen_token_ids: Vec::new(),
            chosen_text: String::new(),
        }
    }

    fn wants_sample(&self) -> bool {
        self.enabled && (self.steps.len() as u64) < self.max_tokens
    }

    fn observe(
        &mut self,
        token: llama_cpp_sys_4::llama_token,
        token_text: &str,
        sample: Option<ProbabilitySample>,
    ) {
        if !self.enabled {
            return;
        }
        if self.steps.len() as u64 >= self.max_tokens {
            self.skipped_tokens += 1;
            return;
        }
        self.chosen_token_ids.push(token as i64);
        self.chosen_text.push_str(token_text);
        let step = self.steps.len() as i64 + 1;
        let trace = match sample {
            Some(sample) => json!({
                "step": step,
                "token_id": token as i64,
                "token_text": token_text,
                "chosen_logit": rounded_probability(sample.chosen_logit),
                "chosen_probability": rounded_probability(sample.chosen_probability),
                "chosen_logprob": rounded_probability(sample.chosen_logprob),
                "rank": sample.rank,
                "top_alternatives": sample.top_alternatives.into_iter().map(|alt| json!({
                    "rank": alt.rank,
                    "token_id": alt.token_id,
                    "token_text": alt.token_text,
                    "logit": alt.logit,
                    "probability": alt.probability,
                    "logprob": alt.logprob
                })).collect::<Vec<_>>()
            }),
            None => json!({
                "step": step,
                "token_id": token as i64,
                "token_text": token_text,
                "probability_status": "unavailable"
            }),
        };
        self.steps.push(trace);
    }

    fn summary(self, stop_reason: &str) -> Value {
        if !self.enabled {
            return json!({
                "status": "disabled",
                "trace_contract": DETAILED_TRACE_CONTRACT,
                "enable_option": "runtime_options.generation_trace=true",
                "storage_policy": DETAILED_TRACE_STORAGE_POLICY
            });
        }
        json!({
            "status": "available",
            "trace_contract": DETAILED_TRACE_CONTRACT,
            "storage_policy": DETAILED_TRACE_STORAGE_POLICY,
            "logprob_policy": "chosen_and_top_k_logprobs_from_llama_logits_softmax",
            "stop_reason": stop_reason,
            "max_tokens": self.max_tokens,
            "top_k": self.top_k,
            "captured_tokens": self.steps.len(),
            "skipped_tokens": self.skipped_tokens,
            "chosen_token_ids": self.chosen_token_ids,
            "chosen_text": self.chosen_text,
            "steps": self.steps
        })
    }
}

fn detailed_trace_unavailable(reason: &str, options: &crate::runtime::RuntimeOptions) -> Value {
    if !options.generation_trace {
        return json!({
            "status": "disabled",
            "trace_contract": DETAILED_TRACE_CONTRACT,
            "enable_option": "runtime_options.generation_trace=true",
            "storage_policy": DETAILED_TRACE_STORAGE_POLICY
        });
    }
    json!({
        "status": "unavailable",
        "reason": reason,
        "trace_contract": DETAILED_TRACE_CONTRACT,
        "storage_policy": DETAILED_TRACE_STORAGE_POLICY,
        "max_tokens": options.generation_trace_max_tokens,
        "top_k": options.generation_trace_top_k,
        "captured_tokens": 0,
        "skipped_tokens": 0,
        "steps": []
    })
}

fn rounded_probability(value: f64) -> f64 {
    if !value.is_finite() {
        return 0.0;
    }
    (value * 1_000_000.0).round() / 1_000_000.0
}

fn probability_unavailable(reason: &str) -> Value {
    json!({
        "status": "unavailable",
        "reason": reason
    })
}
