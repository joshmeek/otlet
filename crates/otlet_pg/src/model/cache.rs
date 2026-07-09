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

fn inference_cache_model_key(job: &Job, context: &RunContext) -> String {
    hash_text_parts(&[
        "model=",
        &job.model_name,
        "|fingerprint=",
        &context.model_fingerprint_hash,
    ])
}

fn model_fingerprint_hash(job: &Job) -> String {
    if let Some(hash) = job
        .artifact_hash
        .as_deref()
        .map(str::trim)
        .filter(|hash| !hash.is_empty())
    {
        return hash_text_parts(&["catalog_hash:", hash]);
    }

    fs::metadata(&job.artifact_path).map_or_else(
        |_| hash_text_parts(&["path_only:", &job.artifact_path]),
        |metadata| {
            let modified_ms = metadata
                .modified()
                .ok()
                .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |duration| duration.as_millis());
            let bytes = metadata.len().to_string();
            let modified_ms = modified_ms.to_string();
            hash_text_parts(&[
                "local_file:path=",
                &job.artifact_path,
                ":bytes=",
                &bytes,
                ":mtime_ms=",
                &modified_ms,
            ])
        },
    )
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
    format!("{table}:{row}")
}

fn input_mvcc_payload(input: &Value) -> Value {
    input
        .get("_otlet_mvcc")
        .or_else(|| input.get("otlet_mvcc"))
        .cloned()
        .unwrap_or(Value::Null)
}

struct CacheLookup {
    raw_output: Option<String>,
    reason: String,
    stats: InferenceCacheStats,
}

impl CacheLookup {
    fn disabled() -> Self {
        Self::disabled_for("disabled")
    }

    fn disabled_for(reason: &str) -> Self {
        Self {
            raw_output: None,
            reason: reason.to_owned(),
            stats: InferenceCacheStats::default(),
        }
    }
}

#[derive(Clone)]
struct InferenceCacheStats {
    entries: i64,
    bytes: i64,
    evictions: i64,
    eviction_reason: String,
}

impl Default for InferenceCacheStats {
    fn default() -> Self {
        Self {
            entries: 0,
            bytes: 0,
            evictions: 0,
            eviction_reason: "none".to_owned(),
        }
    }
}

struct InferenceCacheEntry {
    key: String,
    row_key: String,
    content_key: String,
    contract_key: String,
    model_key: String,
    raw_output: String,
    bytes: usize,
}

#[derive(Default)]
struct InferenceCache {
    entries: Vec<InferenceCacheEntry>,
    bytes: usize,
    hits: i64,
    misses: i64,
    evictions: i64,
    last_eviction_reason: String,
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
            reason: "lock_poisoned".to_owned(),
            stats: InferenceCacheStats::default(),
        };
    };

    if let Some(index) = cache.entries.iter().position(|entry| entry.key == key) {
        let raw_output = cache.entries[index].raw_output.clone();
        if index + 1 < cache.entries.len() {
            let entry = cache.entries.remove(index);
            cache.entries.push(entry);
        }
        cache.hits += 1;
        return CacheLookup {
            raw_output: Some(raw_output),
            reason: "hit".to_owned(),
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
                reason: "contract_changed".to_owned(),
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
        reason: reason.to_owned(),
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
        "entry_too_large".clone_into(&mut cache.last_eviction_reason);
        return cache.stats();
    }

    if let Some(index) = cache.entries.iter().position(|entry| entry.key == key) {
        let old = cache.entries.remove(index);
        cache.bytes = cache.bytes.saturating_sub(old.bytes);
    }

    cache.bytes += bytes;
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
        if cache.entries.len() > INFERENCE_CACHE_MAX_ENTRIES {
            "entry_count_limit"
        } else {
            "byte_limit"
        }
        .clone_into(&mut cache.last_eviction_reason);
        let old = cache.entries.remove(0);
        cache.bytes = cache.bytes.saturating_sub(old.bytes);
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
            eviction_reason: if self.last_eviction_reason.is_empty() {
                "none".to_owned()
            } else {
                self.last_eviction_reason.clone()
            },
        }
    }
}

fn inference_cache_max_entries() -> i64 {
    usize_to_i64_saturating(INFERENCE_CACHE_MAX_ENTRIES)
}

fn inference_cache_max_bytes() -> i64 {
    usize_to_i64_saturating(INFERENCE_CACHE_MAX_BYTES)
}
