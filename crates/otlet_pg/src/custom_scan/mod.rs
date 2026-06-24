use pgrx::{FromDatum, JsonB, direct_function_call, pg_sys};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::{CStr, CString, c_char};
use std::ptr;

const CUSTOM_SCAN_NAME: &[u8] = b"Otlet Semantic Source CustomScan\0";
const CUSTOM_PRIVATE_MARKER: &str = "__otlet_semantic_source_custom_scan_json_v1__";
macro_rules! explain_scan_counters {
    ($source:expr, $last_error:expr, $estimated_model_cost_ms:expr, $es:expr) => {{
        let source = $source;
        explain_counter("Rows Seen", source.rows_seen, $es);
        explain_counter("Rows Returned", source.rows_returned, $es);
        explain_counter("Actual Lookup Rows", source.lookup_rows, $es);
        explain_counter("Actual Wait Resolved Rows", source.wait_resolved_rows, $es);
        explain_counter("Actual Wait Returned Rows", source.wait_returned_rows, $es);
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
        explain_counter("Fresh Materialized Matches", source.fresh_matches, $es);
        explain_counter(
            "Fresh Materialized Non Matches",
            source.fresh_non_matches,
            $es,
        );
        explain_counter("Stale Rows", source.stale_rows, $es);
        explain_counter("Missing Rows", source.missing_rows, $es);
        explain_counter("In Flight Refresh Rows", source.inflight_rows, $es);
        explain_counter("Queued Refreshes", source.queued_refreshes, $es);
        explain_counter("Waited Refreshes", source.waited_refreshes, $es);
        explain_counter("Wait Elapsed Ms", source.wait_elapsed_ms, $es);
        explain_counter("Infer Now Batches", source.infer_now_batches, $es);
        explain_counter("Infer Now Elapsed Ms", source.infer_now_ms, $es);
        explain_counter(
            "Infer Now Request Wait Ms",
            source.infer_now_request_wait_ms,
            $es,
        );
        explain_counter(
            "Infer Now Start Latency Ms",
            source.infer_now_start_latency_ms,
            $es,
        );
        explain_counter(
            "Infer Now Worker Run Ms",
            source.infer_now_worker_run_ms,
            $es,
        );
        explain_counter("Infer Now Timeouts", source.infer_now_timeouts, $es);
        explain_counter(
            "Infer Now Abort Requests",
            source.infer_now_abort_requests,
            $es,
        );
        explain_counter(
            "Infer Now Cancel Job Id",
            source.infer_now_cancel_job_id as u64,
            $es,
        );
        explain_counter("Infer Now Failures", source.infer_now_failures, $es);
        explain_optional_text("Infer Now Last Error", $last_error, $es);
        explain_counter(
            "Infer Now Prefetch Submissions",
            source.infer_prefetch_submissions,
            $es,
        );
        explain_counter(
            "Infer Now Prefetch Source Rows",
            source.infer_prefetch_source_rows,
            $es,
        );
        explain_counter("Infer Now Buffered Rows", source.infer_buffered_rows, $es);
        explain_counter("Infer Now Slot Inputs", source.infer_slot_inputs, $es);
        explain_counter("Infer Now SPI Inputs", source.infer_spi_inputs, $es);
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
        explain_counter("Infer Now Outputs", source.infer_outputs, $es);
        explain_counter("Infer Now Actions", source.infer_actions, $es);
        explain_counter(
            "Infer Now Materializations",
            source.infer_materializations,
            $es,
        );
        explain_counter("Child Plan Source Rows", source.child_plan_rows, $es);
        explain_counter("Direct Scan Source Rows", source.direct_scan_rows, $es);
        explain_counter(
            "Subject Local State Refreshes",
            source.subject_state_refreshes,
            $es,
        );
        explain_counter("Semantic Cache Hits", source.semantic_cache_hits, $es);
        explain_counter("Semantic Cache Misses", source.semantic_cache_misses, $es);
        explain_counter("Estimated Model Cost Ms", $estimated_model_cost_ms, $es);
        explain_counter("Actual Model Cost Ms", source.infer_now_ms, $es);
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

include!("state.rs");
include!("planner.rs");
include!("child_plan.rs");
include!("callbacks.rs");
include!("explain.rs");
include!("predicate_parse.rs");
include!("programs.rs");
include!("source_validation.rs");
include!("semantic_state.rs");
include!("counters.rs");
include!("infer_queue.rs");
include!("infer_provenance.rs");
include!("slot_input.rs");
include!("policy.rs");
include!("private.rs");
include!("sql.rs");
