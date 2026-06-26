use pgrx::prelude::*;
use pgrx::{FromDatum, JsonB, pg_sys};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::ptr;
use std::sync::{Mutex, OnceLock};

#[derive(Clone)]
struct SemanticFdwOptions {
    index_name: String,
    access_kind: SemanticAccessKind,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SemanticAccessKind {
    RowIndex,
    JoinIndex,
}

#[derive(Clone)]
struct SemanticFdwPlan {
    selected_path: String,
    reason: String,
    task_name: String,
    record_type: String,
    model_name: String,
    runtime_name: String,
    source_relation: String,
    total_subjects: i64,
    fresh_subjects: i64,
    stale_subjects: i64,
    missing_subjects: i64,
    inflight_subjects: i64,
    lookup_subjects: i64,
    wait_subjects: i64,
    queue_subjects: i64,
    infer_now_subjects: i64,
    fail_closed_subjects: i64,
    freshness: f64,
    model_ms: f64,
    model_cost_source: String,
    cache_hit_ms: f64,
    lookup_ms: f64,
    queue_ms: f64,
    infer_now_ms: f64,
    path_cost: f64,
    worker_queue_depth: i64,
    available_queue_slots: i64,
}

struct SemanticFdwRow {
    subject_id: Option<String>,
    body: Option<Value>,
    stale: Option<bool>,
    source_hash: Option<String>,
    updated_at: Option<String>,
}

struct SubjectScopeStats {
    source_rows: i64,
    fresh_rows: i64,
}

#[derive(Clone)]
struct SemanticPushdown {
    subjects: SubjectPushdown,
}

impl SemanticPushdown {
    fn none() -> Self {
        Self {
            subjects: SubjectPushdown::None,
        }
    }

    fn subjects(&self) -> Option<&[String]> {
        self.subjects.subjects()
    }

    fn has_filters(&self) -> bool {
        self.subjects().is_some()
    }
}

#[derive(Clone)]
enum SubjectPushdown {
    None,
    Subjects(Vec<String>),
}

impl SubjectPushdown {
    fn subjects(&self) -> Option<&[String]> {
        match self {
            SubjectPushdown::None => None,
            SubjectPushdown::Subjects(subjects) => Some(subjects),
        }
    }
}

struct SemanticFdwState {
    rows: Vec<SemanticFdwRow>,
    next: usize,
    rows_loaded: i64,
    rows_emitted: i64,
    queued_jobs: i64,
    rescans: i64,
    opts: SemanticFdwOptions,
    plan: SemanticFdwPlan,
    pushdown: SemanticPushdown,
}

#[derive(Clone)]
struct SemanticFdwExplainSnapshot {
    opts: SemanticFdwOptions,
    plan: SemanticFdwPlan,
    pushdown: SemanticPushdown,
    rows_loaded: i64,
    rows_emitted: i64,
    queued_jobs: i64,
    rescans: i64,
}

impl SemanticFdwState {
    fn explain_snapshot(&self) -> SemanticFdwExplainSnapshot {
        SemanticFdwExplainSnapshot {
            opts: self.opts.clone(),
            plan: self.plan.clone(),
            pushdown: self.pushdown.clone(),
            rows_loaded: self.rows_loaded,
            rows_emitted: self.rows_emitted,
            queued_jobs: self.queued_jobs,
            rescans: self.rescans,
        }
    }
}

const FDW_PRIVATE_MARKER: &str = "__otlet_semantic_fdw_json_v1__";

static OTLET_SEMANTIC_FDW_FINFO: pg_sys::Pg_finfo_record =
    pg_sys::Pg_finfo_record { api_version: 1 };
static FDW_EXPLAIN_SNAPSHOTS: OnceLock<Mutex<HashMap<usize, SemanticFdwExplainSnapshot>>> =
    OnceLock::new();

include!("callbacks.rs");
include!("explain.rs");
include!("plan.rs");
include!("cost.rs");
include!("private.rs");
include!("quals.rs");
include!("pg.rs");
