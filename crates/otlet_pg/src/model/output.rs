struct ShapedInput {
    serialized: String,
    bytes: i64,
    original_bytes: i64,
    input_truncated: bool,
}

thread_local! {
    // Reuse across jobs so large inputs avoid repeated growth reallocs
    // (worker is single-threaded).
    static SHAPED_INPUT_BYTES: RefCell<Vec<u8>> =
        RefCell::new(Vec::with_capacity(8192));
}

fn with_shaped_input_bytes<R>(input: &Value, f: impl FnOnce(&[u8]) -> R) -> R {
    SHAPED_INPUT_BYTES.with(|cell| {
        let mut buf = cell.borrow_mut();
        buf.clear();
        serde_json::to_writer(&mut *buf, input)
            .expect("serde_json Value serialization cannot fail");
        f(&buf)
    })
}

fn shaped_input_meta(input: &Value, serialized_len: usize) -> (i64, i64, bool) {
    let bytes = usize_to_i64_saturating(serialized_len);
    let original_bytes = input
        .get("original_shaped_input_bytes")
        .and_then(Value::as_i64)
        .unwrap_or(bytes);
    let input_truncated = input
        .get("_otlet_input_truncated")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    (bytes, original_bytes, input_truncated)
}

fn shaped_model_input(input: &Value) -> ShapedInput {
    let serialized = with_shaped_input_bytes(input, |buf| {
        // One exact-sized String alloc; TLS keeps capacity for the next job.
        std::str::from_utf8(buf)
            .expect("serde_json writes UTF-8")
            .to_owned()
    });
    let (bytes, original_bytes, input_truncated) = shaped_input_meta(input, serialized.len());
    ShapedInput {
        serialized,
        bytes,
        original_bytes,
        input_truncated,
    }
}

/// Cache-hit path: same hashes/metadata as shaped_model_input + hash_prompt_full
/// without allocating the shaped JSON String or prompt prefix String.
fn shaped_prompt_hashes_for_cache_hit(
    options: &crate::runtime::RuntimeOptions,
    instruction: &str,
    rendered_schema: &str,
    input: &Value,
) -> (String, String, i64, i64, bool) {
    with_shaped_input_bytes(input, |shaped_bytes| {
        let shaped_text = std::str::from_utf8(shaped_bytes).expect("serde_json writes UTF-8");
        let input_hash = hash_text(shaped_text);
        let (bytes, original_bytes, input_truncated) = shaped_input_meta(input, shaped_bytes.len());
        let reasoning = if options.reasoning == "off" {
            "/no_think "
        } else {
            ""
        };
        // Same byte sequence as prompt_prefix(...) + shaped + PROMPT_BODY_AFTER_INPUT.
        let prompt_hash = hash_text_parts(&[
            reasoning,
            PROMPT_BODY_BEFORE_INSTRUCTION,
            instruction,
            PROMPT_BODY_BEFORE_SCHEMA,
            rendered_schema,
            PROMPT_BODY_BEFORE_INPUT,
            shaped_text,
            PROMPT_BODY_AFTER_INPUT,
        ]);
        (
            prompt_hash,
            input_hash,
            bytes,
            original_bytes,
            input_truncated,
        )
    })
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

const SCHEMA_VALIDATOR_CACHE_MAX_ENTRIES: usize = 16;
const RENDERED_SCHEMA_CACHE_MAX_ENTRIES: usize = 16;
type SchemaValidator = std::sync::Arc<jsonschema::Validator>;
type SchemaValidatorCache = Vec<(Value, SchemaValidator)>;
type RenderedSchemaCache = Vec<(Value, std::sync::Arc<str>)>;

fn validate_output(schema: &Value, output: &Value) -> Result<(), String> {
    let validator = cached_schema_validator(schema)?;
    validator
        .validate(output)
        .map_err(|err| format!("output schema validation failed: {err}"))
}

fn validate_output_schema(schema: &Value) -> Result<(), String> {
    cached_schema_validator(schema).map(|_| ())
}

/// Task schemas repeat across jobs; compiling a jsonschema validator per run
/// is wasted work, so keep a small LRU keyed by the exact schema
fn cached_schema_validator(schema: &Value) -> Result<SchemaValidator, String> {
    static CACHE: OnceLock<Mutex<SchemaValidatorCache>> = OnceLock::new();

    let cache = CACHE.get_or_init(|| {
        Mutex::new(Vec::with_capacity(SCHEMA_VALIDATOR_CACHE_MAX_ENTRIES))
    });
    let mut cache = cache
        .lock()
        .map_err(|_| "schema validator cache lock poisoned".to_owned())?;
    if let Some(index) = cache.iter().position(|(cached, _)| cached == schema) {
        let validator = std::sync::Arc::clone(&cache[index].1);
        if index + 1 < cache.len() {
            let entry = cache.remove(index);
            cache.push(entry);
        }
        drop(cache);
        return Ok(validator);
    }

    let validator = SchemaValidator::new(
        jsonschema::validator_for(schema).map_err(|err| format!("invalid output schema: {err}"))?,
    );
    cache.push((schema.clone(), std::sync::Arc::clone(&validator)));
    if cache.len() > SCHEMA_VALIDATOR_CACHE_MAX_ENTRIES {
        cache.remove(0);
    }
    drop(cache);
    Ok(validator)
}

/// Response-envelope rendering is deterministic per output schema; reuse it
/// across batch jobs that share a task schema.
fn cached_rendered_schema(output_schema: &Value) -> Arc<str> {
    static CACHE: OnceLock<Mutex<RenderedSchemaCache>> = OnceLock::new();

    let cache = CACHE.get_or_init(|| {
        Mutex::new(Vec::with_capacity(RENDERED_SCHEMA_CACHE_MAX_ENTRIES))
    });
    let Ok(mut cache) = cache.lock() else {
        return Arc::from(response_envelope_schema(output_schema).to_string());
    };
    if let Some(index) = cache
        .iter()
        .position(|(cached, _)| cached == output_schema)
    {
        let rendered = Arc::clone(&cache[index].1);
        if index + 1 < cache.len() {
            let entry = cache.remove(index);
            cache.push(entry);
        }
        return rendered;
    }

    let shared: Arc<str> = Arc::from(response_envelope_schema(output_schema).to_string());
    cache.push((output_schema.clone(), Arc::clone(&shared)));
    if cache.len() > RENDERED_SCHEMA_CACHE_MAX_ENTRIES {
        cache.remove(0);
    }
    shared
}

fn trim_error(text: &str) -> String {
    const MAX_ERROR_CHARS: usize = 2000;
    if text.len() <= MAX_ERROR_CHARS {
        return text.to_owned();
    }
    let mut out = String::with_capacity(MAX_ERROR_CHARS);
    out.extend(text.chars().take(MAX_ERROR_CHARS));
    out
}

fn elapsed_ms(start: Instant) -> i64 {
    i64::try_from(start.elapsed().as_millis()).unwrap_or(i64::MAX)
}

fn u64_to_i64_saturating(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn usize_to_i64_saturating(value: usize) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn u64_to_i32_saturating(value: u64) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

fn usize_to_i32_saturating(value: usize) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

fn usize_to_u32_saturating(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

const fn worker_memory_budget_policy(max_worker_rss_bytes: u64) -> &'static str {
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
    if u64::try_from(sample.rss_bytes).unwrap_or(0) > max_worker_rss_bytes {
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

struct ProcessMemorySample {
    rss_bytes: i64,
    virtual_bytes: i64,
    policy: &'static str,
}

fn process_memory_sample() -> ProcessMemorySample {
    fs::read_to_string("/proc/self/status").map_or_else(
        |_| ProcessMemorySample {
            rss_bytes: 0,
            virtual_bytes: 0,
            policy: "proc_self_status_unavailable_non_linux_or_permission_denied",
        },
        |status| {
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
                policy,
            }
        },
    )
}

fn proc_status_kib(status: &str, label: &str) -> Option<i64> {
    let line = status.lines().find(|line| line.starts_with(label))?;
    let kib = line.split_whitespace().nth(1)?.parse::<u64>().ok()?;
    Some(u64_to_i64_saturating(kib.saturating_mul(1024)))
}

struct FnvWriter {
    hash: u64,
}

impl FnvWriter {
    const fn new() -> Self {
        Self {
            hash: 0xcbf2_9ce4_8422_2325_u64,
        }
    }

    fn finish(self) -> String {
        let mut out = String::with_capacity(16);
        use std::fmt::Write as _;
        let _ = write!(out, "{:016x}", self.hash);
        out
    }

    fn write_bytes(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.hash ^= u64::from(*byte);
            self.hash = self.hash.wrapping_mul(0x0100_0000_01b3);
        }
    }
}

impl std::io::Write for FnvWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.write_bytes(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn hash_json(value: &Value) -> String {
    let mut writer = FnvWriter::new();
    // Stream JSON bytes into the hasher; same fingerprint as hashing Display output
    if serde_json::to_writer(&mut writer, value).is_err() {
        return hash_text(&value.to_string());
    }
    writer.finish()
}

fn hash_text(text: &str) -> String {
    hash_text_parts(&[text])
}

fn hash_text_parts(parts: &[&str]) -> String {
    let mut writer = FnvWriter::new();
    for part in parts {
        writer.write_bytes(part.as_bytes());
    }
    writer.finish()
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

        normalized.push(action);
    }

    Ok(Value::Array(normalized))
}

fn parse_model_json(raw_output: &str) -> Result<Value, String> {
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

    Ok(value)
}

struct TaskContractDigests {
    instruction: String,
    output_schema_hash: String,
    runtime_options_hash: String,
    runtime_options_status: Value,
    decision_contract_hash: String,
    decision_preset_name: String,
    decision_preset_contract_hash: String,
    inference_cache_contract_hash: String,
}

thread_local! {
    // Batch-lifetime only: cleared at the start of each process_job(_batch).
    // Avoids re-hashing identical per-task contract fields across claim drains.
    static TASK_CONTRACT_DIGESTS: RefCell<HashMap<String, Arc<TaskContractDigests>>> =
        RefCell::new(HashMap::with_capacity(4));
    // Same lifetime: reuse the large static prompt prefix across jobs of one task.
    static TASK_PROMPT_PREFIXES: RefCell<HashMap<String, Arc<str>>> =
        RefCell::new(HashMap::with_capacity(4));
}

pub(crate) fn clear_task_contract_digests() {
    TASK_CONTRACT_DIGESTS.with(|cell| cell.borrow_mut().clear());
    TASK_PROMPT_PREFIXES.with(|cell| cell.borrow_mut().clear());
}

fn cached_prompt_prefix(
    task_name: &str,
    options: &crate::runtime::RuntimeOptions,
    instruction: &str,
    rendered_schema: &str,
    output_schema_hash: &str,
) -> Arc<str> {
    let reasoning_off = options.reasoning == "off";
    let mut key =
        String::with_capacity(task_name.len() + output_schema_hash.len() + 8);
    key.push_str(task_name);
    key.push('|');
    key.push_str(output_schema_hash);
    key.push('|');
    key.push(if reasoning_off { '0' } else { '1' });
    TASK_PROMPT_PREFIXES.with(|cell| {
        let mut map = cell.borrow_mut();
        if let Some(cached) = map.get(&key) {
            return Arc::clone(cached);
        }
        let prefix = Arc::<str>::from(prompt_prefix(options, instruction, rendered_schema));
        map.insert(key, Arc::clone(&prefix));
        prefix
    })
}

fn task_contract_digests(job: &Job) -> Arc<TaskContractDigests> {
    TASK_CONTRACT_DIGESTS.with(|cell| {
        let mut map = cell.borrow_mut();
        if let Some(cached) = map.get(&job.task_name) {
            return Arc::clone(cached);
        }
        let instruction = effective_instruction(&job.instruction, &job.decision_contract);
        let instruction_hash = hash_text(&instruction);
        let output_schema_hash = hash_json(&job.output_schema);
        let runtime_options_hash = hash_json(&job.runtime_options);
        let runtime_options_status = runtime_option_status(&job.runtime_options);
        let input_shaping_hash = hash_json(&job.input_shaping);
        let decision_contract_hash = hash_json(&job.decision_contract);
        let decision_preset_name = job
            .decision_contract
            .get("preset")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let decision_preset_contract_hash = job
            .decision_contract
            .get("preset_contract_hash")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let inference_cache_contract_hash = inference_cache_contract_hash(
            job,
            &instruction_hash,
            &output_schema_hash,
            &runtime_options_hash,
            &input_shaping_hash,
            &decision_contract_hash,
        );
        let digests = Arc::new(TaskContractDigests {
            instruction,
            output_schema_hash,
            runtime_options_hash,
            runtime_options_status,
            decision_contract_hash,
            decision_preset_name,
            decision_preset_contract_hash,
            inference_cache_contract_hash,
        });
        map.insert(job.task_name.clone(), Arc::clone(&digests));
        digests
    })
}
