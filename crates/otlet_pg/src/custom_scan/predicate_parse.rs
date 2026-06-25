unsafe fn find_semantic_match_predicate(
    restrictinfos: *mut pg_sys::List,
    rti: pg_sys::Index,
    relid: Option<pg_sys::Oid>,
    rte_kind: pg_sys::RTEKind::Type,
) -> Option<SemanticMatchPredicate> {
    unsafe {
        for idx in 0..pg_sys::list_length(restrictinfos) {
            let rinfo = pg_sys::list_nth(restrictinfos, idx) as *mut pg_sys::RestrictInfo;
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
                    validate_semantic_index_source(
                        &predicate.index_name,
                        predicate.predicate_kind,
                        relid,
                        predicate.subject_attno,
                        &predicate.expected_json,
                        predicate.action_type.as_deref(),
                        predicate.allow_refresh,
                        predicate.wait_ms,
                        predicate.infer_ms,
                        predicate.infer_max_rows,
                        predicate.auto_policy,
                    )
                }
                SemanticIndexKind::Join => {
                    if rte_kind != pg_sys::RTEKind::RTE_SUBQUERY {
                        continue;
                    }
                    validate_semantic_join_index_source(
                        &predicate.index_name,
                        &predicate.expected_json,
                        predicate.allow_refresh,
                        predicate.wait_ms,
                        predicate.infer_ms,
                        predicate.infer_max_rows,
                        predicate.auto_policy,
                    )
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
            predicate_kind: parts.predicate_kind,
            index_name: parts.index_name,
            expected_json: parts.expected_json,
            action_type: parts.action_type,
            program_name: parts.program_name,
            program_hash: parts.program_hash,
            program_predicate: parts.program_predicate,
            program_compiler_mode: parts.program_compiler_mode,
            auto_policy: parts.auto_policy,
            allow_refresh: parts.allow_refresh,
            wait_ms: parts.wait_ms,
            infer_ms: parts.infer_ms,
            infer_max_rows: parts.infer_max_rows,
            subject_attno: parts.subject.attno,
            subject_typid: parts.subject.typid,
            restrict_info: ptr::null_mut(),
            estimated_rows: 1.0,
            planner_stats: planner_stats_unknown(),
        })
    }
}

struct ParsedSemanticMatch {
    index_kind: SemanticIndexKind,
    predicate_kind: SemanticPredicateKind,
    index_name: String,
    subject: SubjectVar,
    expected_json: String,
    action_type: Option<String>,
    program_name: Option<String>,
    program_hash: Option<String>,
    program_predicate: Option<String>,
    program_compiler_mode: Option<String>,
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
        let func = clause as *mut pg_sys::FuncExpr;
        let is_matches = is_otlet_function((*func).funcid, "semantic_matches");
        let is_auto = is_otlet_function((*func).funcid, "semantic_matches_auto");
        let is_action_matches = is_otlet_function((*func).funcid, "semantic_action_matches");
        let is_action_program =
            is_otlet_function((*func).funcid, "semantic_action_matches_program");
        let is_program = is_otlet_function((*func).funcid, "semantic_matches_program");
        if is_action_matches {
            if pg_sys::list_length((*func).args) < 4 {
                return None;
            }
            let index_arg = pg_sys::list_nth((*func).args, 0) as *mut pg_sys::Expr;
            let subject_arg = pg_sys::list_nth((*func).args, 1) as *mut pg_sys::Expr;
            let action_type_arg = pg_sys::list_nth((*func).args, 2) as *mut pg_sys::Expr;
            let expected_arg = pg_sys::list_nth((*func).args, 3) as *mut pg_sys::Expr;
            return Some(ParsedSemanticMatch {
                index_kind: SemanticIndexKind::Row,
                predicate_kind: SemanticPredicateKind::Action,
                index_name: text_const_value(index_arg)?,
                subject: subject_var(subject_arg, rti)?,
                expected_json: jsonb_const_text(expected_arg)?,
                action_type: Some(text_const_value(action_type_arg)?),
                program_name: None,
                program_hash: None,
                program_predicate: None,
                program_compiler_mode: None,
                auto_policy: false,
                allow_refresh: false,
                wait_ms: 0,
                infer_ms: 0,
                infer_max_rows: 0,
            });
        }
        if is_action_program {
            if pg_sys::list_length((*func).args) < 2 {
                return None;
            }
            let program_arg = pg_sys::list_nth((*func).args, 0) as *mut pg_sys::Expr;
            let subject_arg = pg_sys::list_nth((*func).args, 1) as *mut pg_sys::Expr;
            let program_name = text_const_value(program_arg)?;
            let program = load_semantic_action_program(&program_name)?;
            return Some(ParsedSemanticMatch {
                index_kind: SemanticIndexKind::Row,
                predicate_kind: SemanticPredicateKind::Action,
                index_name: program.index_name,
                subject: subject_var(subject_arg, rti)?,
                expected_json: program.expected_json,
                action_type: Some(program.action_type),
                program_name: Some(program.name),
                program_hash: Some(program.program_hash),
                program_predicate: Some(program.predicate),
                program_compiler_mode: Some(program.compiler_mode),
                auto_policy: false,
                allow_refresh: false,
                wait_ms: 0,
                infer_ms: 0,
                infer_max_rows: 0,
            });
        }
        let is_join_program = is_otlet_function((*func).funcid, "semantic_join_matches_program");
        if is_program {
            if pg_sys::list_length((*func).args) < 2 {
                return None;
            }
            let program_arg = pg_sys::list_nth((*func).args, 0) as *mut pg_sys::Expr;
            let subject_arg = pg_sys::list_nth((*func).args, 1) as *mut pg_sys::Expr;
            let program_name = text_const_value(program_arg)?;
            let program = load_semantic_program(&program_name)?;
            return Some(ParsedSemanticMatch {
                index_kind: SemanticIndexKind::Row,
                predicate_kind: SemanticPredicateKind::Materialization,
                index_name: program.index_name,
                subject: subject_var(subject_arg, rti)?,
                expected_json: program.expected_json,
                action_type: None,
                program_name: Some(program.name),
                program_hash: Some(program.program_hash),
                program_predicate: Some(program.predicate),
                program_compiler_mode: Some(program.compiler_mode),
                auto_policy: false,
                allow_refresh: false,
                wait_ms: 0,
                infer_ms: 0,
                infer_max_rows: 0,
            });
        }
        if is_join_program {
            if pg_sys::list_length((*func).args) < 2 {
                return None;
            }
            let program_arg = pg_sys::list_nth((*func).args, 0) as *mut pg_sys::Expr;
            let subject_arg = pg_sys::list_nth((*func).args, 1) as *mut pg_sys::Expr;
            let program_name = text_const_value(program_arg)?;
            let program = load_semantic_join_program(&program_name)?;
            return Some(ParsedSemanticMatch {
                index_kind: SemanticIndexKind::Join,
                predicate_kind: SemanticPredicateKind::Materialization,
                index_name: program.index_name,
                subject: subject_var(subject_arg, rti)?,
                expected_json: program.expected_json,
                action_type: None,
                program_name: Some(program.name),
                program_hash: Some(program.program_hash),
                program_predicate: Some(program.predicate),
                program_compiler_mode: Some(program.compiler_mode),
                auto_policy: false,
                allow_refresh: false,
                wait_ms: 0,
                infer_ms: 0,
                infer_max_rows: 0,
            });
        }
        let is_join_matches = is_otlet_function((*func).funcid, "semantic_join_matches");
        let is_join_auto = is_otlet_function((*func).funcid, "semantic_join_matches_auto");
        let is_join = is_join_matches || is_join_auto;
        let is_any_auto = is_auto || is_join_auto;
        if (!is_matches && !is_auto && !is_join) || pg_sys::list_length((*func).args) < 3 {
            return None;
        }

        let index_arg = pg_sys::list_nth((*func).args, 0) as *mut pg_sys::Expr;
        let subject_arg = pg_sys::list_nth((*func).args, 1) as *mut pg_sys::Expr;
        let expected_arg = pg_sys::list_nth((*func).args, 2) as *mut pg_sys::Expr;
        let allow_refresh = if is_any_auto {
            if pg_sys::list_length((*func).args) >= 7 {
                let allow_refresh_arg = pg_sys::list_nth((*func).args, 6) as *mut pg_sys::Expr;
                bool_const_value(allow_refresh_arg)?
            } else {
                true
            }
        } else {
            false
        };
        let wait_ms = if is_any_auto {
            if pg_sys::list_length((*func).args) >= 4 {
                let wait_arg = pg_sys::list_nth((*func).args, 3) as *mut pg_sys::Expr;
                int_const_value(wait_arg)?.clamp(0, 30_000) as u32
            } else {
                10_000
            }
        } else {
            0
        };
        let infer_ms = if is_any_auto {
            if pg_sys::list_length((*func).args) >= 5 {
                let infer_arg = pg_sys::list_nth((*func).args, 4) as *mut pg_sys::Expr;
                int_const_value(infer_arg)?.clamp(0, 30_000) as u32
            } else {
                wait_ms
            }
        } else {
            0
        };
        let infer_max_rows = if is_any_auto {
            if pg_sys::list_length((*func).args) >= 6 {
                let max_rows_arg = pg_sys::list_nth((*func).args, 5) as *mut pg_sys::Expr;
                int_const_value(max_rows_arg)?.clamp(0, 10) as u32
            } else {
                1
            }
        } else {
            0
        };
        Some(ParsedSemanticMatch {
            index_kind: if is_join {
                SemanticIndexKind::Join
            } else {
                SemanticIndexKind::Row
            },
            predicate_kind: SemanticPredicateKind::Materialization,
            index_name: text_const_value(index_arg)?,
            subject: subject_var(subject_arg, rti)?,
            expected_json: jsonb_const_text(expected_arg)?,
            action_type: None,
            program_name: None,
            program_hash: None,
            program_predicate: None,
            program_compiler_mode: None,
            auto_policy: is_any_auto,
            allow_refresh,
            wait_ms,
            infer_ms,
            infer_max_rows,
        })
    }
}
