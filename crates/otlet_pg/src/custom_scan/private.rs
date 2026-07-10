struct CustomScanPrivate {
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
    planner_stats: Option<SemanticPlannerStats>,
}

fn planner_stats_to_json(stats: &SemanticPlannerStats) -> Value {
    json!({
        "selected_path": &stats.selected_path,
        "reason": &stats.reason,
        "source_rows": stats.source_rows,
        "fresh_matches": stats.fresh_matches,
        "fresh_non_matches": stats.fresh_non_matches,
        "stale_rows": stats.stale_rows,
        "missing_rows": stats.missing_rows,
        "inflight_rows": stats.inflight_rows,
        "cache_reusable_rows": stats.cache_reusable_rows,
        "infer_decision_rows": stats.infer_decision_rows,
        "fail_closed_decision_rows": stats.fail_closed_decision_rows,
        "model_ms": stats.model_ms,
        "model_cost_source": &stats.model_cost_source,
        "path_cost": stats.path_cost,
        "stale_reasons": &stats.stale_reasons,
        "count_basis": &stats.count_basis,
    })
}

fn planner_stats_from_json(value: &Value) -> Option<SemanticPlannerStats> {
    Some(SemanticPlannerStats {
        selected_path: value.get("selected_path")?.as_str()?.to_owned(),
        reason: value.get("reason")?.as_str()?.to_owned(),
        source_rows: value.get("source_rows")?.as_u64()?,
        fresh_matches: value.get("fresh_matches")?.as_u64()?,
        fresh_non_matches: value.get("fresh_non_matches")?.as_u64()?,
        stale_rows: value.get("stale_rows")?.as_u64()?,
        missing_rows: value.get("missing_rows")?.as_u64()?,
        inflight_rows: value.get("inflight_rows")?.as_u64()?,
        cache_reusable_rows: value
            .get("cache_reusable_rows")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        infer_decision_rows: value.get("infer_decision_rows")?.as_u64()?,
        fail_closed_decision_rows: value.get("fail_closed_decision_rows")?.as_u64()?,
        model_ms: value.get("model_ms")?.as_f64()?,
        model_cost_source: value.get("model_cost_source")?.as_str()?.to_owned(),
        path_cost: value.get("path_cost")?.as_f64()?,
        stale_reasons: value.get("stale_reasons")?.as_str()?.to_owned(),
        count_basis: value.get("count_basis")?.as_str()?.to_owned(),
    })
}

unsafe fn custom_private_from_predicate(predicate: &SemanticMatchPredicate) -> *mut pg_sys::List {
    unsafe {
        let payload = json!({
            "index_kind": predicate.index_kind.as_str(),
            "index_name": &predicate.index_name,
            "expected_json": &predicate.expected_json,
            "auto_policy": predicate.auto_policy,
            "allow_refresh": predicate.allow_refresh,
            "wait_ms": predicate.wait_ms,
            "infer_ms": predicate.infer_ms,
            "infer_max_rows": predicate.infer_max_rows,
            "subject_attno": predicate.subject_attno,
            "subject_typid": predicate.subject_typid.to_u32(),
            "planner_stats": planner_stats_to_json(&predicate.planner_stats),
        });
        let mut list = ptr::null_mut();
        list = append_string_node(list, CUSTOM_PRIVATE_MARKER);
        append_string_node(list, &payload.to_string())
    }
}

unsafe fn custom_private_from_plan(
    node: *mut pg_sys::CustomScanState,
) -> Option<CustomScanPrivate> {
    unsafe {
        if node.is_null() || (*node).ss.ps.plan.is_null() {
            return None;
        }
        let scan = (*node).ss.ps.plan.cast::<pg_sys::CustomScan>();
        custom_private_from_list((*scan).custom_private)
    }
}

unsafe fn custom_private_from_list(private: *mut pg_sys::List) -> Option<CustomScanPrivate> {
    unsafe {
        if private.is_null() || pg_sys::list_length(private) < 2 {
            return None;
        }

        let marker = string_node_value(pg_sys::list_nth(private, 0).cast::<pg_sys::String>())?;
        if marker != CUSTOM_PRIVATE_MARKER {
            return None;
        }
        let payload_text =
            string_node_value(pg_sys::list_nth(private, 1).cast::<pg_sys::String>())?;
        let payload: Value = serde_json::from_str(&payload_text).ok()?;

        Some(CustomScanPrivate {
            index_kind: payload
                .get("index_kind")
                .and_then(Value::as_str)
                .and_then(SemanticIndexKind::from_str)
                .unwrap_or(SemanticIndexKind::Row),
            index_name: payload.get("index_name")?.as_str()?.to_owned(),
            expected_json: payload.get("expected_json")?.as_str()?.to_owned(),
            auto_policy: payload
                .get("auto_policy")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            allow_refresh: payload
                .get("allow_refresh")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            wait_ms: payload
                .get("wait_ms")
                .and_then(Value::as_u64)
                .map_or(0, u64_to_u32_saturating),
            infer_ms: payload
                .get("infer_ms")
                .and_then(Value::as_u64)
                .map_or(0, u64_to_u32_saturating),
            infer_max_rows: payload
                .get("infer_max_rows")
                .and_then(Value::as_u64)
                .map_or(0, u64_to_u32_saturating),
            subject_attno: payload.get("subject_attno")?.as_i64()?.try_into().ok()?,
            subject_typid: pg_sys::Oid::from(u32::try_from(
                payload.get("subject_typid")?.as_u64()?,
            )
            .ok()?),
            planner_stats: payload.get("planner_stats").and_then(planner_stats_from_json),
        })
    }
}

fn reload_private_planner_stats_plan_only(private: &CustomScanPrivate) -> SemanticPlannerStats {
    pgrx::Spi::connect(|client| {
        let args = [private.index_name.as_str().into()];
        let query = match private.index_kind {
            SemanticIndexKind::Row => {
                "SELECT \
                   COALESCE(selected_path, 'semantic_lookup')::text AS selected_path, \
                   COALESCE(reason, 'reloaded_from_sql_plan')::text AS reason, \
                   COALESCE(total_subjects, 0)::bigint AS total_subjects, \
                   0::bigint AS fresh_matches, \
                   0::bigint AS fresh_non_matches, \
                   COALESCE(stale_subjects, 0)::bigint AS stale_subjects, \
                   COALESCE(missing_subjects, 0)::bigint AS missing_subjects, \
                   COALESCE(inflight_subjects, 0)::bigint AS inflight_subjects, \
                   COALESCE(infer_now_subjects, 0)::bigint AS infer_now_subjects, \
                   COALESCE(fail_closed_subjects, 0)::bigint AS fail_closed_subjects, \
                   COALESCE(model_ms, 2500)::float8 AS model_ms, \
                   COALESCE(model_cost_source, 'static_fallback')::text AS model_cost_source, \
                   COALESCE(path_cost, 1)::float8 AS path_cost, \
                   COALESCE(stale_reasons::text, '{}')::text AS stale_reasons, \
                   COALESCE(count_basis, 'exact')::text AS count_basis \
                 FROM otlet.semantic_index_plan($1, true)"
            }
            SemanticIndexKind::Join => {
                "SELECT \
                   COALESCE(selected_path, 'semantic_lookup')::text AS selected_path, \
                   COALESCE(reason, 'reloaded_from_sql_plan')::text AS reason, \
                   COALESCE(total_subjects, 0)::bigint AS total_subjects, \
                   0::bigint AS fresh_matches, \
                   0::bigint AS fresh_non_matches, \
                   COALESCE(stale_subjects, 0)::bigint AS stale_subjects, \
                   COALESCE(missing_subjects, 0)::bigint AS missing_subjects, \
                   COALESCE(inflight_subjects, 0)::bigint AS inflight_subjects, \
                   COALESCE(infer_now_subjects, 0)::bigint AS infer_now_subjects, \
                   COALESCE(fail_closed_subjects, 0)::bigint AS fail_closed_subjects, \
                   COALESCE(model_ms, 2500)::float8 AS model_ms, \
                   COALESCE(model_cost_source, 'static_fallback')::text AS model_cost_source, \
                   COALESCE(path_cost, 1)::float8 AS path_cost, \
                   COALESCE(stale_reasons::text, '{}')::text AS stale_reasons, \
                   COALESCE(count_basis, 'exact')::text AS count_basis \
                 FROM otlet.semantic_join_index_plan($1)"
            }
        };
        let table = client.select(query, Some(1), &args).map_err(to_string)?;
        if table.is_empty() {
            return Err("missing semantic index plan".to_owned());
        }
        let row = table.first();
        macro_rules! text {
            ($name:literal, $default:literal) => {
                row.get_by_name::<String, _>($name)
                    .map_err(to_string)?
                    .unwrap_or_else(|| $default.to_string())
            };
        }
        macro_rules! count {
            ($name:literal) => {
                row.get_by_name::<i64, _>($name)
                    .map_err(to_string)?
                    .map_or(0, nonnegative_count)
            };
        }
        let mut stats = SemanticPlannerStats {
            selected_path: text!("selected_path", "semantic_lookup"),
            reason: text!("reason", "reloaded_from_sql_plan"),
            source_rows: count!("total_subjects"),
            fresh_matches: count!("fresh_matches"),
            fresh_non_matches: count!("fresh_non_matches"),
            stale_rows: count!("stale_subjects"),
            missing_rows: count!("missing_subjects"),
            inflight_rows: count!("inflight_subjects"),
            cache_reusable_rows: 0,
            infer_decision_rows: count!("infer_now_subjects"),
            fail_closed_decision_rows: count!("fail_closed_subjects"),
            model_ms: row
                .get_by_name::<f64, _>("model_ms")
                .map_err(to_string)?
                .unwrap_or(2500.0)
                .max(1.0),
            model_cost_source: text!("model_cost_source", "static_fallback"),
            path_cost: row
                .get_by_name::<f64, _>("path_cost")
                .map_err(to_string)?
                .unwrap_or(1.0)
                .max(0.0),
            stale_reasons: text!("stale_reasons", "{}"),
            count_basis: text!("count_basis", "estimated"),
        };
        finish_planner_stats(
            &mut stats,
            private.allow_refresh,
            private.wait_ms,
            private.infer_ms,
            private.infer_max_rows,
            private.auto_policy,
        );
        if private.index_kind == SemanticIndexKind::Join && stats.selected_path == "semantic_lookup"
        {
            stats.selected_path = "semantic_join_lookup".to_owned();
        }
        Ok::<SemanticPlannerStats, String>(stats)
    })
    .unwrap_or_else(|err| {
        pgrx::warning!("otlet semantic CustomScan private plan reload failed: {err}");
        planner_stats_with_reason("private_plan_reload_failed")
    })
}


unsafe fn list_make1(value: *mut std::ffi::c_void) -> *mut pg_sys::List {
    unsafe {
        pg_sys::list_make1_impl(
            pg_sys::NodeTag::T_List,
            pg_sys::ListCell { ptr_value: value },
        )
    }
}

unsafe fn append_string_node(list: *mut pg_sys::List, value: &str) -> *mut pg_sys::List {
    unsafe {
        let node = string_node(value);
        if node.is_null() {
            return list;
        }
        if list.is_null() {
            list_make1(node.cast())
        } else {
            pg_sys::lappend(list, node.cast())
        }
    }
}

unsafe fn string_node(value: &str) -> *mut pg_sys::String {
    unsafe {
        CString::new(value)
            .map(|value| pg_sys::makeString(pg_sys::pstrdup(value.as_ptr())))
            .unwrap_or(ptr::null_mut())
    }
}

unsafe fn string_node_value(string_node: *mut pg_sys::String) -> Option<String> {
    unsafe {
        if string_node.is_null()
            || (*string_node).type_ != pg_sys::NodeTag::T_String
            || (*string_node).sval.is_null()
        {
            return None;
        }
        // Fail closed on invalid UTF-8 rather than silently mojibake plan private.
        Some(CStr::from_ptr((*string_node).sval).to_str().ok()?.to_owned())
    }
}

unsafe fn strip_relabel(node: *mut pg_sys::Expr) -> *mut pg_sys::Expr {
    unsafe {
        let mut current = node;
        while !current.is_null() && (*current).type_ == pg_sys::NodeTag::T_RelabelType {
            current = (*current.cast::<pg_sys::RelabelType>()).arg;
        }
        current
    }
}

unsafe fn text_const_value(node: *mut pg_sys::Expr) -> Option<String> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Const {
            return None;
        }
        let value = node.cast::<pg_sys::Const>();
        if (*value).constisnull || (*value).consttype != pg_sys::TEXTOID {
            return None;
        }
        <String as FromDatum>::from_polymorphic_datum(
            (*value).constvalue,
            false,
            (*value).consttype,
        )
    }
}

unsafe fn jsonb_const_text(node: *mut pg_sys::Expr) -> Option<String> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Const {
            return None;
        }
        let value = node.cast::<pg_sys::Const>();
        if (*value).constisnull || (*value).consttype != pg_sys::JSONBOID {
            return None;
        }
        let jsonb = <JsonB as FromDatum>::from_polymorphic_datum(
            (*value).constvalue,
            false,
            (*value).consttype,
        )?;
        serde_json::to_string(&jsonb.0).ok()
    }
}

unsafe fn datum_to_text(value: pg_sys::Datum, typid: pg_sys::Oid) -> Option<String> {
    unsafe {
        if typid == pg_sys::TEXTOID {
            return <String as FromDatum>::from_polymorphic_datum(value, false, typid);
        }
        let output_oid = cached_type_output_oid(typid)?;
        let output = pg_sys::OidOutputFunctionCall(output_oid, value);
        if output.is_null() {
            return None;
        }
        // Fail closed on invalid UTF-8 rather than silently mojibake subjects.
        let text = CStr::from_ptr(output).to_str().ok()?.to_owned();
        pg_sys::pfree(output.cast());
        Some(text)
    }
}

unsafe fn cached_type_output_oid(typid: pg_sys::Oid) -> Option<pg_sys::Oid> {
    // Backend-local cache: CustomScan subject extraction is single-threaded per
    // backend, so avoid a global mutex on every non-text subject row.
    thread_local! {
        static CACHE: RefCell<HashMap<pg_sys::Oid, pg_sys::Oid>> =
            RefCell::new(HashMap::with_capacity(16));
    }
    if let Some(oid) = CACHE.with(|cache| cache.borrow().get(&typid).copied()) {
        return Some(oid);
    }

    unsafe {
        let mut output_oid = pg_sys::InvalidOid;
        let mut is_varlena = false;
        pg_sys::getTypeOutputInfo(typid, &raw mut output_oid, &raw mut is_varlena);
        if output_oid == pg_sys::InvalidOid {
            return None;
        }
        CACHE.with(|cache| {
            cache.borrow_mut().insert(typid, output_oid);
        });
        Some(output_oid)
    }
}

unsafe fn clear_slot(slot: *mut pg_sys::TupleTableSlot) -> *mut pg_sys::TupleTableSlot {
    unsafe {
        if slot.is_null() {
            slot
        } else {
            pg_sys::ExecClearTuple(slot)
        }
    }
}

unsafe fn emit_buffered_row(
    node: *mut pg_sys::CustomScanState,
    runtime: &mut RuntimeState,
) -> Option<*mut pg_sys::TupleTableSlot> {
    unsafe {
        let buffered_slot = runtime.pending_output_rows.pop_front()?;
        let slot = (*node).ss.ss_ScanTupleSlot;
        if slot.is_null() {
            pg_sys::ExecDropSingleTupleTableSlot(buffered_slot);
            return None;
        }
        runtime.rows_returned = runtime.rows_returned.saturating_add(1);
        let output_slot = pg_sys::ExecCopySlot(slot, buffered_slot);
        pg_sys::ExecDropSingleTupleTableSlot(buffered_slot);
        Some(output_slot)
    }
}
