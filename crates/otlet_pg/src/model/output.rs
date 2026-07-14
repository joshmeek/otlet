struct ShapedPrompt {
    full: String,
    prompt_hash: String,
    input_hash: String,
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

fn shaped_model_prompt(input: &Value, prefix: &str) -> ShapedPrompt {
    with_shaped_input_bytes(input, |buf| {
        let shaped_input = std::str::from_utf8(buf).expect("serde_json writes UTF-8");
        let (bytes, original_bytes, input_truncated) = shaped_input_meta(input, buf.len());
        let prompt_hash = hash_text_parts(&[prefix, shaped_input, PROMPT_BODY_AFTER_INPUT]);
        let input_hash = hash_text(shaped_input);
        let mut full =
            String::with_capacity(prefix.len() + shaped_input.len() + PROMPT_BODY_AFTER_INPUT.len());
        full.push_str(prefix);
        full.push_str(shaped_input);
        full.push_str(PROMPT_BODY_AFTER_INPUT);
        ShapedPrompt {
            full,
            prompt_hash,
            input_hash,
            bytes,
            original_bytes,
            input_truncated,
        }
    })
}

/// Cache-hit path: same hashes/metadata as shaped_model_prompt
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
        let reasoning = prompt_reasoning_prefix(options);
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

struct DigestCacheEntry<T> {
    schema: Value,
    value: T,
    last_access: u64,
}

struct DigestCache<T> {
    entries: HashMap<String, DigestCacheEntry<T>>,
    access_clock: u64,
}

impl<T: Clone> DigestCache<T> {
    fn new() -> Self {
        Self {
            entries: HashMap::with_capacity(4),
            access_clock: 0,
        }
    }

    fn get(&mut self, digest: &str, schema: &Value) -> Option<T> {
        self.next_access();
        let entry = self.entries.get_mut(digest)?;
        if entry.schema != *schema {
            return None;
        }
        entry.last_access = self.access_clock;
        Some(entry.value.clone())
    }

    fn insert(&mut self, digest: &str, schema: &Value, value: T, max_entries: usize) {
        if self.entries.contains_key(digest) {
            return;
        }
        if self.entries.len() >= max_entries
            && let Some(oldest) = self
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.last_access)
                .map(|(key, _)| key.clone())
        {
            self.entries.remove(&oldest);
        }
        self.next_access();
        self.entries.insert(
            digest.to_owned(),
            DigestCacheEntry {
                schema: schema.clone(),
                value,
                last_access: self.access_clock,
            },
        );
    }

    fn next_access(&mut self) {
        if self.access_clock == u64::MAX {
            let mut order = self
                .entries
                .iter()
                .map(|(key, entry)| (key.clone(), entry.last_access))
                .collect::<Vec<_>>();
            order.sort_unstable_by_key(|(_, last_access)| *last_access);
            for (index, (key, _)) in order.into_iter().enumerate() {
                self.entries.get_mut(&key).unwrap().last_access = index as u64 + 1;
            }
            self.access_clock = self.entries.len() as u64;
        }
        self.access_clock += 1;
    }
}

fn validate_output(schema: &Value, schema_digest: &str, output: &Value) -> Result<(), String> {
    let validator = cached_schema_validator(schema, schema_digest)?;
    validator
        .validate(output)
        .map_err(|_| "output schema validation failed".to_owned())
}

fn validate_output_schema(schema: &Value, schema_digest: &str) -> Result<(), String> {
    cached_schema_validator(schema, schema_digest).map(|_| ())
}

/// Task schemas repeat across jobs; compiling a jsonschema validator per run
/// is wasted work, so keep a small LRU keyed by the exact schema
fn cached_schema_validator(schema: &Value, schema_digest: &str) -> Result<SchemaValidator, String> {
    static CACHE: OnceLock<Mutex<DigestCache<SchemaValidator>>> = OnceLock::new();

    let cache = CACHE.get_or_init(|| Mutex::new(DigestCache::new()));
    let mut cache = cache
        .lock()
        .map_err(|_| "schema validator cache lock poisoned".to_owned())?;
    if let Some(validator) = cache.get(schema_digest, schema) {
        return Ok(validator);
    }

    let validator = SchemaValidator::new(
        jsonschema::validator_for(schema).map_err(|err| format!("invalid output schema: {err}"))?,
    );
    cache.insert(
        schema_digest,
        schema,
        std::sync::Arc::clone(&validator),
        SCHEMA_VALIDATOR_CACHE_MAX_ENTRIES,
    );
    Ok(validator)
}

/// Response-envelope rendering is deterministic per output schema; reuse it
/// across batch jobs that share a task schema.
fn cached_rendered_schema(output_schema: &Value, schema_digest: &str) -> Arc<str> {
    static CACHE: OnceLock<Mutex<DigestCache<Arc<str>>>> = OnceLock::new();

    let cache = CACHE.get_or_init(|| Mutex::new(DigestCache::new()));
    let Ok(mut cache) = cache.lock() else {
        return Arc::from(response_envelope_schema(output_schema).to_string());
    };
    if let Some(rendered) = cache.get(schema_digest, output_schema) {
        return rendered;
    }

    let shared: Arc<str> = Arc::from(response_envelope_schema(output_schema).to_string());
    cache.insert(
        schema_digest,
        output_schema,
        Arc::clone(&shared),
        RENDERED_SCHEMA_CACHE_MAX_ENTRIES,
    );
    shared
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

#[derive(Clone, Default)]
struct ProcessMemorySample {
    rss_bytes: i64,
    virtual_bytes: i64,
    swap_bytes: i64,
    major_faults: i64,
    read_bytes: i64,
    system_memory_total_bytes: i64,
    system_memory_available_bytes: i64,
    system_swap_total_bytes: i64,
    system_swap_free_bytes: i64,
    memory_pressure_some_total_us: i64,
    memory_pressure_full_total_us: i64,
    memory_pressure_scope: &'static str,
    cgroup_memory_current_bytes: i64,
    cgroup_memory_max_bytes: i64,
    cgroup_swap_current_bytes: i64,
    cgroup_memory_high_events: i64,
    cgroup_memory_oom_events: i64,
    cgroup_memory_oom_kill_events: i64,
    policy: &'static str,
}

fn process_memory_sample() -> ProcessMemorySample {
    let status = fs::read_to_string("/proc/self/status").unwrap_or_default();
    let stat = fs::read_to_string("/proc/self/stat").unwrap_or_default();
    let io = fs::read_to_string("/proc/self/io").unwrap_or_default();
    let meminfo = fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let cgroup = fs::read_to_string("/proc/self/cgroup").unwrap_or_default();
    let cgroup_path = cgroup_v2_relative(&cgroup).map(|relative| {
        std::path::Path::new("/sys/fs/cgroup").join(relative.trim_start_matches('/'))
    });
    let cgroup_file = |name: &str| {
        cgroup_path
            .as_ref()
            .and_then(|path| fs::read_to_string(path.join(name)).ok())
    };
    let cgroup_pressure = cgroup_file("memory.pressure");
    let system_pressure = fs::read_to_string("/proc/pressure/memory").ok();
    let (pressure, memory_pressure_scope) = if let Some(pressure) = cgroup_pressure.as_deref() {
        (pressure, "cgroup_v2_memory_pressure")
    } else if let Some(pressure) = system_pressure.as_deref() {
        (pressure, "system_memory_pressure")
    } else {
        ("", "memory_pressure_unavailable")
    };
    let cgroup_events = cgroup_file("memory.events").unwrap_or_default();
    let rss_bytes = proc_kib(&status, "VmRSS:").unwrap_or(0);
    let virtual_bytes = proc_kib(&status, "VmSize:").unwrap_or(0);
    let policy = if rss_bytes > 0 && virtual_bytes > 0 {
        "linux_proc_self_and_optional_cgroup_v2_memory_pressure_v1"
    } else {
        "proc_self_status_unavailable_or_missing_vmrss_vmsize"
    };
    ProcessMemorySample {
        rss_bytes,
        virtual_bytes,
        swap_bytes: proc_kib(&status, "VmSwap:").unwrap_or(0),
        major_faults: proc_stat_major_faults(&stat).unwrap_or(0),
        read_bytes: keyed_i64(&io, "read_bytes:").unwrap_or(0),
        system_memory_total_bytes: proc_kib(&meminfo, "MemTotal:").unwrap_or(0),
        system_memory_available_bytes: proc_kib(&meminfo, "MemAvailable:").unwrap_or(0),
        system_swap_total_bytes: proc_kib(&meminfo, "SwapTotal:").unwrap_or(0),
        system_swap_free_bytes: proc_kib(&meminfo, "SwapFree:").unwrap_or(0),
        memory_pressure_some_total_us: psi_total_us(pressure, "some").unwrap_or(0),
        memory_pressure_full_total_us: psi_total_us(pressure, "full").unwrap_or(0),
        memory_pressure_scope,
        cgroup_memory_current_bytes: cgroup_file("memory.current")
            .as_deref()
            .and_then(parse_memory_value)
            .unwrap_or(0),
        cgroup_memory_max_bytes: cgroup_file("memory.max")
            .as_deref()
            .and_then(parse_memory_value)
            .unwrap_or(0),
        cgroup_swap_current_bytes: cgroup_file("memory.swap.current")
            .as_deref()
            .and_then(parse_memory_value)
            .unwrap_or(0),
        cgroup_memory_high_events: keyed_i64(&cgroup_events, "high").unwrap_or(0),
        cgroup_memory_oom_events: keyed_i64(&cgroup_events, "oom").unwrap_or(0),
        cgroup_memory_oom_kill_events: keyed_i64(&cgroup_events, "oom_kill").unwrap_or(0),
        policy,
    }
}

fn proc_kib(contents: &str, label: &str) -> Option<i64> {
    let line = contents.lines().find(|line| line.starts_with(label))?;
    let kib = line.split_whitespace().nth(1)?.parse::<u64>().ok()?;
    Some(u64_to_i64_saturating(kib.saturating_mul(1024)))
}

fn keyed_i64(contents: &str, key: &str) -> Option<i64> {
    let line = contents.lines().find(|line| line.starts_with(key))?;
    let value = line.split_whitespace().nth(1)?.parse::<u64>().ok()?;
    Some(u64_to_i64_saturating(value))
}

fn proc_stat_major_faults(stat: &str) -> Option<i64> {
    let (_, fields) = stat.rsplit_once(") ")?;
    let value = fields.split_whitespace().nth(9)?.parse::<u64>().ok()?;
    Some(u64_to_i64_saturating(value))
}

fn psi_total_us(contents: &str, kind: &str) -> Option<i64> {
    let line = contents
        .lines()
        .find(|line| line.split_whitespace().next() == Some(kind))?;
    let total = line
        .split_whitespace()
        .find_map(|field| field.strip_prefix("total="))?
        .parse::<u64>()
        .ok()?;
    Some(u64_to_i64_saturating(total))
}

fn cgroup_v2_relative(cgroup: &str) -> Option<&str> {
    cgroup.lines().find_map(|line| {
        let mut parts = line.splitn(3, ':');
        if parts.next()? == "0" && parts.next()?.is_empty() {
            parts.next()
        } else {
            None
        }
    })
}

fn parse_memory_value(value: &str) -> Option<i64> {
    let value = value.trim();
    if value == "max" {
        return Some(0);
    }
    Some(u64_to_i64_saturating(value.parse::<u64>().ok()?))
}

fn counter_delta(before: i64, after: i64) -> i64 {
    after.saturating_sub(before).max(0)
}

impl ProcessMemorySample {
    fn supports_preload_admission(&self) -> bool {
        self.rss_bytes > 0
            && self.system_memory_total_bytes > 0
            && self.system_memory_available_bytes > 0
    }

    fn as_json(&self) -> Value {
        json!({
            "process_rss_bytes": self.rss_bytes,
            "process_virtual_bytes": self.virtual_bytes,
            "process_swap_bytes": self.swap_bytes,
            "process_major_faults": self.major_faults,
            "process_read_bytes": self.read_bytes,
            "system_memory_total_bytes": self.system_memory_total_bytes,
            "system_memory_available_bytes": self.system_memory_available_bytes,
            "system_swap_total_bytes": self.system_swap_total_bytes,
            "system_swap_free_bytes": self.system_swap_free_bytes,
            "memory_pressure_some_total_us": self.memory_pressure_some_total_us,
            "memory_pressure_full_total_us": self.memory_pressure_full_total_us,
            "memory_pressure_scope": self.memory_pressure_scope,
            "cgroup_memory_current_bytes": self.cgroup_memory_current_bytes,
            "cgroup_memory_max_bytes": self.cgroup_memory_max_bytes,
            "cgroup_swap_current_bytes": self.cgroup_swap_current_bytes,
            "cgroup_memory_high_events": self.cgroup_memory_high_events,
            "cgroup_memory_oom_events": self.cgroup_memory_oom_events,
            "cgroup_memory_oom_kill_events": self.cgroup_memory_oom_kill_events,
            "sample_policy": self.policy
        })
    }
}

struct ModelLoadAdmission {
    decision: &'static str,
    reason: &'static str,
    policy: &'static str,
    artifact_bytes: i64,
    worker_budget_bytes: i64,
    worker_budget_headroom_bytes: i64,
    system_available_headroom_bytes: i64,
    cgroup_headroom_bytes: i64,
    allowed_additional_bytes: i64,
    projected_model_bytes: i64,
    projected_context_kv_bytes: i64,
    projected_batch_compute_bytes: i64,
    projected_total_bytes: i64,
    llama_projected_fit: bool,
}

impl ModelLoadAdmission {
    fn not_required(
        reason: &'static str,
        worker_budget_bytes: u64,
        sample: &ProcessMemorySample,
    ) -> Self {
        Self {
            decision: "not_required",
            reason,
            policy: "linked_llama_no_alloc_model_kv_batch_projection_v1",
            artifact_bytes: 0,
            worker_budget_bytes: u64_to_i64_saturating(worker_budget_bytes),
            worker_budget_headroom_bytes: u64_to_i64_saturating(worker_budget_bytes)
                .saturating_sub(sample.rss_bytes)
                .max(0),
            system_available_headroom_bytes: sample.system_memory_available_bytes,
            cgroup_headroom_bytes: cgroup_memory_headroom(sample),
            allowed_additional_bytes: 0,
            projected_model_bytes: 0,
            projected_context_kv_bytes: 0,
            projected_batch_compute_bytes: 0,
            projected_total_bytes: 0,
            llama_projected_fit: false,
        }
    }

    fn rejected(&self) -> bool {
        self.decision == "rejected"
    }

    fn as_json(&self) -> Value {
        json!({
            "decision": self.decision,
            "reason": self.reason,
            "policy": self.policy,
            "artifact_bytes": self.artifact_bytes,
            "worker_budget_bytes": self.worker_budget_bytes,
            "worker_budget_headroom_bytes": self.worker_budget_headroom_bytes,
            "system_available_headroom_bytes": self.system_available_headroom_bytes,
            "cgroup_headroom_bytes": self.cgroup_headroom_bytes,
            "allowed_additional_bytes": self.allowed_additional_bytes,
            "projected_model_bytes": self.projected_model_bytes,
            "projected_context_kv_bytes": self.projected_context_kv_bytes,
            "projected_batch_compute_bytes": self.projected_batch_compute_bytes,
            "projected_total_bytes": self.projected_total_bytes,
            "llama_projected_fit": self.llama_projected_fit
        })
    }
}

fn cgroup_memory_headroom(sample: &ProcessMemorySample) -> i64 {
    if sample.cgroup_memory_max_bytes > 0 {
        sample
            .cgroup_memory_max_bytes
            .saturating_sub(sample.cgroup_memory_current_bytes)
            .max(0)
    } else {
        0
    }
}

fn build_memory_trace(
    before: &ProcessMemorySample,
    after: &ProcessMemorySample,
    admission: &ModelLoadAdmission,
    max_worker_rss_bytes: u64,
) -> Value {
    json!({
        "model_device_policy": LINKED_MODEL_DEVICE_POLICY,
        "memory_accounting_policy": LINKED_MEMORY_ACCOUNTING_POLICY,
        "worker_memory_sample_policy": after.policy,
        "worker_memory_budget_bytes": u64_to_i64_saturating(max_worker_rss_bytes),
        "worker_memory_budget_policy": worker_memory_budget_policy(max_worker_rss_bytes),
        "before": before.as_json(),
        "after": after.as_json(),
        "delta": {
            "process_major_faults": counter_delta(before.major_faults, after.major_faults),
            "process_read_bytes": counter_delta(before.read_bytes, after.read_bytes),
            "memory_pressure_some_total_us": counter_delta(
                before.memory_pressure_some_total_us,
                after.memory_pressure_some_total_us
            ),
            "memory_pressure_full_total_us": counter_delta(
                before.memory_pressure_full_total_us,
                after.memory_pressure_full_total_us
            ),
            "cgroup_memory_high_events": counter_delta(
                before.cgroup_memory_high_events,
                after.cgroup_memory_high_events
            ),
            "cgroup_memory_oom_events": counter_delta(
                before.cgroup_memory_oom_events,
                after.cgroup_memory_oom_events
            ),
            "cgroup_memory_oom_kill_events": counter_delta(
                before.cgroup_memory_oom_kill_events,
                after.cgroup_memory_oom_kill_events
            )
        },
        "admission": admission.as_json()
    })
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
            artifact_hash: Some("artifact".to_owned()),
            model_name: "test_model".to_owned(),
            runtime_options: json!({"reasoning": "off"}),
            input_shaping: json!({"include": ["value"]}),
            decision_contract: json!({"answer_field": "decision"}),
            max_attempt_ms: 30_000,
            claim_attempt: 1,
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
        changed.artifact_hash = Some("other_artifact".to_owned());
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

struct TaskContractDigests {
    instruction: String,
    runtime_options: Result<crate::runtime::RuntimeOptions, String>,
    output_schema_hash: String,
    runtime_options_hash: String,
    runtime_options_status: Value,
    decision_contract_hash: String,
    decision_preset_name: String,
    decision_preset_contract_hash: String,
    inference_cache_contract_hash: String,
    prompt_prefix: OnceLock<Arc<str>>,
}

const TASK_CONTRACT_CACHE_MAX_ENTRIES: usize = 16;

struct TaskContractCacheEntry {
    task_name: String,
    instruction: String,
    output_schema: Value,
    runtime_options: Value,
    input_shaping: Value,
    decision_contract: Value,
    model_name: String,
    artifact_path: String,
    artifact_hash: Option<String>,
    digests: Arc<TaskContractDigests>,
}

impl TaskContractCacheEntry {
    fn matches(&self, job: &Job) -> bool {
        self.task_name == job.task_name
            && self.instruction == job.instruction
            && self.output_schema == job.output_schema
            && self.runtime_options == job.runtime_options
            && self.input_shaping == job.input_shaping
            && self.decision_contract == job.decision_contract
            && self.model_name == job.model_name
            && self.artifact_path == job.artifact_path
            && self.artifact_hash == job.artifact_hash
    }
}

struct TaskContractCache {
    entries: Vec<TaskContractCacheEntry>,
}

impl TaskContractCache {
    fn new() -> Self {
        Self {
            entries: Vec::with_capacity(TASK_CONTRACT_CACHE_MAX_ENTRIES),
        }
    }

    fn get(&mut self, job: &Job) -> Option<Arc<TaskContractDigests>> {
        let index = self.entries.iter().position(|entry| entry.matches(job))?;
        let entry = self.entries.remove(index);
        let digests = Arc::clone(&entry.digests);
        self.entries.insert(0, entry);
        Some(digests)
    }

    fn insert(&mut self, job: &Job, digests: Arc<TaskContractDigests>) {
        self.entries
            .retain(|entry| entry.task_name != job.task_name);
        self.entries.insert(
            0,
            TaskContractCacheEntry {
                task_name: job.task_name.clone(),
                instruction: job.instruction.clone(),
                output_schema: job.output_schema.clone(),
                runtime_options: job.runtime_options.clone(),
                input_shaping: job.input_shaping.clone(),
                decision_contract: job.decision_contract.clone(),
                model_name: job.model_name.clone(),
                artifact_path: job.artifact_path.clone(),
                artifact_hash: job.artifact_hash.clone(),
                digests,
            },
        );
        if self.entries.len() > TASK_CONTRACT_CACHE_MAX_ENTRIES {
            self.entries.pop();
        }
    }
}

thread_local! {
    // Worker-lifetime exact-contract LRU; stores no job input or model output
    static TASK_CONTRACT_DIGESTS: RefCell<TaskContractCache> =
        RefCell::new(TaskContractCache::new());
}

fn cached_prompt_prefix(
    digests: &TaskContractDigests,
    options: &crate::runtime::RuntimeOptions,
    instruction: &str,
    rendered_schema: &str,
) -> Arc<str> {
    Arc::clone(digests.prompt_prefix.get_or_init(|| {
        Arc::from(prompt_prefix(options, instruction, rendered_schema))
    }))
}

fn task_contract_digests(job: &Job) -> Arc<TaskContractDigests> {
    TASK_CONTRACT_DIGESTS.with(|cell| {
        let mut cache = cell.borrow_mut();
        if let Some(cached) = cache.get(job) {
            return cached;
        }
        let digests = Arc::new(build_task_contract_digests(job));
        cache.insert(job, Arc::clone(&digests));
        digests
    })
}

fn build_task_contract_digests(job: &Job) -> TaskContractDigests {
    let instruction = effective_instruction(&job.instruction, &job.decision_contract);
    let runtime_options = parse_runtime_options(&job.runtime_options);
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
    TaskContractDigests {
        instruction,
        runtime_options,
        output_schema_hash,
        runtime_options_hash,
        runtime_options_status,
        decision_contract_hash,
        decision_preset_name,
        decision_preset_contract_hash,
        inference_cache_contract_hash,
        prompt_prefix: OnceLock::new(),
    }
}
