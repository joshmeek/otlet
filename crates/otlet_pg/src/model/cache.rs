fn inference_cache_key(row_key: &str, model_key: &str) -> String {
    hash_text_parts(&["row=", row_key, "|model=", model_key])
}

fn inference_cache_content_key(job: &Job, context: &RunContext) -> String {
    hash_text_parts(&[
        "task=",
        &job.task_name,
        "|subject=",
        &job.subject_id,
        "|content=",
        &context.input_content_hash,
    ])
}

fn inference_cache_contract_key(context: &RunContext) -> String {
    hash_text_parts(&["contract=", &context.inference_cache_contract_hash])
}

fn inference_cache_row_key(content_key: &str, contract_key: &str) -> String {
    hash_text_parts(&["content=", content_key, "|contract=", contract_key])
}

fn inference_cache_contract_hash(
    job: &Job,
    instruction_hash: &str,
    output_schema_hash: &str,
    runtime_options_hash: &str,
    input_shaping_hash: &str,
    decision_contract_hash: &str,
) -> String {
    hash_text_parts(&[
        "task=",
        &job.task_name,
        "|instruction=",
        instruction_hash,
        "|schema=",
        output_schema_hash,
        "|options=",
        runtime_options_hash,
        "|input_shaping=",
        input_shaping_hash,
        "|decision_contract=",
        decision_contract_hash,
    ])
}

fn inference_cache_model_key(model: JobModelRef<'_>, context: &RunContext) -> String {
    hash_text_parts(&[
        "model=",
        model.name,
        "|fingerprint=",
        &context.model_fingerprint_hash,
    ])
}

fn model_fingerprint_hash(model: JobModelRef<'_>) -> Arc<str> {
    if let Some(hash) = model
        .artifact_hash
        .map(str::trim)
        .filter(|hash| !hash.is_empty())
    {
        return Arc::<str>::from(hash_text_parts(&["catalog_hash:", hash]));
    }

    #[derive(Clone)]
    struct FingerprintMeta {
        modified_ms: u128,
        bytes: u64,
        hash: Arc<str>,
    }

    static FINGERPRINT_CACHE: OnceLock<Mutex<HashMap<String, FingerprintMeta>>> = OnceLock::new();

    let metadata = match fs::metadata(model.artifact_path) {
        Ok(metadata) => metadata,
        Err(_) => {
            return Arc::<str>::from(hash_text_parts(&["path_only:", model.artifact_path]));
        }
    };
    let modified_ms = metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |duration| duration.as_millis());
    let bytes = metadata.len();

    let cache = FINGERPRINT_CACHE.get_or_init(|| Mutex::new(HashMap::with_capacity(32)));
    if let Ok(mut cache) = cache.lock() {
        if let Some(cached) = cache.get(model.artifact_path)
            && cached.modified_ms == modified_ms
            && cached.bytes == bytes
        {
            return Arc::clone(&cached.hash);
        }

        let hash = local_file_fingerprint(model.artifact_path, modified_ms, bytes);
        let shared = Arc::<str>::from(hash);
        if cache.len() >= 32 {
            // Drop an arbitrary entry; process-local and rebuilt from metadata
            cache.drain().next();
        }
        cache.insert(
            model.artifact_path.to_owned(),
            FingerprintMeta {
                modified_ms,
                bytes,
                hash: Arc::clone(&shared),
            },
        );
        return shared;
    }

    Arc::<str>::from(local_file_fingerprint(
        model.artifact_path,
        modified_ms,
        bytes,
    ))
}

fn local_file_fingerprint(path: &str, modified_ms: u128, bytes: u64) -> String {
    let bytes_text = bytes.to_string();
    let modified_text = modified_ms.to_string();
    hash_text_parts(&[
        "local_file:path=",
        path,
        ":bytes=",
        &bytes_text,
        ":mtime_ms=",
        &modified_text,
    ])
}

fn input_mvcc_row_identity(input: &Value, subject_id: &str) -> String {
    let Some(Value::Object(mvcc)) = input.get("_otlet_mvcc").or_else(|| input.get("otlet_mvcc"))
    else {
        return subject_id.to_owned();
    };

    let table = mvcc
        .get("table")
        .or_else(|| mvcc.get("relid"))
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let row = mvcc
        .get("subject_id")
        .or_else(|| mvcc.get("id"))
        .or_else(|| mvcc.get("pk"))
        .and_then(Value::as_str)
        .unwrap_or(subject_id);
    // Keep human-readable table:row for receipt/trace identity
    let mut identity = String::with_capacity(table.len() + row.len() + 1);
    identity.push_str(table);
    identity.push(':');
    identity.push_str(row);
    identity
}

fn input_mvcc_payload(input: &Value) -> Value {
    input
        .get("_otlet_mvcc")
        .or_else(|| input.get("otlet_mvcc"))
        .cloned()
        .unwrap_or(Value::Null)
}

struct CacheLookup {
    raw_output: Option<Arc<str>>,
    reason: &'static str,
    stats: InferenceCacheStats,
}

impl CacheLookup {
    fn disabled() -> Self {
        Self::disabled_for("disabled")
    }

    fn disabled_for(reason: &'static str) -> Self {
        Self {
            raw_output: None,
            reason,
            stats: InferenceCacheStats::default(),
        }
    }
}

#[derive(Clone)]
struct InferenceCacheStats {
    entries: i64,
    bytes: i64,
    evictions: i64,
    eviction_reason: &'static str,
}

impl Default for InferenceCacheStats {
    fn default() -> Self {
        Self {
            entries: 0,
            bytes: 0,
            evictions: 0,
            eviction_reason: "none",
        }
    }
}

struct InferenceCacheEntry {
    key: String,
    row_key: String,
    content_key: String,
    contract_key: String,
    model_key: String,
    raw_output: Arc<str>,
    bytes: usize,
}

struct InferenceCache {
    entries: Vec<InferenceCacheEntry>,
    key_index: HashMap<String, usize>,
    bytes: usize,
    hits: i64,
    misses: i64,
    evictions: i64,
    last_eviction_reason: &'static str,
}

impl Default for InferenceCache {
    fn default() -> Self {
        Self {
            entries: Vec::with_capacity(32),
            key_index: HashMap::with_capacity(32),
            bytes: 0,
            hits: 0,
            misses: 0,
            evictions: 0,
            last_eviction_reason: "none",
        }
    }
}

impl InferenceCache {
    fn promote_to_mru(&mut self, index: usize) {
        if index + 1 >= self.entries.len() {
            return;
        }
        let entry = self.entries.remove(index);
        for shifted in &self.entries[index..] {
            if let Some(idx) = self.key_index.get_mut(&shifted.key) {
                *idx = idx.saturating_sub(1);
            }
        }
        let new_index = self.entries.len();
        self.key_index.insert(entry.key.clone(), new_index);
        self.entries.push(entry);
    }

    fn remove_at(&mut self, index: usize) -> InferenceCacheEntry {
        let entry = self.entries.remove(index);
        self.key_index.remove(&entry.key);
        self.bytes = self.bytes.saturating_sub(entry.bytes);
        for shifted in &self.entries[index..] {
            if let Some(idx) = self.key_index.get_mut(&shifted.key) {
                *idx = idx.saturating_sub(1);
            }
        }
        entry
    }
}

fn inference_cache_get(
    key: &str,
    row_key: &str,
    content_key: &str,
    contract_key: &str,
    model_key: &str,
) -> CacheLookup {
    let cache = INFERENCE_CACHE.get_or_init(|| Mutex::new(InferenceCache::default()));
    let Ok(mut cache) = cache.lock() else {
        return CacheLookup {
            raw_output: None,
            reason: "lock_poisoned",
            stats: InferenceCacheStats::default(),
        };
    };

    if let Some(&index) = cache.key_index.get(key) {
        let raw_output = Arc::clone(&cache.entries[index].raw_output);
        cache.promote_to_mru(index);
        cache.hits += 1;
        return CacheLookup {
            raw_output: Some(raw_output),
            reason: "hit",
            stats: cache.stats(),
        };
    }

    cache.misses += 1;
    let mut row_model_changed = false;
    let mut row_seen = false;
    for entry in &cache.entries {
        if entry.content_key == content_key && entry.contract_key != contract_key {
            return CacheLookup {
                raw_output: None,
                reason: "contract_changed",
                stats: cache.stats(),
            };
        }
        if entry.row_key == row_key {
            row_seen = true;
            if entry.model_key != model_key {
                row_model_changed = true;
            }
        }
    }

    let reason = if row_model_changed {
        "model_fingerprint_changed"
    } else if row_seen {
        "row_version_changed"
    } else {
        "not_found"
    };
    CacheLookup {
        raw_output: None,
        reason,
        stats: cache.stats(),
    }
}

fn inference_cache_put(
    key: String,
    row_key: String,
    content_key: String,
    contract_key: String,
    model_key: String,
    raw_output: String,
) -> InferenceCacheStats {
    let cache = INFERENCE_CACHE.get_or_init(|| Mutex::new(InferenceCache::default()));
    let Ok(mut cache) = cache.lock() else {
        return InferenceCacheStats::default();
    };

    let bytes = key.len()
        + row_key.len()
        + content_key.len()
        + contract_key.len()
        + model_key.len()
        + raw_output.len();
    if bytes > INFERENCE_CACHE_MAX_BYTES {
        cache.last_eviction_reason = "entry_too_large";
        return cache.stats();
    }

    if let Some(&index) = cache.key_index.get(&key) {
        let _ = cache.remove_at(index);
    }

    cache.bytes += bytes;
    let index = cache.entries.len();
    let raw_output = Arc::<str>::from(raw_output);
    cache.key_index.insert(key.clone(), index);
    cache.entries.push(InferenceCacheEntry {
        key,
        row_key,
        content_key,
        contract_key,
        model_key,
        raw_output,
        bytes,
    });

    while cache.entries.len() > INFERENCE_CACHE_MAX_ENTRIES
        || cache.bytes > INFERENCE_CACHE_MAX_BYTES
    {
        if cache.entries.is_empty() {
            break;
        }
        cache.last_eviction_reason = if cache.entries.len() > INFERENCE_CACHE_MAX_ENTRIES {
            "entry_count_limit"
        } else {
            "byte_limit"
        };
        let _ = cache.remove_at(0);
        cache.evictions += 1;
    }

    cache.stats()
}

impl InferenceCache {
    fn stats(&self) -> InferenceCacheStats {
        InferenceCacheStats {
            entries: usize_to_i64_saturating(self.entries.len()),
            bytes: usize_to_i64_saturating(self.bytes),
            evictions: self.evictions,
            eviction_reason: self.last_eviction_reason,
        }
    }
}

fn inference_cache_max_entries() -> i64 {
    usize_to_i64_saturating(INFERENCE_CACHE_MAX_ENTRIES)
}

fn inference_cache_max_bytes() -> i64 {
    usize_to_i64_saturating(INFERENCE_CACHE_MAX_BYTES)
}
