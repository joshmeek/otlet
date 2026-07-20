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
