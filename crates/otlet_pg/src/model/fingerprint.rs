use pgrx::{IntoDatum, JsonB, pg_guard, pg_sys};

const RUNTIME_FINGERPRINT_VERSION: &str = "otlet_runtime_fingerprint_v1";
const PROMPT_TEMPLATE_NAME: &str = "otlet_raw_json_worker_v1";
const LLAMA_CPP_SYS_VERSION: &str = "0.3.1";
const LLAMA_CPP_REVISION: &str = "94a220cd6";

static OTLET_LINKED_RUNTIME_CAPABILITIES_FINFO: pg_sys::Pg_finfo_record =
    pg_sys::Pg_finfo_record { api_version: 1 };

fn linked_runtime_capabilities() -> Value {
    let batch_tokens = linked_prompt_batch_tokens();
    json!({
        "version": "otlet_runtime_capabilities_v1",
        "supported_runtime_options": crate::runtime::SUPPORTED_RUNTIME_OPTIONS,
        "schema_behavior": {
            "input": "postgres_jsonb_shaped_snapshot",
            "response": "json_object_output_actions_envelope",
            "decode_constraint": LINKED_DECODE_CONSTRAINT,
            "validation": "runtime_then_postgres_authoritative_json_schema_subset",
            "unsupported_schema": "rejected_at_task_registration",
            "supported_types": [
                "object", "array", "string", "number", "integer", "boolean", "null"
            ],
            "supported_keywords": [
                "$schema", "$id", "title", "description", "default", "examples",
                "type", "enum", "const", "required", "properties",
                "additionalProperties", "items", "minLength", "maxLength", "minimum",
                "maximum", "exclusiveMinimum", "exclusiveMaximum", "minItems",
                "maxItems", "minProperties", "maxProperties"
            ],
            "additional_properties": "boolean_only",
            "items": "one_schema"
        },
        "context_limits": {
            "context_window_tokens": LINKED_CONTEXT_WINDOW_TOKENS,
            "physical_context_quantum_tokens": LINKED_CONTEXT_WINDOW_QUANTUM_TOKENS,
            "model_context_window_source": "artifact_identity.context_window_tokens",
            "task_context_window_option": "context_window_tokens_optional_lte_model_limit",
            "batch_tokens": batch_tokens,
            "ubatch_tokens": linked_prompt_ubatch_tokens(batch_tokens),
            "max_generation_tokens": 4096
        },
        "cancellation": {
            "policy": LINKED_CANCELLATION_POLICY,
            "prompt_decode_boundary": LINKED_PROMPT_DECODE_CANCELLATION_BOUNDARY,
            "observation_slice_ms": LINKED_CANCELLATION_SLICE_MS
        },
        "tracing": {
            "summary": "otlet_generation_trace_v1",
            "detailed": DETAILED_TRACE_CONTRACT,
            "generation_trace": "optional",
            "max_tokens": 256,
            "max_top_k": 16,
            "storage": DETAILED_TRACE_STORAGE_POLICY
        },
        "artifact_formats": {
            "accepted": ["gguf"],
            "verification": "sha256_verified_open_regular_file_descriptor",
            "symlinks": "rejected"
        },
        "runtime_build": {
            "engine": "llama.cpp",
            "crate": "llama-cpp-sys-4",
            "crate_version": LLAMA_CPP_SYS_VERSION,
            "revision": LLAMA_CPP_REVISION,
            "features": {
                "native": cfg!(feature = "native"),
                "openmp": cfg!(feature = "openmp")
            }
        },
        "device_settings": {
            "policy": LINKED_MODEL_DEVICE_POLICY,
            "gpu_layers": 0,
            "mmap": linked_env_bool("OTLET_LLAMA_MMAP", true),
            "mlock": linked_env_bool("OTLET_LLAMA_MLOCK", false),
            "flash_attention": fingerprint_flash_attention()
        },
        "resource_admission": {
            "budget_option": "max_worker_rss_bytes",
            "default_max_worker_rss_bytes": crate::runtime::DEFAULT_MAX_WORKER_RSS_BYTES,
            "memory_accounting": LINKED_MEMORY_ACCOUNTING_POLICY,
            "load_policy": "one_resident_model_preflight_before_tensor_allocation",
            "request_projection_policy": "linked_prompt_token_output_piece_batch_prefix_state_projection_v1",
            "request_projection_evidence": [
                "prompt_tokens",
                "max_generation_tokens",
                "projected_prompt_bytes",
                "projected_decode_bytes",
                "projected_prompt_prefix_state_bytes",
                "decision",
                "reason"
            ],
            "required_evidence": [
                "artifact_bytes",
                "worker_rss",
                "system_available_memory",
                "cgroup_memory"
            ]
        },
        "database_operations": {
            "transaction_timeout_ms": crate::worker::DATABASE_TRANSACTION_TIMEOUT_MS,
            "lock_timeout_ms": crate::worker::DATABASE_LOCK_TIMEOUT_MS,
            "scope": "native_worker_session",
            "covered_operations": [
                "claim", "sweep", "renewal", "receipt", "completion", "materialization"
            ],
            "timeout_recovery": "transaction_rollback_worker_restart_lease_reclaim"
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn pg_finfo_otlet_linked_runtime_capabilities()
-> *const pg_sys::Pg_finfo_record {
    &raw const OTLET_LINKED_RUNTIME_CAPABILITIES_FINFO
}

#[pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn otlet_linked_runtime_capabilities(
    _fcinfo: pg_sys::FunctionCallInfo,
) -> pg_sys::Datum {
    JsonB(linked_runtime_capabilities()).into_datum().unwrap()
}

struct RuntimeFingerprint {
    document: Value,
    hash: String,
    output_contract_hash: String,
}

fn runtime_fingerprint(
    model: JobModelRef<'_>,
    model_fingerprint_hash: &str,
    verified_artifact_sha256: &str,
    verified_artifact_bytes: u64,
    options: &crate::runtime::RuntimeOptions,
    context_budget: ModelContextBudget,
) -> RuntimeFingerprint {
    let batch_tokens = linked_prompt_batch_tokens();
    let ubatch_tokens = linked_prompt_ubatch_tokens(batch_tokens);
    let decode_threads = linked_decode_threads(options);
    let batch_threads = linked_batch_threads(options, decode_threads);
    let (kv_type_k, kv_type_v) = fingerprint_kv_types();
    let prompt_template_hash = hash_text_parts(&[
        prompt_reasoning_prefix(options),
        PROMPT_BODY_BEFORE_INSTRUCTION,
        PROMPT_BODY_BEFORE_SCHEMA,
        PROMPT_BODY_BEFORE_INPUT,
        PROMPT_BODY_AFTER_INPUT,
    ]);
    let output_contract = json!({
        "version": RUNTIME_FINGERPRINT_VERSION,
        "model_fingerprint_hash": model_fingerprint_hash,
        "prompt_template": {
            "name": PROMPT_TEMPLATE_NAME,
            "hash": prompt_template_hash,
            "reasoning": options.reasoning
        },
        "decode_constraint": LINKED_DECODE_CONSTRAINT,
        "llama_cpp": {
            "crate": "llama-cpp-sys-4",
            "crate_version": LLAMA_CPP_SYS_VERSION,
            "revision": LLAMA_CPP_REVISION,
            "native": cfg!(feature = "native"),
            "openmp": cfg!(feature = "openmp"),
            "target_arch": std::env::consts::ARCH
        },
        "context": {
            "tokens": context_budget.tested,
            "tested_context_window_tokens": context_budget.tested,
            "requested_context_window_tokens": context_budget.requested,
            "effective_context_window_tokens": context_budget.effective,
            "physical_context_window_tokens": context_budget.physical,
            "batch_tokens": batch_tokens,
            "ubatch_tokens": ubatch_tokens,
            "kv_type_k": ggml_type_name(kv_type_k),
            "kv_type_v": ggml_type_name(kv_type_v),
            "flash_attention": fingerprint_flash_attention(),
            "decode_threads": decode_threads,
            "batch_threads": batch_threads
        }
    });
    let output_contract_hash = hash_json(&output_contract);
    let artifact_name = std::path::Path::new(model.artifact_path)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(model.artifact_path);
    let document = json!({
        "version": RUNTIME_FINGERPRINT_VERSION,
        "output_contract_hash": output_contract_hash,
        "output_contract": output_contract,
        "artifact": {
            "name": artifact_name,
            "bytes": verified_artifact_bytes,
            "sha256": verified_artifact_sha256,
            "identity": model.artifact_identity,
            "verification": "sha256_verified_file_descriptor_load",
            "fingerprint_hash": model_fingerprint_hash,
            "quantization": model.artifact_identity
                .get("quantization")
                .and_then(Value::as_str)
                .unwrap_or_else(|| artifact_quantization(artifact_name)),
            "quantization_source": "registered_identity_bound_by_verified_sha256"
        },
        "runtime": {
            "device_policy": LINKED_MODEL_DEVICE_POLICY,
            "memory_accounting_policy": LINKED_MEMORY_ACCOUNTING_POLICY,
            "mmap": linked_env_bool("OTLET_LLAMA_MMAP", true),
            "mlock": linked_env_bool("OTLET_LLAMA_MLOCK", false),
            "perf_counters": !linked_env_bool("OTLET_LLAMA_NO_PERF", true),
            "openmp_affinity": environment_value("OMP_PROC_BIND"),
            "openmp_places": environment_value("OMP_PLACES"),
            "gomp_cpu_affinity": environment_value("GOMP_CPU_AFFINITY")
        },
        "host": host_fingerprint()
    });
    let hash = hash_json(&document);
    RuntimeFingerprint {
        document,
        hash,
        output_contract_hash,
    }
}

fn environment_value(name: &str) -> Value {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map_or(Value::Null, Value::String)
}

fn artifact_quantization(artifact_name: &str) -> &str {
    artifact_name
        .split('-')
        .rev()
        .map(|part| part.trim_end_matches(".gguf"))
        .find(|part| {
            let upper = part.as_bytes();
            matches!(upper, [b'Q', b'0'..=b'9', ..])
                || part.starts_with("IQ")
                || part.starts_with("TQ")
                || matches!(*part, "F16" | "F32" | "BF16")
        })
        .unwrap_or("artifact_bound_unknown")
}

fn ggml_type_name(value: llama_cpp_sys_4::ggml_type) -> &'static str {
    match value {
        llama_cpp_sys_4::GGML_TYPE_F16 => "f16",
        llama_cpp_sys_4::GGML_TYPE_Q8_0 => "q8_0",
        llama_cpp_sys_4::GGML_TYPE_Q4_0 => "q4_0",
        _ => "other",
    }
}

fn fingerprint_flash_attention() -> &'static str {
    match std::env::var("OTLET_LLAMA_FLASH_ATTN").as_deref() {
        Ok("1" | "true" | "on" | "yes" | "enabled") => "enabled",
        Ok("0" | "false" | "off" | "no" | "disabled") => "disabled",
        _ => "auto",
    }
}

fn fingerprint_kv_types() -> (llama_cpp_sys_4::ggml_type, llama_cpp_sys_4::ggml_type) {
    let both = std::env::var("OTLET_LLAMA_KV_TYPE")
        .ok()
        .and_then(|value| linked_ggml_type(&value));
    let key = std::env::var("OTLET_LLAMA_KV_TYPE_K")
        .ok()
        .and_then(|value| linked_ggml_type(&value))
        .or(both)
        .unwrap_or(llama_cpp_sys_4::GGML_TYPE_F16);
    let value = std::env::var("OTLET_LLAMA_KV_TYPE_V")
        .ok()
        .and_then(|value| linked_ggml_type(&value))
        .or(both)
        .unwrap_or(llama_cpp_sys_4::GGML_TYPE_F16);
    (key, value)
}

fn host_fingerprint() -> Value {
    static HOST: OnceLock<Value> = OnceLock::new();
    HOST.get_or_init(|| {
        json!({
            "architecture": std::env::consts::ARCH,
            "available_parallelism": std::thread::available_parallelism()
                .map(std::num::NonZero::get)
                .unwrap_or(0),
            "online_cpus": read_trimmed("/sys/devices/system/cpu/online"),
            "numa_nodes": read_trimmed("/sys/devices/system/node/online"),
            "memory_bytes": meminfo_bytes("MemTotal"),
            "swap_bytes": meminfo_bytes("SwapTotal")
        })
    })
    .clone()
}

fn read_trimmed(path: &str) -> Value {
    fs::read_to_string(path)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .map_or(Value::Null, Value::String)
}

fn meminfo_bytes(field: &str) -> u64 {
    let Ok(meminfo) = fs::read_to_string("/proc/meminfo") else {
        return 0;
    };
    meminfo
        .lines()
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            (name == field).then(|| {
                value
                    .split_whitespace()
                    .next()
                    .and_then(|value| value.parse::<u64>().ok())
                    .unwrap_or(0)
                    .saturating_mul(1024)
            })
        })
        .unwrap_or(0)
}

#[cfg(test)]
mod runtime_fingerprint_tests {
    use super::*;

    #[test]
    fn capabilities_advertise_model_bound_context_and_request_projection() {
        let capabilities = linked_runtime_capabilities();
        assert_eq!(
            capabilities["context_limits"]["model_context_window_source"],
            "artifact_identity.context_window_tokens"
        );
        assert_eq!(
            capabilities["context_limits"]["task_context_window_option"],
            "context_window_tokens_optional_lte_model_limit"
        );
        assert_eq!(
            capabilities["context_limits"]["physical_context_quantum_tokens"],
            LINKED_CONTEXT_WINDOW_QUANTUM_TOKENS
        );
        assert_eq!(
            capabilities["resource_admission"]["request_projection_policy"],
            "linked_prompt_token_output_piece_batch_prefix_state_projection_v1"
        );
        assert_eq!(
            capabilities["resource_admission"]["request_projection_evidence"],
            json!([
                "prompt_tokens",
                "max_generation_tokens",
                "projected_prompt_bytes",
                "projected_decode_bytes",
                "projected_prompt_prefix_state_bytes",
                "decision",
                "reason"
            ])
        );
        assert_eq!(
            capabilities["database_operations"],
            json!({
                "transaction_timeout_ms": 10_000,
                "lock_timeout_ms": 1_000,
                "scope": "native_worker_session",
                "covered_operations": [
                    "claim", "sweep", "renewal", "receipt", "completion", "materialization"
                ],
                "timeout_recovery": "transaction_rollback_worker_restart_lease_reclaim"
            })
        );
    }

    #[test]
    fn output_contract_hash_is_stable_and_scoped() {
        let identity = json!({
            "sha256": "1111111111111111111111111111111111111111111111111111111111111111",
            "bytes": 24,
            "source": "test",
            "revision": "v1",
            "quantization": "test",
            "license": "test"
        });
        let model = JobModelRef {
            name: "test",
            artifact_path: "/not/read",
            artifact_hash: identity.get("sha256").and_then(Value::as_str).unwrap(),
            artifact_identity: &identity,
        };
        let options = crate::runtime::RuntimeOptions::default();
        let context_budget = model_context_budget(&identity, &options)
            .unwrap_or_else(|err| panic!("{}", err.message));
        let first = runtime_fingerprint(
            model,
            "model-hash",
            model.artifact_hash,
            24,
            &options,
            context_budget,
        );
        let second = runtime_fingerprint(
            model,
            "model-hash",
            model.artifact_hash,
            24,
            &options,
            context_budget,
        );
        let narrowed_options = crate::runtime::RuntimeOptions {
            context_window_tokens: Some(1024),
            ..Default::default()
        };
        let narrowed_budget = model_context_budget(&identity, &narrowed_options)
            .unwrap_or_else(|err| panic!("{}", err.message));
        let narrowed = runtime_fingerprint(
            model,
            "model-hash",
            model.artifact_hash,
            24,
            &narrowed_options,
            narrowed_budget,
        );
        let mut changed_options = crate::runtime::RuntimeOptions::default();
        changed_options.llama_threads = 2;
        let changed = runtime_fingerprint(
            model,
            "model-hash",
            model.artifact_hash,
            24,
            &changed_options,
            context_budget,
        );
        let mut reasoning_on = crate::runtime::RuntimeOptions::default();
        reasoning_on.reasoning = "on";
        let reasoning_on = runtime_fingerprint(
            model,
            "model-hash",
            model.artifact_hash,
            24,
            &reasoning_on,
            context_budget,
        );
        let mut changed_host = first.document.clone();
        changed_host["host"]["memory_bytes"] = json!(1);
        let changed_identity = json!({
            "sha256": "2222222222222222222222222222222222222222222222222222222222222222",
            "bytes": 24,
            "source": "test",
            "revision": "v2",
            "quantization": "test",
            "license": "test"
        });
        let changed_artifact = runtime_fingerprint(
            JobModelRef {
                artifact_hash: changed_identity
                    .get("sha256")
                    .and_then(Value::as_str)
                    .unwrap(),
                artifact_identity: &changed_identity,
                ..model
            },
            "changed-model-hash",
            changed_identity
                .get("sha256")
                .and_then(Value::as_str)
                .unwrap(),
            24,
            &options,
            context_budget,
        );

        assert_eq!(first.hash, second.hash);
        assert_eq!(
            first.document["output_contract"]["context"]["effective_context_window_tokens"],
            LINKED_CONTEXT_WINDOW_TOKENS
        );
        assert_eq!(
            narrowed.document["output_contract"]["context"]["requested_context_window_tokens"],
            1024
        );
        assert_eq!(
            narrowed.document["output_contract"]["context"]["effective_context_window_tokens"],
            1024
        );
        assert_eq!(
            narrowed.document["output_contract"]["context"]["physical_context_window_tokens"],
            LINKED_CONTEXT_WINDOW_TOKENS
        );
        assert_ne!(first.output_contract_hash, narrowed.output_contract_hash);
        assert_eq!(first.output_contract_hash, second.output_contract_hash);
        assert_ne!(first.output_contract_hash, changed.output_contract_hash);
        assert_ne!(
            first.document["output_contract"]["prompt_template"]["hash"],
            reasoning_on.document["output_contract"]["prompt_template"]["hash"]
        );
        assert_ne!(first.hash, hash_json(&changed_host));
        assert_ne!(first.hash, changed_artifact.hash);
        assert_eq!(
            first.output_contract_hash,
            changed_host["output_contract_hash"].as_str().unwrap()
        );
    }

    #[test]
    fn quantization_comes_from_common_gguf_names() {
        assert_eq!(artifact_quantization("Qwen3.5-4B-Q4_K_M.gguf"), "Q4_K_M");
        assert_eq!(
            artifact_quantization("model-IQ4_XS-00001-of-00002.gguf"),
            "IQ4_XS"
        );
        assert_eq!(
            artifact_quantization("model.gguf"),
            "artifact_bound_unknown"
        );
    }
}
