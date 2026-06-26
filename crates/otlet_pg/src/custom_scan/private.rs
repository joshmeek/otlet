struct CustomScanPrivate {
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
    planner_stats: SemanticPlannerStats,
}

unsafe fn custom_private_from_predicate(predicate: &SemanticMatchPredicate) -> *mut pg_sys::List {
    unsafe {
        let payload = json!({
            "index_kind": predicate.index_kind.as_str(),
            "predicate_kind": predicate.predicate_kind.as_str(),
            "index_name": &predicate.index_name,
            "expected_json": &predicate.expected_json,
            "action_type": &predicate.action_type,
            "auto_policy": predicate.auto_policy,
            "allow_refresh": predicate.allow_refresh,
            "wait_ms": predicate.wait_ms,
            "infer_ms": predicate.infer_ms,
            "infer_max_rows": predicate.infer_max_rows,
            "subject_attno": predicate.subject_attno,
            "subject_typid": predicate.subject_typid.to_u32(),
            "planner_stats": {
                "selected_path": &predicate.planner_stats.selected_path,
                "reason": &predicate.planner_stats.reason,
                "source_rows": predicate.planner_stats.source_rows,
                "fresh_matches": predicate.planner_stats.fresh_matches,
                "fresh_non_matches": predicate.planner_stats.fresh_non_matches,
                "stale_rows": predicate.planner_stats.stale_rows,
                "missing_rows": predicate.planner_stats.missing_rows,
                "inflight_rows": predicate.planner_stats.inflight_rows,
                "cache_reusable_rows": predicate.planner_stats.cache_reusable_rows,
                "lookup_decision_rows": predicate.planner_stats.lookup_decision_rows,
                "wait_decision_rows": predicate.planner_stats.wait_decision_rows,
                "infer_decision_rows": predicate.planner_stats.infer_decision_rows,
                "queue_decision_rows": predicate.planner_stats.queue_decision_rows,
                "fail_closed_decision_rows": predicate.planner_stats.fail_closed_decision_rows,
                "model_ms": predicate.planner_stats.model_ms,
                "path_cost": predicate.planner_stats.path_cost
            }
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
        let scan = (*node).ss.ps.plan as *mut pg_sys::CustomScan;
        custom_private_from_list((*scan).custom_private)
    }
}

unsafe fn custom_private_from_list(private: *mut pg_sys::List) -> Option<CustomScanPrivate> {
    unsafe {
        if private.is_null() || pg_sys::list_length(private) < 2 {
            return None;
        }

        let marker = string_node_value(pg_sys::list_nth(private, 0) as *mut pg_sys::String)?;
        if marker != CUSTOM_PRIVATE_MARKER {
            return None;
        }
        let payload_text = string_node_value(pg_sys::list_nth(private, 1) as *mut pg_sys::String)?;
        let payload: Value = serde_json::from_str(&payload_text).ok()?;
        let stats = payload.get("planner_stats")?;

        Some(CustomScanPrivate {
            index_kind: payload
                .get("index_kind")
                .and_then(Value::as_str)
                .and_then(SemanticIndexKind::from_str)
                .unwrap_or(SemanticIndexKind::Row),
            predicate_kind: payload
                .get("predicate_kind")
                .and_then(Value::as_str)
                .and_then(SemanticPredicateKind::from_str)
                .unwrap_or(SemanticPredicateKind::Materialization),
            index_name: payload.get("index_name")?.as_str()?.to_string(),
            expected_json: payload.get("expected_json")?.as_str()?.to_string(),
            action_type: payload
                .get("action_type")
                .and_then(Value::as_str)
                .map(str::to_string),
            auto_policy: payload.get("auto_policy")?.as_bool()?,
            allow_refresh: payload.get("allow_refresh")?.as_bool()?,
            wait_ms: payload.get("wait_ms")?.as_u64()?.try_into().ok()?,
            infer_ms: payload.get("infer_ms")?.as_u64()?.try_into().ok()?,
            infer_max_rows: payload.get("infer_max_rows")?.as_u64()?.try_into().ok()?,
            subject_attno: payload.get("subject_attno")?.as_i64()?.try_into().ok()?,
            subject_typid: pg_sys::Oid::from(payload.get("subject_typid")?.as_u64()? as u32),
            planner_stats: SemanticPlannerStats {
                selected_path: stats.get("selected_path")?.as_str()?.to_string(),
                reason: stats.get("reason")?.as_str()?.to_string(),
                source_rows: stats.get("source_rows")?.as_u64()?,
                fresh_matches: stats.get("fresh_matches")?.as_u64()?,
                fresh_non_matches: stats.get("fresh_non_matches")?.as_u64()?,
                stale_rows: stats.get("stale_rows")?.as_u64()?,
                missing_rows: stats.get("missing_rows")?.as_u64()?,
                inflight_rows: stats.get("inflight_rows")?.as_u64()?,
                cache_reusable_rows: stats.get("cache_reusable_rows")?.as_u64()?,
                lookup_decision_rows: stats.get("lookup_decision_rows")?.as_u64()?,
                wait_decision_rows: stats.get("wait_decision_rows")?.as_u64()?,
                infer_decision_rows: stats.get("infer_decision_rows")?.as_u64()?,
                queue_decision_rows: stats.get("queue_decision_rows")?.as_u64()?,
                fail_closed_decision_rows: stats.get("fail_closed_decision_rows")?.as_u64()?,
                model_ms: stats.get("model_ms")?.as_f64()?,
                path_cost: stats.get("path_cost")?.as_f64()?,
            },
        })
    }
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
        Some(
            CStr::from_ptr((*string_node).sval)
                .to_string_lossy()
                .into_owned(),
        )
    }
}

unsafe fn strip_relabel(node: *mut pg_sys::Expr) -> *mut pg_sys::Expr {
    unsafe {
        let mut current = node;
        while !current.is_null() && (*current).type_ == pg_sys::NodeTag::T_RelabelType {
            current = (*(current as *mut pg_sys::RelabelType)).arg;
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
        let value = node as *mut pg_sys::Const;
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
        let value = node as *mut pg_sys::Const;
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

unsafe fn bool_const_value(node: *mut pg_sys::Expr) -> Option<bool> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Const {
            return None;
        }
        let value = node as *mut pg_sys::Const;
        if (*value).constisnull || (*value).consttype != pg_sys::BOOLOID {
            return None;
        }
        <bool as FromDatum>::from_polymorphic_datum((*value).constvalue, false, (*value).consttype)
    }
}

unsafe fn int_const_value(node: *mut pg_sys::Expr) -> Option<i32> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Const {
            return None;
        }
        let value = node as *mut pg_sys::Const;
        if (*value).constisnull || (*value).consttype != pg_sys::INT4OID {
            return None;
        }
        <i32 as FromDatum>::from_polymorphic_datum((*value).constvalue, false, (*value).consttype)
    }
}

unsafe fn datum_to_text(value: pg_sys::Datum, typid: pg_sys::Oid) -> Option<String> {
    unsafe {
        if typid == pg_sys::TEXTOID {
            return <String as FromDatum>::from_polymorphic_datum(value, false, typid);
        }
        let mut output_oid = pg_sys::InvalidOid;
        let mut is_varlena = false;
        pg_sys::getTypeOutputInfo(typid, &mut output_oid, &mut is_varlena);
        if output_oid == pg_sys::InvalidOid {
            return None;
        }
        let output = pg_sys::OidOutputFunctionCall(output_oid, value);
        if output.is_null() {
            return None;
        }
        let text = CStr::from_ptr(output).to_string_lossy().into_owned();
        pg_sys::pfree(output.cast());
        Some(text)
    }
}

unsafe fn clear_slot(slot: *mut pg_sys::TupleTableSlot) -> *mut pg_sys::TupleTableSlot {
    unsafe {
        if !slot.is_null() {
            pg_sys::ExecClearTuple(slot)
        } else {
            slot
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
