use pgrx::{FromDatum, JsonB, direct_function_call, pg_sys};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::ffi::{CStr, CString, c_char};
use std::mem::size_of;
use std::ptr;

const CUSTOM_SCAN_NAME: &[u8] = b"Otlet Semantic Source CustomScan\0";
const CUSTOM_PRIVATE_MARKER: &str = "__otlet_semantic_source_custom_scan_json_v1__";
macro_rules! explain_scan_counters {
    ($source:expr, $last_error:expr, $estimated_model_cost_ms:expr, $es:expr) => {{
        let source = $source;
        explain_counter("Rows Seen", source.rows_seen, $es);
        explain_counter("Rows Returned", source.rows_returned, $es);
        explain_counter("Actual Lookup Rows", source.lookup_rows, $es);
        explain_counter(
            "Actual Infer Resolved Rows",
            source.infer_resolved_rows,
            $es,
        );
        explain_counter(
            "Actual Infer Returned Rows",
            source.infer_returned_rows,
            $es,
        );
        explain_counter("Actual Fail Closed Rows", source.fail_closed_rows, $es);
        explain_counter(
            "Actual Fresh Subjects",
            source
                .fresh_matches
                .saturating_add(source.fresh_non_matches),
            $es,
        );
        explain_counter("Actual Stale Subjects", source.stale_rows, $es);
        explain_counter("Actual Missing Subjects", source.missing_rows, $es);
        explain_counter("Actual In Flight Subjects", source.inflight_rows, $es);
        explain_counter("Queued Refreshes", source.queued_refreshes, $es);
        explain_counter("Infer Now Batches", source.infer_now_batches, $es);
        explain_counter("Infer Now Elapsed Ms", source.infer_now_ms, $es);
        explain_counter("Infer Now Timeouts", source.infer_now_timeouts, $es);
        explain_counter("Infer Now Failures", source.infer_now_failures, $es);
        explain_optional_text("Infer Now Last Error", $last_error, $es);
        explain_counter("Infer Now Receipts", source.infer_receipts, $es);
        explain_counter(
            "Infer Now Failed Receipts",
            source.infer_failed_receipts,
            $es,
        );
        explain_counter(
            "Infer Now Last Failed Receipt Id",
            source.infer_failed_receipt_id,
            $es,
        );
        explain_counter("Child Plan Source Rows", source.child_plan_rows, $es);
        explain_counter("Estimated Model Cost Ms", $estimated_model_cost_ms, $es);
        explain_counter("Actual Model Cost Ms", source.infer_trace_generate_ms, $es);
    }};
}

static mut CUSTOM_PATH_METHODS: pg_sys::CustomPathMethods = pg_sys::CustomPathMethods {
    CustomName: CUSTOM_SCAN_NAME.as_ptr().cast(),
    PlanCustomPath: Some(plan_semantic_custom_path),
    ReparameterizeCustomPathByChild: None,
};

static mut CUSTOM_SCAN_METHODS: pg_sys::CustomScanMethods = pg_sys::CustomScanMethods {
    CustomName: CUSTOM_SCAN_NAME.as_ptr().cast(),
    CreateCustomScanState: Some(create_semantic_custom_scan_state),
};

static mut CUSTOM_EXEC_METHODS: pg_sys::CustomExecMethods = pg_sys::CustomExecMethods {
    CustomName: CUSTOM_SCAN_NAME.as_ptr().cast(),
    BeginCustomScan: Some(begin_semantic_custom_scan),
    ExecCustomScan: Some(exec_semantic_custom_scan),
    EndCustomScan: Some(end_semantic_custom_scan),
    ReScanCustomScan: Some(rescan_semantic_custom_scan),
    MarkPosCustomScan: None,
    RestrPosCustomScan: None,
    EstimateDSMCustomScan: None,
    InitializeDSMCustomScan: None,
    ReInitializeDSMCustomScan: None,
    InitializeWorkerCustomScan: None,
    ShutdownCustomScan: Some(end_semantic_custom_scan),
    ExplainCustomScan: Some(explain_semantic_custom_scan),
};

static mut PREV_SET_REL_PATHLIST_HOOK: pg_sys::set_rel_pathlist_hook_type = None;
static mut HOOK_INSTALLED: bool = false;

pub fn init() {
    unsafe {
        pg_sys::RegisterCustomScanMethods(&raw const CUSTOM_SCAN_METHODS);
        if !HOOK_INSTALLED {
            PREV_SET_REL_PATHLIST_HOOK = pg_sys::set_rel_pathlist_hook;
            pg_sys::set_rel_pathlist_hook = Some(otlet_set_rel_pathlist);
            HOOK_INSTALLED = true;
        }
    }
}

fn semantic_freshness_status_sql(
    material_alias: &str,
    current_content_hash_sql: &str,
    current_contract_hash_sql: &str,
    current_source_hash_sql: &str,
) -> String {
    format!(
        "otlet.semantic_freshness_status(\
         {material_alias}.content_hash, \
         {material_alias}.contract_hash, \
         {material_alias}.stale, \
         {material_alias}.stale_reason, \
         {material_alias}.source_hash, \
         {current_content_hash_sql}, \
         {current_contract_hash_sql}, \
         {current_source_hash_sql})"
    )
}

include!("state.rs");
include!("planner.rs");
include!("child_plan.rs");
include!("callbacks.rs");
include!("explain.rs");
include!("predicate_parse.rs");
include!("source_validation.rs");
include!("semantic_state.rs");
include!("counters.rs");
include!("infer_queue.rs");
include!("infer_provenance.rs");
include!("slot_input.rs");
include!("policy.rs");
include!("private.rs");
include!("sql.rs");
