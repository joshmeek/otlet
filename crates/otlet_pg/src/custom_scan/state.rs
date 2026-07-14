#[derive(Clone, Copy, Eq, PartialEq)]
enum SemanticIndexKind {
    Row,
    Join,
}

fn u64_to_u32_saturating(value: u64) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

impl SemanticIndexKind {
    const fn as_str(self) -> &'static str {
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

#[repr(C)]
struct OtletSemanticCustomScanState {
    css: pg_sys::CustomScanState,
    runtime: *mut RuntimeState,
    index_kind: SemanticIndexKind,
    source_table: *mut c_char,
    task_name: *mut c_char,
    record_type: *mut c_char,
    known_subjects: u64,
    preloaded_fresh_matches: u64,
    preloaded_fresh_non_matches: u64,
    preloaded_freshness_basis: *mut c_char,
    emitted_freshness_basis: *mut c_char,
    preloaded_stale_subjects: u64,
    preloaded_missing_subjects: u64,
    preloaded_inflight_subjects: u64,
    auto_policy: bool,
    allow_refresh: bool,
    wait_ms: u32,
    infer_ms: u32,
    infer_max_rows: u32,
    planner_selected_path: *mut c_char,
    planner_reason: *mut c_char,
    planner_stale_reasons: *mut c_char,
    planner_model_cost_source: *mut c_char,
    planner_model_ms: f64,
    planner_count_basis: *mut c_char,
    planner_path_cost: f64,
    planner_infer_decision_rows: u64,
    planner_fail_closed_decision_rows: u64,
    rows_seen: u64,
    rows_returned: u64,
    lookup_rows: u64,
    infer_resolved_rows: u64,
    infer_returned_rows: u64,
    fail_closed_rows: u64,
    fresh_matches: u64,
    fresh_non_matches: u64,
    stale_rows: u64,
    missing_rows: u64,
    inflight_rows: u64,
    queued_refreshes: u64,
    refresh_queue_skips: u64,
    refresh_queue_batches: u64,
    refresh_queue_errors: u64,
    infer_now_batches: u64,
    infer_now_ms: u64,
    infer_now_timeouts: u64,
    infer_now_failures: u64,
    infer_now_last_error: *mut c_char,
    infer_receipts: u64,
    infer_failed_receipts: u64,
    infer_failed_receipt_id: u64,
    infer_trace_receipt_id: u64,
    infer_trace_prompt_tokens: u64,
    infer_trace_generated_tokens: u64,
    infer_trace_generate_ms: u64,
    infer_trace_finish_sql_ms: u64,
    infer_trace_materialize_ms: u64,
    infer_trace_version: *mut c_char,
    infer_trace_runtime_fingerprint_hash: *mut c_char,
    infer_trace_probability_status: *mut c_char,
    infer_trace_schema_force: *mut c_char,
    infer_trace_detailed_status: *mut c_char,
    infer_trace_detailed_captured_tokens: u64,
    infer_trace_detailed_top_k: u64,
    child_plan_rows: u64,
    /// True once begin-scan attached a PG child plan (EXPLAIN provider parity).
    has_child_plan: bool,
}

#[derive(Default)]
struct EmittedFreshnessCounts {
    content_hash_match: u64,
    mvcc_match: u64,
    revalidated_after_benign_update: u64,
    runtime_refresh: u64,
    other: BTreeMap<String, u64>,
}

impl EmittedFreshnessCounts {
    fn clear(&mut self) {
        *self = Self::default();
    }

    fn is_empty(&self) -> bool {
        self.content_hash_match == 0
            && self.mvcc_match == 0
            && self.revalidated_after_benign_update == 0
            && self.runtime_refresh == 0
            && self.other.is_empty()
    }
}

fn emitted_freshness_counts_json(counts: &EmittedFreshnessCounts) -> String {
    if counts.is_empty() {
        return "{}".to_owned();
    }
    let mut value = serde_json::Map::new();
    if counts.content_hash_match > 0 {
        value.insert("content_hash_match".to_owned(), json!(counts.content_hash_match));
    }
    if counts.mvcc_match > 0 {
        value.insert("mvcc_match".to_owned(), json!(counts.mvcc_match));
    }
    if counts.revalidated_after_benign_update > 0 {
        value.insert(
            "revalidated_after_benign_update".to_owned(),
            json!(counts.revalidated_after_benign_update),
        );
    }
    if counts.runtime_refresh > 0 {
        value.insert("runtime_refresh".to_owned(), json!(counts.runtime_refresh));
    }
    for (k, v) in &counts.other {
        if *v > 0 {
            value.insert(k.clone(), json!(v));
        }
    }
    Value::Object(value).to_string()
}

struct RuntimeState {
    index_kind: SemanticIndexKind,
    index_name: String,
    expected_json: String,
    auto_policy: bool,
    allow_refresh: bool,
    wait_ms: u32,
    infer_ms: u32,
    infer_max_rows: u32,
    planner_selected_path: String,
    planner_reason: String,
    planner_stale_reasons: String,
    planner_model_cost_source: String,
    planner_model_ms: f64,
    planner_count_basis: String,
    planner_path_cost: f64,
    planner_infer_decision_rows: u64,
    planner_fail_closed_decision_rows: u64,
    source_table: String,
    task_name: String,
    record_type: String,
    /// Frozen once at begin-scan for infer-now receipt stamping (pre-serialized JSON text).
    infer_now_executor_context_json: String,
    input_columns: Option<Vec<String>>,
    preloaded_freshness_basis: String,
    preloaded_fresh_matches: u64,
    preloaded_fresh_non_matches: u64,
    preloaded_stale_subjects: u64,
    preloaded_missing_subjects: u64,
    preloaded_inflight_subjects: u64,
    source_reltype: pg_sys::Oid,
    subject_attno: i16,
    subject_typid: pg_sys::Oid,
    // Join child "input" jsonb attnum resolved once at begin-scan (0 = unset).
    join_input_attno: i16,
    child_plan: *mut pg_sys::PlanState,
    owns_child_plan: bool,
    semantic_states: HashMap<String, SubjectSemanticState>,
    subject_freshness_basis: HashMap<String, String>,
    emitted_freshness_basis: EmittedFreshnessCounts,
    rows_seen: u64,
    rows_returned: u64,
    lookup_rows: u64,
    infer_resolved_rows: u64,
    infer_returned_rows: u64,
    fail_closed_rows: u64,
    fresh_matches: u64,
    fresh_non_matches: u64,
    stale_rows: u64,
    missing_rows: u64,
    inflight_rows: u64,
    queued_refreshes: u64,
    refresh_queue_skips: u64,
    refresh_queue_batches: u64,
    refresh_queue_errors: u64,
    infer_now_batches: u64,
    infer_now_ms: u64,
    infer_now_timeouts: u64,
    infer_now_failures: u64,
    infer_now_last_error: String,
    infer_receipts: u64,
    infer_failed_receipts: u64,
    infer_failed_receipt_id: u64,
    infer_trace_receipt_id: u64,
    infer_trace_prompt_tokens: u64,
    infer_trace_generated_tokens: u64,
    infer_trace_generate_ms: u64,
    infer_trace_finish_sql_ms: u64,
    infer_trace_materialize_ms: u64,
    infer_trace_version: String,
    infer_trace_runtime_fingerprint_hash: String,
    infer_trace_probability_status: String,
    infer_trace_schema_force: String,
    infer_trace_detailed_status: String,
    infer_trace_detailed_captured_tokens: u64,
    infer_trace_detailed_top_k: u64,
    child_plan_rows: u64,
    queued_refresh_subjects: HashSet<String>,
    pending_refresh_subjects: Vec<String>,
    pending_output_rows: VecDeque<*mut pg_sys::TupleTableSlot>,
}

struct InferNowTraceExplain<'trace> {
    receipt_id: u64,
    prompt_tokens: u64,
    generated_tokens: u64,
    generate_ms: u64,
    finish_sql_ms: u64,
    materialize_ms: u64,
    version: Option<&'trace str>,
    runtime_fingerprint_hash: Option<&'trace str>,
    probability_status: Option<&'trace str>,
    schema_force: Option<&'trace str>,
    detailed_status: Option<&'trace str>,
    detailed_captured_tokens: u64,
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

#[derive(Clone, Copy)]
struct PreloadedSubjectCounts {
    fresh_matches: u64,
    fresh_non_matches: u64,
    stale: u64,
    inflight: u64,
    missing: u64,
}

impl PreloadedSubjectCounts {
    const fn new() -> Self {
        Self {
            fresh_matches: 0,
            fresh_non_matches: 0,
            stale: 0,
            inflight: 0,
            missing: 0,
        }
    }

    fn record(&mut self, state: SubjectSemanticState) {
        match state {
            SubjectSemanticState::FreshMatch => self.fresh_matches += 1,
            SubjectSemanticState::FreshNonMatch => self.fresh_non_matches += 1,
            SubjectSemanticState::Stale => self.stale += 1,
            SubjectSemanticState::InFlight => self.inflight += 1,
            SubjectSemanticState::Missing => self.missing += 1,
        }
    }
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
    input_columns: Option<Vec<String>>,
    freshness_basis_counts: String,
    stale_reasons: String,
    model_ms: f64,
    model_cost_source: String,
    freshness_basis_by_subject: HashMap<String, String>,
    subjects: HashMap<String, SubjectSemanticState>,
    subject_counts: PreloadedSubjectCounts,
}

impl SubjectSemanticState {
    fn from_label(label: &str) -> Option<Self> {
        match label {
            "fresh_match" => Some(Self::FreshMatch),
            "fresh_non_match" => Some(Self::FreshNonMatch),
            "stale" => Some(Self::Stale),
            "in_flight" => Some(Self::InFlight),
            "missing" => Some(Self::Missing),
            _ => None,
        }
    }
}

struct SemanticMatchPredicate {
    index_kind: SemanticIndexKind,
    index_name: String,
    expected_json: String,
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

#[derive(Clone, Deserialize, Serialize)]
struct SemanticPlannerStats {
    selected_path: String,
    reason: String,
    source_rows: u64,
    fresh_matches: u64,
    fresh_non_matches: u64,
    stale_rows: u64,
    missing_rows: u64,
    inflight_rows: u64,
    cache_reusable_rows: u64,
    infer_decision_rows: u64,
    fail_closed_decision_rows: u64,
    model_ms: f64,
    model_cost_source: String,
    path_cost: f64,
    stale_reasons: String,
    count_basis: String,
}
