struct CustomScanPrivate {
    index_kind: SemanticIndexKind,
    index_name: String,
    expected_json: String,
    subject_attno: i16,
    subject_typid: pg_sys::Oid,
    selected_path: String,
    reason: String,
    stale_reasons: String,
    model_cost_source: String,
    model_ms: f64,
    count_basis: String,
    infer_decision_rows: u64,
    fail_closed_decision_rows: u64,
    input_columns: Option<Vec<String>>,
}

unsafe fn custom_private_from_predicate(predicate: &SemanticMatchPredicate) -> *mut pg_sys::List {
    unsafe {
        let payload = json!({
            "index_kind": predicate.index_kind.as_str(),
            "index_name": &predicate.index_name,
            "expected_json": &predicate.expected_json,
            "subject_attno": predicate.subject_attno,
            "subject_typid": predicate.subject_typid.to_u32(),
            "selected_path": &predicate.planner_stats.selected_path,
            "reason": &predicate.planner_stats.reason,
            "stale_reasons": &predicate.planner_stats.stale_reasons,
            "model_cost_source": &predicate.planner_stats.model_cost_source,
            "model_ms": predicate.planner_stats.model_ms,
            "count_basis": &predicate.planner_stats.count_basis,
            "infer_decision_rows": predicate.planner_stats.infer_decision_rows,
            "fail_closed_decision_rows": predicate.planner_stats.fail_closed_decision_rows,
            "input_columns": &predicate.input_columns
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

        Some(CustomScanPrivate {
            index_kind: payload
                .get("index_kind")
                .and_then(Value::as_str)
                .and_then(SemanticIndexKind::from_str)
                .unwrap_or(SemanticIndexKind::Row),
            index_name: payload.get("index_name")?.as_str()?.to_string(),
            expected_json: payload.get("expected_json")?.as_str()?.to_string(),
            subject_attno: payload.get("subject_attno")?.as_i64()?.try_into().ok()?,
            subject_typid: pg_sys::Oid::from(payload.get("subject_typid")?.as_u64()? as u32),
            selected_path: payload.get("selected_path")?.as_str()?.to_string(),
            reason: payload
                .get("reason")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            stale_reasons: payload
                .get("stale_reasons")
                .and_then(Value::as_str)
                .unwrap_or("{}")
                .to_string(),
            model_cost_source: payload
                .get("model_cost_source")
                .and_then(Value::as_str)
                .unwrap_or("static_fallback")
                .to_string(),
            model_ms: payload
                .get("model_ms")
                .and_then(Value::as_f64)
                .unwrap_or(2500.0),
            count_basis: payload
                .get("count_basis")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string(),
            infer_decision_rows: payload
                .get("infer_decision_rows")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            fail_closed_decision_rows: payload
                .get("fail_closed_decision_rows")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            input_columns: payload
                .get("input_columns")
                .and_then(Value::as_array)
                .map(|columns| {
                    columns
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect()
                }),
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
