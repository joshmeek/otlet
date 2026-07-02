fn inference_cache_key(job: &Job, context: &RunContext) -> String {
    hash_text(
        format!(
            "task={}|subject={}|model={}|runtime={}|model_fingerprint={}|prompt={}|input={}|schema={}|options={}|content={}",
            job.task_name,
            job.subject_id,
            job.model_name,
            job.runtime_name,
            context.model_fingerprint_hash,
            context.prompt_hash,
            context.input_hash,
            context.output_schema_hash,
            context.runtime_options_hash,
            input_content_hash(&job.input)
        )
        .as_str(),
    )
}

fn inference_cache_row_key(job: &Job) -> String {
    hash_text(
        format!(
            "task={}|subject={}|model={}|row={}",
            job.task_name,
            job.subject_id,
            job.model_name,
            input_mvcc_row_identity(&job.input, &job.subject_id)
        )
        .as_str(),
    )
}

fn inference_cache_model_key(job: &Job, context: &RunContext) -> String {
    hash_text(
        format!(
            "model={}|runtime={}|fingerprint={}",
            job.model_name, job.runtime_name, context.model_fingerprint_hash
        )
        .as_str(),
    )
}

fn model_fingerprint(job: &Job) -> String {
    if let Some(hash) = job
        .artifact_hash
        .as_deref()
        .map(str::trim)
        .filter(|hash| !hash.is_empty())
    {
        return format!("catalog_hash:{hash}");
    }

    match fs::metadata(&job.artifact_path) {
        Ok(metadata) => {
            let modified_ms = metadata
                .modified()
                .ok()
                .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
                .map(|duration| duration.as_millis())
                .unwrap_or(0);
            format!(
                "local_file:path={}:bytes={}:mtime_ms={modified_ms}",
                job.artifact_path,
                metadata.len()
            )
        }
        Err(_) => format!("path_only:{}", job.artifact_path),
    }
}

fn input_content_hash(input: &Value) -> String {
    let mut content = input.clone();
    if let Value::Object(object) = &mut content {
        object.remove("_otlet_mvcc");
        object.remove("otlet_mvcc");
    }
    format!("{:x}", md5::compute(canonical_jsonb_text(&content)))
}

fn canonical_jsonb_text(value: &Value) -> String {
    match value {
        Value::Null => "null".to_owned(),
        Value::Bool(value) => value.to_string(),
        Value::Number(number) => canonical_number_text(number),
        Value::String(value) => serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_owned()),
        Value::Array(values) => {
            let values = values
                .iter()
                .map(canonical_jsonb_text)
                .collect::<Vec<_>>()
                .join(", ");
            format!("[{values}]")
        }
        Value::Object(object) => {
            let mut keys = object.keys().collect::<Vec<_>>();
            keys.sort();
            let fields = keys
                .into_iter()
                .filter_map(|key| {
                    object.get(key).map(|value| {
                        let key = serde_json::to_string(key).unwrap_or_else(|_| "\"\"".to_owned());
                        format!("{key}: {}", canonical_jsonb_text(value))
                    })
                })
                .collect::<Vec<_>>()
                .join(", ");
            format!("{{{fields}}}")
        }
    }
}

fn canonical_number_text(number: &serde_json::Number) -> String {
    if let Some(value) = number.as_i64() {
        return value.to_string();
    }
    if let Some(value) = number.as_u64() {
        return value.to_string();
    }
    let raw = number.to_string();
    let mut text = if raw.contains('e') || raw.contains('E') {
        raw.parse::<f64>()
            .ok()
            .filter(|value| value.is_finite())
            .map(|value| format!("{value}"))
            .unwrap_or(raw)
    } else {
        raw
    };
    if text.contains('.') {
        while text.ends_with('0') {
            text.pop();
        }
        if text.ends_with('.') {
            text.pop();
        }
    }
    if text == "-0" {
        text = "0".to_owned();
    }
    text
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_hash_matches_sql_sample() {
        let input: Value = serde_json::from_str(
            r#"{"_otlet_mvcc":{"xmin":"7","ctid":"(0,1)"},"b":1,"a":2}"#,
        )
        .expect("valid sample json");

        assert_eq!(
            input_content_hash(&input),
            "5e4d14d82c320bafb2f1286fe486d1f8"
        );
    }

    #[test]
    fn content_hash_ignores_mvcc_key_order_and_numeric_scale() {
        let left: Value = serde_json::from_str(
            r#"{"_otlet_mvcc":{"xmin":"1"},"outer":{"b":1.00,"a":[{"y":1.0,"x":true}]}}"#,
        )
        .expect("valid left json");
        let right: Value = serde_json::from_str(
            r#"{"outer":{"a":[{"x":true,"y":1e0}],"b":1}}"#,
        )
        .expect("valid right json");

        assert_eq!(input_content_hash(&left), input_content_hash(&right));
        assert_eq!(
            canonical_jsonb_text(&right),
            r#"{"outer": {"a": [{"x": true, "y": 1}], "b": 1}}"#
        );
    }
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

#[derive(Default, Clone, Copy)]
struct InferenceCacheStats {
    entries: i64,
    bytes: i64,
    evictions: i64,
}

struct InferenceCacheEntry {
    key: String,
    row_key: String,
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
}

fn inference_cache_get(key: &str, row_key: &str, model_key: &str) -> CacheLookup {
    let cache = INFERENCE_CACHE.get_or_init(|| Mutex::new(InferenceCache::default()));
    let mut cache = match cache.lock() {
        Ok(cache) => cache,
        Err(_) => {
            return CacheLookup {
                raw_output: None,
                reason: "lock_poisoned".to_owned(),
                stats: InferenceCacheStats::default(),
            };
        }
    };

    if let Some(index) = cache.entries.iter().position(|entry| entry.key == key) {
        let entry = cache.entries.remove(index);
        let raw_output = entry.raw_output.clone();
        cache.entries.push(entry);
        cache.hits += 1;
        return CacheLookup {
            raw_output: Some(raw_output),
            reason: "hit".to_owned(),
            stats: cache.stats(),
        };
    }

    cache.misses += 1;
    let reason = if cache
        .entries
        .iter()
        .any(|entry| entry.row_key == row_key && entry.model_key != model_key)
    {
        "model_fingerprint_changed"
    } else if cache.entries.iter().any(|entry| entry.row_key == row_key) {
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
    model_key: String,
    raw_output: String,
) -> InferenceCacheStats {
    let cache = INFERENCE_CACHE.get_or_init(|| Mutex::new(InferenceCache::default()));
    let mut cache = match cache.lock() {
        Ok(cache) => cache,
        Err(_) => return InferenceCacheStats::default(),
    };

    let bytes = key.len() + row_key.len() + model_key.len() + raw_output.len();
    if bytes > INFERENCE_CACHE_MAX_BYTES {
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
        let old = cache.entries.remove(0);
        cache.bytes = cache.bytes.saturating_sub(old.bytes);
        cache.evictions += 1;
    }

    cache.stats()
}

impl InferenceCache {
    fn stats(&self) -> InferenceCacheStats {
        InferenceCacheStats {
            entries: self.entries.len() as i64,
            bytes: self.bytes as i64,
            evictions: self.evictions,
        }
    }
}
