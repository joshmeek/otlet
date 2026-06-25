#[derive(Clone, Copy, Eq, PartialEq)]
enum SemanticIndexKind {
    Row,
    Join,
}

impl SemanticIndexKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Row => "row",
            Self::Join => "join",
        }
    }

    fn from_str(value: &str) -> Option<Self> {
        match value {
            "row" => Some(Self::Row),
            "join" => Some(Self::Join),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum SemanticPredicateKind {
    Materialization,
    Action,
}

impl SemanticPredicateKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Materialization => "materialization",
            Self::Action => "action",
        }
    }

    fn from_str(value: &str) -> Option<Self> {
        match value {
            "materialization" => Some(Self::Materialization),
            "action" => Some(Self::Action),
            _ => None,
        }
    }
}

#[repr(C)]
struct OtletSemanticCustomScanState {
    css: pg_sys::CustomScanState,
    runtime: *mut RuntimeState,
    source_table: *mut c_char,
    task_name: *mut c_char,
    record_type: *mut c_char,
    known_subjects: u64,
    preloaded_fresh_matches: u64,
    preloaded_fresh_non_matches: u64,
    preloaded_stale_subjects: u64,
    preloaded_inflight_subjects: u64,
    rows_seen: u64,
    rows_returned: u64,
    lookup_rows: u64,
    wait_resolved_rows: u64,
    wait_returned_rows: u64,
    infer_resolved_rows: u64,
    infer_returned_rows: u64,
    fail_closed_rows: u64,
    fresh_matches: u64,
    fresh_non_matches: u64,
    stale_rows: u64,
    missing_rows: u64,
    inflight_rows: u64,
    queued_refreshes: u64,
    waited_refreshes: u64,
    wait_elapsed_ms: u64,
    infer_now_batches: u64,
    infer_now_ms: u64,
    infer_now_request_wait_ms: u64,
    infer_now_start_latency_ms: u64,
    infer_now_worker_run_ms: u64,
    infer_now_timeouts: u64,
    infer_now_abort_requests: u64,
    infer_now_cancel_job_id: i64,
    infer_now_failures: u64,
    infer_now_last_error: *mut c_char,
    infer_prefetch_submissions: u64,
    infer_prefetch_source_rows: u64,
    infer_buffered_rows: u64,
    infer_slot_inputs: u64,
    infer_spi_inputs: u64,
    infer_receipts: u64,
    infer_failed_receipts: u64,
    infer_failed_receipt_id: u64,
    infer_outputs: u64,
    infer_actions: u64,
    infer_materializations: u64,
    infer_trace_receipt_id: u64,
    infer_trace_prompt_tokens: u64,
    infer_trace_generated_tokens: u64,
    infer_trace_generate_ms: u64,
    infer_trace_version: *mut c_char,
    infer_trace_tokens_per_second: *mut c_char,
    infer_trace_probability_status: *mut c_char,
    infer_trace_probability_method: *mut c_char,
    infer_trace_schema_force: *mut c_char,
    infer_trace_worker_rss_bytes: u64,
    infer_trace_worker_virtual_bytes: u64,
    infer_trace_worker_memory_policy: *mut c_char,
    infer_trace_model_cache_hits: u64,
    infer_trace_model_cache_misses: u64,
    infer_trace_inference_cache_hits: u64,
    infer_trace_inference_cache_misses: u64,
    infer_trace_inference_cache_entries: u64,
    infer_trace_inference_cache_bytes: u64,
    infer_trace_inference_cache_evictions: u64,
    infer_trace_inference_cache_reason: *mut c_char,
    infer_trace_detailed_status: *mut c_char,
    infer_trace_detailed_captured_tokens: u64,
    infer_trace_detailed_skipped_tokens: u64,
    infer_trace_detailed_top_k: u64,
    child_plan_rows: u64,
    direct_scan_rows: u64,
    subject_state_refreshes: u64,
    semantic_cache_hits: u64,
    semantic_cache_misses: u64,
}

struct RuntimeState {
    index_kind: SemanticIndexKind,
    predicate_kind: SemanticPredicateKind,
    index_name: String,
    expected_json: String,
    action_type: Option<String>,
    auto_policy: bool,
    allow_refresh: bool,
    wait_ms: u32,
    infer_ms: u32,
    infer_max_rows: u32,
    source_table: String,
    task_name: String,
    record_type: String,
    source_reltype: pg_sys::Oid,
    subject_attno: i16,
    subject_typid: pg_sys::Oid,
    child_plan: *mut pg_sys::PlanState,
    owns_child_plan: bool,
    semantic_states: HashMap<String, SubjectSemanticState>,
    rows_seen: u64,
    rows_returned: u64,
    lookup_rows: u64,
    wait_resolved_rows: u64,
    wait_returned_rows: u64,
    infer_resolved_rows: u64,
    infer_returned_rows: u64,
    fail_closed_rows: u64,
    fresh_matches: u64,
    fresh_non_matches: u64,
    stale_rows: u64,
    missing_rows: u64,
    inflight_rows: u64,
    queued_refreshes: u64,
    waited_refreshes: u64,
    wait_elapsed_ms: u64,
    infer_now_batches: u64,
    infer_now_ms: u64,
    infer_now_request_wait_ms: u64,
    infer_now_start_latency_ms: u64,
    infer_now_worker_run_ms: u64,
    infer_now_timeouts: u64,
    infer_now_abort_requests: u64,
    infer_now_cancel_job_id: i64,
    infer_now_failures: u64,
    infer_now_last_error: String,
    infer_prefetch_submissions: u64,
    infer_prefetch_source_rows: u64,
    infer_buffered_rows: u64,
    infer_slot_inputs: u64,
    infer_spi_inputs: u64,
    infer_receipts: u64,
    infer_failed_receipts: u64,
    infer_failed_receipt_id: u64,
    infer_outputs: u64,
    infer_actions: u64,
    infer_materializations: u64,
    infer_trace_receipt_id: u64,
    infer_trace_prompt_tokens: u64,
    infer_trace_generated_tokens: u64,
    infer_trace_generate_ms: u64,
    infer_trace_version: String,
    infer_trace_tokens_per_second: String,
    infer_trace_probability_status: String,
    infer_trace_probability_method: String,
    infer_trace_schema_force: String,
    infer_trace_worker_rss_bytes: u64,
    infer_trace_worker_virtual_bytes: u64,
    infer_trace_worker_memory_policy: String,
    infer_trace_model_cache_hits: u64,
    infer_trace_model_cache_misses: u64,
    infer_trace_inference_cache_hits: u64,
    infer_trace_inference_cache_misses: u64,
    infer_trace_inference_cache_entries: u64,
    infer_trace_inference_cache_bytes: u64,
    infer_trace_inference_cache_evictions: u64,
    infer_trace_inference_cache_reason: String,
    infer_trace_detailed_status: String,
    infer_trace_detailed_captured_tokens: u64,
    infer_trace_detailed_skipped_tokens: u64,
    infer_trace_detailed_top_k: u64,
    child_plan_rows: u64,
    direct_scan_rows: u64,
    subject_state_refreshes: u64,
    semantic_cache_hits: u64,
    semantic_cache_misses: u64,
    queued_refresh_subjects: HashSet<String>,
    pending_output_rows: VecDeque<*mut pg_sys::TupleTableSlot>,
}

struct InferNowTraceExplain<'a> {
    receipt_id: u64,
    prompt_tokens: u64,
    generated_tokens: u64,
    generate_ms: u64,
    version: Option<&'a str>,
    tokens_per_second: Option<&'a str>,
    probability_status: Option<&'a str>,
    probability_method: Option<&'a str>,
    schema_force: Option<&'a str>,
    worker_rss_bytes: u64,
    worker_virtual_bytes: u64,
    worker_memory_policy: Option<&'a str>,
    model_cache_hits: u64,
    model_cache_misses: u64,
    inference_cache_hits: u64,
    inference_cache_misses: u64,
    inference_cache_entries: u64,
    inference_cache_bytes: u64,
    inference_cache_evictions: u64,
    inference_cache_reason: Option<&'a str>,
    detailed_status: Option<&'a str>,
    detailed_captured_tokens: u64,
    detailed_skipped_tokens: u64,
    detailed_top_k: u64,
}

struct PendingInferNowRow {
    subject_id: String,
    slot: *mut pg_sys::TupleTableSlot,
    submitted: crate::infer_now::SubmittedInferNow,
    submitted_at: pg_sys::TimestampTz,
    snapshot_before: crate::infer_now::InferNowSnapshot,
}

enum PrefetchedRow {
    Ready(*mut pg_sys::TupleTableSlot),
    Infer(PendingInferNowRow),
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum SubjectSemanticState {
    FreshMatch,
    FreshNonMatch,
    Stale,
    InFlight,
    Missing,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum SemanticResolution {
    Match,
    NonMatch,
    Unresolved,
}

struct LoadedSemanticState {
    source_table: String,
    task_name: String,
    record_type: String,
    subjects: HashMap<String, SubjectSemanticState>,
}

impl SubjectSemanticState {
    fn from_label(label: &str) -> Option<Self> {
        match label {
            "fresh_match" => Some(Self::FreshMatch),
            "fresh_non_match" => Some(Self::FreshNonMatch),
            "stale" => Some(Self::Stale),
            "in_flight" => Some(Self::InFlight),
            _ => None,
        }
    }
}

struct SemanticMatchPredicate {
    index_kind: SemanticIndexKind,
    predicate_kind: SemanticPredicateKind,
    index_name: String,
    expected_json: String,
    action_type: Option<String>,
    auto_policy: bool,
    allow_refresh: bool,
    wait_ms: u32,
    infer_ms: u32,
    infer_max_rows: u32,
    subject_attno: i16,
    subject_typid: pg_sys::Oid,
    restrict_info: *mut pg_sys::RestrictInfo,
    estimated_rows: f64,
    planner_stats: SemanticPlannerStats,
}

#[derive(Clone)]
struct SemanticPlannerStats {
    reason: String,
    source_rows: u64,
    fresh_matches: u64,
    fresh_non_matches: u64,
    stale_rows: u64,
    missing_rows: u64,
    inflight_rows: u64,
    cache_reusable_rows: u64,
    lookup_decision_rows: u64,
    wait_decision_rows: u64,
    infer_decision_rows: u64,
    queue_decision_rows: u64,
    fail_closed_decision_rows: u64,
    model_ms: f64,
    path_cost: f64,
}
