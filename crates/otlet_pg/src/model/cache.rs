fn inference_cache_key(content_key: u64, contract_key: u64, model_key: u64) -> u64 {
    hash_bytes_parts_u64(&[
        b"content=",
        &content_key.to_le_bytes(),
        b"|contract=",
        &contract_key.to_le_bytes(),
        b"|model=",
        &model_key.to_le_bytes(),
    ])
}

fn inference_cache_content_key(job: &Job, context: &RunContext) -> u64 {
    hash_bytes_parts_u64(&[
        b"task=",
        job.task_name.as_bytes(),
        b"|subject=",
        job.subject_id.as_bytes(),
        b"|content=",
        context.input_content_hash.as_bytes(),
    ])
}

fn inference_cache_contract_key(context: &RunContext) -> u64 {
    hash_bytes_parts_u64(&[
        b"contract=",
        context.inference_cache_contract_hash.as_bytes(),
        b"|runtime_output_contract=",
        context.runtime_output_contract_hash.as_bytes(),
    ])
}

fn inference_cache_row_key(job: &Job) -> u64 {
    hash_bytes_parts_u64(&[
        b"task=",
        job.task_name.as_bytes(),
        b"|subject=",
        job.subject_id.as_bytes(),
    ])
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

fn inference_cache_model_key(model: JobModelRef<'_>, context: &RunContext) -> u64 {
    hash_bytes_parts_u64(&[
        b"model=",
        model.name.as_bytes(),
        b"|fingerprint=",
        context.model_fingerprint_hash.as_bytes(),
    ])
}

fn model_fingerprint_hash(model: JobModelRef<'_>) -> Arc<str> {
    if let Some(hash) = model
        .artifact_hash
        .map(str::trim)
        .filter(|hash| !hash.is_empty())
    {
        thread_local! {
            static CATALOG_FINGERPRINT_CACHE: RefCell<HashMap<String, Arc<str>>> =
                RefCell::new(HashMap::with_capacity(4));
        }
        return CATALOG_FINGERPRINT_CACHE.with(|cell| {
            let mut cache = cell.borrow_mut();
            if let Some(cached) = cache.get(hash) {
                return Arc::clone(cached);
            }
            let fingerprint = Arc::<str>::from(hash_text_parts(&["catalog_hash:", hash]));
            if cache.len() >= 32 {
                cache.drain().next();
            }
            cache.insert(hash.to_owned(), Arc::clone(&fingerprint));
            fingerprint
        });
    }

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
    fn disabled_for(reason: &'static str) -> Self {
        Self {
            raw_output: None,
            reason,
            stats: InferenceCacheStats::default(),
        }
    }
}

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
    row_key: u64,
    content_key: u64,
    contract_key: u64,
    model_key: u64,
    raw_output: Arc<str>,
    bytes: usize,
    last_access: u64,
}

impl InferenceCacheEntry {
    fn matches_identity(
        &self,
        row_key: u64,
        content_key: u64,
        contract_key: u64,
        model_key: u64,
    ) -> bool {
        self.row_key == row_key
            && self.content_key == content_key
            && self.contract_key == contract_key
            && self.model_key == model_key
    }
}

#[derive(Clone, Copy)]
struct CacheIdentity {
    key: u64,
    content_key: u64,
    contract_key: u64,
    model_key: u64,
}

struct InferenceCache {
    entries: HashMap<u64, InferenceCacheEntry>,
    latest_by_row: HashMap<u64, CacheIdentity>,
    bytes: usize,
    hits: i64,
    misses: i64,
    evictions: i64,
    last_eviction_reason: &'static str,
    access_clock: u64,
}

impl Default for InferenceCache {
    fn default() -> Self {
        Self {
            entries: HashMap::with_capacity(32),
            latest_by_row: HashMap::with_capacity(32),
            bytes: 0,
            hits: 0,
            misses: 0,
            evictions: 0,
            last_eviction_reason: "none",
            access_clock: 0,
        }
    }
}

impl InferenceCache {
    fn next_access(&mut self) -> u64 {
        if self.access_clock == u64::MAX {
            let mut order = self
                .entries
                .iter()
                .map(|(key, entry)| (*key, entry.last_access))
                .collect::<Vec<_>>();
            order.sort_unstable_by_key(|(_, last_access)| *last_access);
            for (index, (key, _)) in order.into_iter().enumerate() {
                self.entries.get_mut(&key).unwrap().last_access = index as u64 + 1;
            }
            self.access_clock = self.entries.len() as u64;
        }
        self.access_clock += 1;
        self.access_clock
    }

    fn remove(&mut self, key: u64) -> Option<InferenceCacheEntry> {
        let entry = self.entries.remove(&key)?;
        self.bytes = self.bytes.saturating_sub(entry.bytes);
        if self
            .latest_by_row
            .get(&entry.row_key)
            .is_some_and(|latest| latest.key == key)
        {
            let replacement = self
                .entries
                .iter()
                .filter(|(_, candidate)| candidate.row_key == entry.row_key)
                .max_by_key(|(_, candidate)| candidate.last_access)
                .map(|(candidate_key, candidate)| CacheIdentity {
                    key: *candidate_key,
                    content_key: candidate.content_key,
                    contract_key: candidate.contract_key,
                    model_key: candidate.model_key,
                });
            if let Some(replacement) = replacement {
                self.latest_by_row.insert(entry.row_key, replacement);
            } else {
                self.latest_by_row.remove(&entry.row_key);
            }
        }
        Some(entry)
    }

    fn remove_lru(&mut self) -> Option<InferenceCacheEntry> {
        let key = self
            .entries
            .iter()
            .min_by_key(|(_, entry)| entry.last_access)
            .map(|(key, _)| *key)?;
        self.remove(key)
    }

    fn miss_reason(
        &self,
        row_key: u64,
        content_key: u64,
        contract_key: u64,
        model_key: u64,
    ) -> &'static str {
        let Some(latest) = self.latest_by_row.get(&row_key) else {
            return "not_found";
        };
        if latest.content_key != content_key {
            "row_version_changed"
        } else if latest.contract_key != contract_key {
            "contract_changed"
        } else if latest.model_key != model_key {
            "model_fingerprint_changed"
        } else {
            "not_found"
        }
    }
}

fn inference_cache_get(
    key: u64,
    row_key: u64,
    content_key: u64,
    contract_key: u64,
    model_key: u64,
) -> CacheLookup {
    let cache = INFERENCE_CACHE.get_or_init(|| Mutex::new(InferenceCache::default()));
    let Ok(mut cache) = cache.lock() else {
        return CacheLookup {
            raw_output: None,
            reason: "lock_poisoned",
            stats: InferenceCacheStats::default(),
        };
    };

    let access = cache.next_access();
    if let Some(entry) = cache.entries.get_mut(&key)
        && entry.matches_identity(row_key, content_key, contract_key, model_key)
    {
        entry.last_access = access;
        let raw_output = Arc::clone(&entry.raw_output);
        let row_key = entry.row_key;
        let identity = CacheIdentity {
            key,
            content_key: entry.content_key,
            contract_key: entry.contract_key,
            model_key: entry.model_key,
        };
        cache.latest_by_row.insert(row_key, identity);
        cache.hits += 1;
        return CacheLookup {
            raw_output: Some(raw_output),
            reason: "hit",
            stats: cache.stats(),
        };
    }

    cache.misses += 1;
    let reason = cache.miss_reason(row_key, content_key, contract_key, model_key);
    CacheLookup {
        raw_output: None,
        reason,
        stats: cache.stats(),
    }
}

fn inference_cache_put(
    key: u64,
    row_key: u64,
    content_key: u64,
    contract_key: u64,
    model_key: u64,
    raw_output: String,
) -> InferenceCacheStats {
    let cache = INFERENCE_CACHE.get_or_init(|| Mutex::new(InferenceCache::default()));
    let Ok(mut cache) = cache.lock() else {
        return InferenceCacheStats::default();
    };

    let bytes = 5 * std::mem::size_of::<u64>() + raw_output.len();
    if bytes > INFERENCE_CACHE_MAX_BYTES {
        cache.last_eviction_reason = "entry_too_large";
        return cache.stats();
    }

    let _ = cache.remove(key);

    cache.bytes += bytes;
    let last_access = cache.next_access();
    let raw_output = Arc::<str>::from(raw_output);
    cache.entries.insert(key, InferenceCacheEntry {
        row_key,
        content_key,
        contract_key,
        model_key,
        raw_output,
        bytes,
        last_access,
    });
    cache.latest_by_row.insert(
        row_key,
        CacheIdentity {
            key,
            content_key,
            contract_key,
            model_key,
        },
    );

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
        let _ = cache.remove_lru();
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

#[cfg(test)]
mod cache_tests {
    use super::*;

    fn entry(last_access: u64) -> InferenceCacheEntry {
        InferenceCacheEntry {
            row_key: 0,
            content_key: 0,
            contract_key: 0,
            model_key: 0,
            raw_output: Arc::from("{}"),
            bytes: 1,
            last_access,
        }
    }

    #[test]
    fn inference_cache_evicts_least_recently_used_stable_entry() {
        let mut cache = InferenceCache::default();
        cache.entries.insert(1, entry(1));
        cache.entries.insert(2, entry(2));
        cache.entries.insert(3, entry(3));
        cache.bytes = 3;
        cache.access_clock = 3;

        let access = cache.next_access();
        cache.entries.get_mut(&1).unwrap().last_access = access;
        let removed = cache.remove_lru().unwrap();

        assert_eq!(removed.last_access, 2);
        assert!(cache.entries.contains_key(&1));
        assert!(!cache.entries.contains_key(&2));
        assert!(cache.entries.contains_key(&3));
        assert_eq!(cache.bytes, 2);
    }

    #[test]
    fn inference_cache_preserves_lru_order_when_access_clock_exhausts() {
        let mut cache = InferenceCache::default();
        cache.entries.insert(1, entry(1));
        cache.entries.insert(2, entry(u64::MAX));
        cache.access_clock = u64::MAX;

        let access = cache.next_access();

        assert_eq!(cache.entries.get(&1).unwrap().last_access, 1);
        assert_eq!(cache.entries.get(&2).unwrap().last_access, 2);
        assert_eq!(access, 3);
        assert_eq!(cache.remove_lru().unwrap().last_access, 1);
    }

    #[test]
    fn inference_cache_classifies_identity_changes_without_scanning_entries() {
        let mut cache = InferenceCache::default();
        cache.latest_by_row.insert(
            10,
            CacheIdentity {
                key: 1,
                content_key: 20,
                contract_key: 30,
                model_key: 40,
            },
        );

        assert_eq!(cache.miss_reason(99, 20, 30, 40), "not_found");
        assert_eq!(cache.miss_reason(10, 21, 30, 40), "row_version_changed");
        assert_eq!(cache.miss_reason(10, 20, 31, 40), "contract_changed");
        assert_eq!(
            cache.miss_reason(10, 20, 30, 41),
            "model_fingerprint_changed"
        );
    }

    #[test]
    fn inference_cache_repairs_latest_identity_after_eviction() {
        let mut cache = InferenceCache::default();
        let mut older = entry(1);
        older.row_key = 10;
        older.content_key = 20;
        let mut newer = entry(2);
        newer.row_key = 10;
        newer.content_key = 21;
        cache.entries.insert(1, older);
        cache.entries.insert(2, newer);
        cache.bytes = 2;
        cache.latest_by_row.insert(
            10,
            CacheIdentity {
                key: 2,
                content_key: 21,
                contract_key: 0,
                model_key: 0,
            },
        );

        cache.remove(2).unwrap();

        assert_eq!(cache.latest_by_row.get(&10).unwrap().key, 1);
        assert_eq!(cache.miss_reason(10, 20, 0, 0), "not_found");
    }

    #[test]
    fn catalog_model_fingerprint_reuses_cached_allocation() {
        let model = JobModelRef {
            name: "test",
            artifact_path: "/not/read",
            artifact_hash: Some("catalog-hash"),
        };
        let first = model_fingerprint_hash(model);
        let second = model_fingerprint_hash(model);
        assert!(Arc::ptr_eq(&first, &second));
    }

    #[test]
    fn inference_cache_rejects_forced_full_key_collision() {
        let mut cached = entry(1);
        cached.row_key = 10;
        cached.content_key = 20;
        cached.contract_key = 30;
        cached.model_key = 40;

        assert!(cached.matches_identity(10, 20, 30, 40));
        assert!(!cached.matches_identity(10, 21, 30, 40));
        assert!(!cached.matches_identity(10, 20, 31, 40));
        assert!(!cached.matches_identity(10, 20, 30, 41));
    }
}
