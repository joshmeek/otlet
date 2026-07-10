unsafe fn find_semantic_match_predicate(
    restrictinfos: *mut pg_sys::List,
    rti: pg_sys::Index,
    relid: Option<pg_sys::Oid>,
    rte_kind: pg_sys::RTEKind::Type,
) -> Option<SemanticMatchPredicate> {
    unsafe {
        for idx in 0..pg_sys::list_length(restrictinfos) {
            let rinfo = pg_sys::list_nth(restrictinfos, idx).cast::<pg_sys::RestrictInfo>();
            if rinfo.is_null() || (*rinfo).clause.is_null() {
                continue;
            }
            let Some(mut predicate) = semantic_match_from_clause((*rinfo).clause, rti) else {
                continue;
            };
            predicate.restrict_info = rinfo;
            let stats = match predicate.index_kind {
                SemanticIndexKind::Row => {
                    let relid = relid?;
                    if rte_kind != pg_sys::RTEKind::RTE_RELATION {
                        continue;
                    }
                    let (stats, input_columns, row_meta) = validate_semantic_index_source(
                        &predicate.index_name,
                        relid,
                        predicate.subject_attno,
                        &predicate.expected_json,
                        predicate.allow_refresh,
                        predicate.wait_ms,
                        predicate.infer_ms,
                        predicate.infer_max_rows,
                        predicate.auto_policy,
                    )?;
                    predicate.input_columns = input_columns;
                    predicate.row_preload_meta = row_meta;
                    Some(stats)
                }
                SemanticIndexKind::Join => {
                    if rte_kind != pg_sys::RTEKind::RTE_SUBQUERY {
                        continue;
                    }
                    let (stats, join_meta) = validate_semantic_join_index_source(
                        &predicate.index_name,
                        &predicate.expected_json,
                        predicate.allow_refresh,
                        predicate.wait_ms,
                        predicate.infer_ms,
                        predicate.infer_max_rows,
                        predicate.auto_policy,
                    )?;
                    predicate.join_preload_meta = join_meta;
                    Some(stats)
                }
            };
            if let Some(stats) = stats {
                predicate.estimated_rows = estimated_result_rows(&stats, &predicate);
                predicate.planner_stats = stats;
                return Some(predicate);
            }
        }
        None
    }
}

unsafe fn semantic_match_from_clause(
    clause: *mut pg_sys::Expr,
    rti: pg_sys::Index,
) -> Option<SemanticMatchPredicate> {
    unsafe {
        let clause = strip_relabel(clause);
        if clause.is_null() {
            return None;
        }
        let parts = match (*clause).type_ {
            pg_sys::NodeTag::T_FuncExpr => semantic_match_function_parts(clause, rti)?,
            _ => return None,
        };
        Some(SemanticMatchPredicate {
            index_kind: parts.index_kind,
            index_name: parts.index_name,
            expected_json: parts.expected_json,
            auto_policy: parts.auto_policy,
            allow_refresh: parts.allow_refresh,
            wait_ms: parts.wait_ms,
            infer_ms: parts.infer_ms,
            infer_max_rows: parts.infer_max_rows,
            subject_attno: parts.subject.attno,
            subject_typid: parts.subject.typid,
            restrict_info: ptr::null_mut(),
            estimated_rows: 1.0,
            input_columns: None,
            row_preload_meta: None,
            join_preload_meta: None,
            planner_stats: planner_stats_unknown(),
        })
    }
}

struct ParsedSemanticMatch {
    index_kind: SemanticIndexKind,
    index_name: String,
    subject: SubjectVar,
    expected_json: String,
    auto_policy: bool,
    allow_refresh: bool,
    wait_ms: u32,
    infer_ms: u32,
    infer_max_rows: u32,
}

#[derive(Clone, Copy)]
struct SemanticAutoPolicy {
    auto_policy: bool,
    allow_refresh: bool,
    wait_ms: u32,
    infer_ms: u32,
    infer_max_rows: u32,
}

unsafe fn semantic_match_function_parts(
    clause: *mut pg_sys::Expr,
    rti: pg_sys::Index,
) -> Option<ParsedSemanticMatch> {
    unsafe {
        let func = clause.cast::<pg_sys::FuncExpr>();
        let is_matches = is_otlet_function((*func).funcid, "semantic_matches");
        let is_auto = is_otlet_function((*func).funcid, "semantic_matches_auto");
        let is_join_matches = is_otlet_function((*func).funcid, "semantic_join_matches");
        let is_join_auto = is_otlet_function((*func).funcid, "semantic_join_matches_auto");
        let is_join = is_join_matches || is_join_auto;
        let is_any_auto = is_auto || is_join_auto;
        if (!is_matches && !is_auto && !is_join) || pg_sys::list_length((*func).args) < 3 {
            return None;
        }

        let index_arg = pg_sys::list_nth((*func).args, 0).cast::<pg_sys::Expr>();
        let subject_arg = pg_sys::list_nth((*func).args, 1).cast::<pg_sys::Expr>();
        let expected_arg = pg_sys::list_nth((*func).args, 2).cast::<pg_sys::Expr>();
        let policy = semantic_auto_policy(is_any_auto);
        Some(ParsedSemanticMatch {
            index_kind: if is_join {
                SemanticIndexKind::Join
            } else {
                SemanticIndexKind::Row
            },
            index_name: text_const_value(index_arg)?,
            subject: subject_var(subject_arg, rti)?,
            expected_json: jsonb_const_text(expected_arg)?,
            auto_policy: is_any_auto,
            allow_refresh: policy.allow_refresh,
            wait_ms: policy.wait_ms,
            infer_ms: policy.infer_ms,
            infer_max_rows: policy.infer_max_rows,
        })
    }
}

fn semantic_auto_policy(enabled: bool) -> SemanticAutoPolicy {
    if !enabled {
        return SemanticAutoPolicy {
            auto_policy: false,
            allow_refresh: false,
            wait_ms: 0,
            infer_ms: 0,
            infer_max_rows: 0,
        };
    }

    // One SPI read per statement: production_policy is a single-row table and
    // begin-scan already freezes knobs from plan-time private data.
    let stmt_start = unsafe { pg_sys::GetCurrentStatementStartTimestamp() };
    thread_local! {
        static CACHED: std::cell::Cell<Option<(pg_sys::TimestampTz, SemanticAutoPolicy)>> =
            const { std::cell::Cell::new(None) };
    }
    if let Some((cached_start, policy)) = CACHED.get()
        && cached_start == stmt_start
    {
        return policy;
    }

    let policy = pgrx::Spi::connect(|client| {
        let table = client
            .select(
                "SELECT \
                   stale_policy = 'refresh_then_fail_closed' AS allow_refresh, \
                   semantic_auto_wait_ms, \
                   semantic_auto_infer_ms, \
                   semantic_auto_max_rows \
                 FROM otlet.production_policy \
                 WHERE name = 'default' \
                 LIMIT 1",
                Some(1),
                &[],
            )
            .ok()?;
        let row = table.first();
        Some(SemanticAutoPolicy {
            auto_policy: true,
            // Null allow_refresh fails closed (no refresh) rather than permissive.
            allow_refresh: row
                .get_by_name::<bool, _>("allow_refresh")
                .ok()
                .flatten()
                .unwrap_or(false),
            wait_ms: row
                .get_by_name::<i32, _>("semantic_auto_wait_ms")
                .ok()
                .flatten()
                .unwrap_or(10_000)
                .clamp(0, 30_000)
                .cast_unsigned(),
            infer_ms: row
                .get_by_name::<i32, _>("semantic_auto_infer_ms")
                .ok()
                .flatten()
                .unwrap_or(15_000)
                .clamp(0, 30_000)
                .cast_unsigned(),
            infer_max_rows: row
                .get_by_name::<i32, _>("semantic_auto_max_rows")
                .ok()
                .flatten()
                .unwrap_or(1)
                .clamp(0, 10)
                .cast_unsigned(),
        })
    })
    .unwrap_or(SemanticAutoPolicy {
        // SPI failure: fail closed — no refresh, no wait/infer budget.
        auto_policy: true,
        allow_refresh: false,
        wait_ms: 0,
        infer_ms: 0,
        infer_max_rows: 0,
    });
    CACHED.set(Some((stmt_start, policy)));
    policy
}
