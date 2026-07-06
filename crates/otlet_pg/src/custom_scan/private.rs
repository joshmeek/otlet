struct CustomScanPrivate {
    index_kind: SemanticIndexKind,
    index_name: String,
    expected_json: String,
    subject_attno: i16,
    subject_typid: pg_sys::Oid,
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

fn reload_private_planner_stats(private: &CustomScanPrivate) -> SemanticPlannerStats {
    let plan_function = match private.index_kind {
        SemanticIndexKind::Row => "otlet.semantic_index_plan",
        SemanticIndexKind::Join => "otlet.semantic_join_index_plan",
    };
    let query = format!(
        "SELECT selected_path, reason, total_subjects, fresh_subjects, stale_subjects, missing_subjects, inflight_subjects, \
         infer_now_subjects, fail_closed_subjects, model_ms::float8 AS model_ms, model_cost_source, path_cost::float8 AS path_cost, \
         stale_reasons::text AS stale_reasons, count_basis \
         FROM {}({})",
        plan_function,
        sql_literal(&private.index_name)
    );

    pgrx::Spi::connect(|client| {
        let table = client.select(query.as_str(), Some(1), &[]).map_err(to_string)?;
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
                    .unwrap_or(0)
                    .max(0) as u64
            };
        }
        Ok::<SemanticPlannerStats, String>(SemanticPlannerStats {
            selected_path: text!("selected_path", "semantic_lookup"),
            reason: text!("reason", "reloaded_from_sql_plan"),
            source_rows: count!("total_subjects"),
            fresh_matches: count!("fresh_subjects"),
            fresh_non_matches: 0,
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
        })
    })
    .unwrap_or_else(|err| {
        pgrx::warning!("otlet semantic CustomScan private plan reload failed: {err}");
        SemanticPlannerStats {
            selected_path: "semantic_lookup".to_owned(),
            reason: "private_plan_reload_failed".to_owned(),
            source_rows: 0,
            fresh_matches: 0,
            fresh_non_matches: 0,
            stale_rows: 0,
            missing_rows: 0,
            inflight_rows: 0,
            cache_reusable_rows: 0,
            infer_decision_rows: 0,
            fail_closed_decision_rows: 0,
            model_ms: 2500.0,
            model_cost_source: "static_fallback".to_owned(),
            path_cost: 1.0,
            stale_reasons: "{}".to_owned(),
            count_basis: "unknown".to_owned(),
        }
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
