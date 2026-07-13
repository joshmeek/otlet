const RUNTIME_FINGERPRINT_VERSION: &str = "otlet_runtime_fingerprint_v1";
const PROMPT_TEMPLATE_NAME: &str = "otlet_raw_json_worker_v1";
const LLAMA_CPP_SYS_VERSION: &str = "0.3.1";
const LLAMA_CPP_REVISION: &str = "94a220cd6";

struct RuntimeFingerprint {
    document: Value,
    hash: String,
    output_contract_hash: String,
}

fn runtime_fingerprint(
    model: JobModelRef<'_>,
    model_fingerprint_hash: &str,
    options: &crate::runtime::RuntimeOptions,
) -> RuntimeFingerprint {
    let batch_tokens = linked_prompt_batch_tokens();
    let ubatch_tokens = linked_prompt_ubatch_tokens(batch_tokens);
    let decode_threads = linked_decode_threads(options);
    let batch_threads = linked_batch_threads(options, decode_threads);
    let (kv_type_k, kv_type_v) = fingerprint_kv_types();
    let prompt_template_hash = hash_text_parts(&[
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
            "tokens": LINKED_CONTEXT_WINDOW_TOKENS,
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
            "bytes": fs::metadata(model.artifact_path).map(|meta| meta.len()).unwrap_or(0),
            "catalog_hash": model.artifact_hash,
            "fingerprint_hash": model_fingerprint_hash,
            "quantization": artifact_quantization(artifact_name),
            "quantization_source": "artifact_filename_bound_by_fingerprint"
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
    }).clone()
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
    fn output_contract_hash_is_stable_and_scoped() {
        let model = JobModelRef {
            name: "test",
            artifact_path: "/not/read",
            artifact_hash: Some("catalog-hash"),
        };
        let options = crate::runtime::RuntimeOptions::default();
        let first = runtime_fingerprint(model, "model-hash", &options);
        let second = runtime_fingerprint(model, "model-hash", &options);
        let mut changed_options = crate::runtime::RuntimeOptions::default();
        changed_options.llama_threads = 2;
        let changed = runtime_fingerprint(model, "model-hash", &changed_options);
        let mut changed_host = first.document.clone();
        changed_host["host"]["memory_bytes"] = json!(1);

        assert_eq!(first.hash, second.hash);
        assert_eq!(first.output_contract_hash, second.output_contract_hash);
        assert_ne!(first.output_contract_hash, changed.output_contract_hash);
        assert_ne!(first.hash, hash_json(&changed_host));
        assert_eq!(
            first.output_contract_hash,
            changed_host["output_contract_hash"].as_str().unwrap()
        );
    }

    #[test]
    fn quantization_comes_from_common_gguf_names() {
        assert_eq!(artifact_quantization("Qwen3.5-4B-Q4_K_M.gguf"), "Q4_K_M");
        assert_eq!(artifact_quantization("model-IQ4_XS-00001-of-00002.gguf"), "IQ4_XS");
        assert_eq!(artifact_quantization("model.gguf"), "artifact_bound_unknown");
    }
}
