fn refresh_runtime_subject_state(
    runtime: &mut RuntimeState,
    subject_id: &str,
) -> Result<SubjectSemanticState, String> {
    let state = with_latest_snapshot(|| {
        semantic_subject_state(
            runtime.index_kind,
            &runtime.index_name,
            &runtime.expected_json,
            subject_id,
        )
    })?;
    runtime
        .semantic_states
        .insert(subject_id.to_owned(), state);
    Ok(state)
}

fn semantic_slot_input(
    runtime: &RuntimeState,
    subject_id: &str,
    slot: *mut pg_sys::TupleTableSlot,
) -> Result<Option<Value>, String> {
    if is_semantic_join_runtime(runtime) {
        return unsafe { semantic_join_slot_input(runtime, subject_id, slot) };
    }
    if slot.is_null() || runtime.source_reltype == pg_sys::InvalidOid {
        return Ok(None);
    }
    let row = project_row_json(
        unsafe { slot_row_json(slot, runtime.source_reltype)? },
        runtime.input_columns.as_deref(),
    );
    let ctid = unsafe { slot_tid_text(slot)? };
    let xmin = unsafe { slot_xmin_text(slot)? };
    Ok(Some(serde_json::json!({
        "_otlet_mvcc": {
            "table": runtime.source_table,
            "subject_id": subject_id,
            "ctid": ctid,
            "xmin": xmin
        },
        "table": runtime.source_table,
        "row": row
    })))
}

fn project_row_json(row: Value, input_columns: Option<&[String]>) -> Value {
    let Some(input_columns) = input_columns else {
        return row;
    };
    let Value::Object(object) = row else {
        return json!({});
    };
    let mut projected = serde_json::Map::new();
    for column in input_columns {
        if let Some(value) = object.get(column) {
            projected.insert(column.clone(), value.clone());
        }
    }
    Value::Object(projected)
}

unsafe fn semantic_join_slot_input(
    runtime: &RuntimeState,
    subject_id: &str,
    slot: *mut pg_sys::TupleTableSlot,
) -> Result<Option<Value>, String> {
    unsafe {
        let input = slot_jsonb_attribute(slot, "input")?.or_else(|| slot_semantic_join_jsonb_input(slot));
        let Some(input) = input else {
            return Ok(None);
        };
        match input {
            Value::Object(mut object) => {
                object.entry("_otlet_mvcc".to_owned()).or_insert_with(|| {
                    serde_json::json!({
                        "semantic_join_index": runtime.index_name,
                        "subject_id": subject_id
                    })
                });
                Ok(Some(Value::Object(object)))
            }
            value => Ok(Some(serde_json::json!({
                "_otlet_mvcc": {
                    "semantic_join_index": runtime.index_name,
                    "subject_id": subject_id
                },
                "input": value
            }))),
        }
    }
}

unsafe fn slot_semantic_join_jsonb_input(slot: *mut pg_sys::TupleTableSlot) -> Option<Value> {
    unsafe {
        if slot.is_null() {
            return None;
        }
        let tuple_desc = (*slot).tts_tupleDescriptor;
        if tuple_desc.is_null() {
            return None;
        }

        let natts = (*tuple_desc).natts;
        for idx in 0..natts {
            let attr = pg_sys::TupleDescAttr(tuple_desc, idx);
            if attr.is_null() || (*attr).attisdropped || (*attr).atttypid != pg_sys::JSONBOID {
                continue;
            }
            let mut isnull = false;
            let datum =
                pg_sys::slot_getattr(slot, std::ffi::c_int::from((*attr).attnum), &raw mut isnull);
            if isnull {
                continue;
            }
            let Some(json) =
                <JsonB as FromDatum>::from_polymorphic_datum(datum, false, pg_sys::JSONBOID)
            else {
                continue;
            };
            if semantic_join_input_shape(&json.0) {
                return Some(json.0);
            }
        }
        None
    }
}

fn semantic_join_input_shape(value: &Value) -> bool {
    let Value::Object(object) = value else {
        return false;
    };
    object.contains_key("_otlet_mvcc")
        || (object.contains_key("left_row") && object.contains_key("right_row"))
}

unsafe fn slot_jsonb_attribute(
    slot: *mut pg_sys::TupleTableSlot,
    attribute_name: &str,
) -> Result<Option<Value>, String> {
    unsafe {
        if slot.is_null() {
            return Ok(None);
        }
        let tuple_desc = (*slot).tts_tupleDescriptor;
        if tuple_desc.is_null() {
            return Ok(None);
        }

        let natts = (*tuple_desc).natts;
        for idx in 0..natts {
            let attr = pg_sys::TupleDescAttr(tuple_desc, idx);
            if attr.is_null() || (*attr).attisdropped {
                continue;
            }
            let name = CStr::from_ptr((*attr).attname.data.as_ptr())
                .to_str()
                .map_err(|err| err.to_string())?;
            if name != attribute_name {
                continue;
            }
            if (*attr).atttypid != pg_sys::JSONBOID {
                return Err(format!(
                    "projected semantic join attribute {attribute_name} has type oid {}, expected jsonb",
                    (*attr).atttypid
                ));
            }
            let mut isnull = false;
            let datum =
                pg_sys::slot_getattr(slot, std::ffi::c_int::from((*attr).attnum), &raw mut isnull);
            if isnull {
                return Ok(None);
            }
            return <JsonB as FromDatum>::from_polymorphic_datum(datum, false, pg_sys::JSONBOID)
                .map(|json| Some(json.0))
                .ok_or_else(|| {
                    format!("projected semantic join attribute {attribute_name} was not readable")
                });
        }
        Ok(None)
    }
}

unsafe fn slot_row_json(
    slot: *mut pg_sys::TupleTableSlot,
    row_type: pg_sys::Oid,
) -> Result<Value, String> {
    unsafe {
        let row_datum = pg_sys::ExecFetchSlotHeapTupleDatum(slot);
        typed_to_jsonb(row_datum, row_type)
    }
}

unsafe fn typed_to_jsonb(datum: pg_sys::Datum, type_oid: pg_sys::Oid) -> Result<Value, String> {
    unsafe {
        let function_info =
            pg_sys::palloc0(size_of::<pg_sys::FmgrInfo>()).cast::<pg_sys::FmgrInfo>();
        pg_sys::fmgr_info(pg_sys::F_TO_JSONB.into(), function_info);

        let func_expr =
            pg_sys::palloc0(size_of::<pg_sys::FuncExpr>()).cast::<pg_sys::FuncExpr>();
        (*func_expr).xpr.type_ = pg_sys::NodeTag::T_FuncExpr;
        (*func_expr).funcid = pg_sys::F_TO_JSONB.into();
        (*func_expr).funcresulttype = pg_sys::JSONBOID;
        (*func_expr).funcretset = false;
        (*func_expr).funcvariadic = false;
        (*func_expr).funcformat = pg_sys::CoercionForm::COERCE_EXPLICIT_CALL;
        (*func_expr).funccollid = pg_sys::InvalidOid;
        (*func_expr).inputcollid = pg_sys::InvalidOid;
        (*func_expr).location = -1;

        let arg = pg_sys::palloc0(size_of::<pg_sys::Const>()).cast::<pg_sys::Const>();
        (*arg).xpr.type_ = pg_sys::NodeTag::T_Const;
        (*arg).consttype = type_oid;
        (*arg).consttypmod = -1;
        (*arg).constcollid = pg_sys::InvalidOid;
        (*arg).constlen = -1;
        (*arg).constvalue = datum;
        (*arg).constisnull = false;
        (*arg).constbyval = false;
        (*arg).location = -1;

        (*func_expr).args = list_make1(arg.cast());
        (*function_info).fn_expr = func_expr.cast();

        let call_info_size =
            size_of::<pg_sys::FunctionCallInfoBaseData>() + size_of::<pg_sys::NullableDatum>();
        let call_info =
            pg_sys::palloc0(call_info_size).cast::<pg_sys::FunctionCallInfoBaseData>();
        (*call_info).flinfo = function_info;
        (*call_info).context = ptr::null_mut();
        (*call_info).resultinfo = ptr::null_mut();
        (*call_info).fncollation = pg_sys::InvalidOid;
        (*call_info).isnull = false;
        (*call_info).nargs = 1;
        let args_ptr: *mut pg_sys::NullableDatum = ptr::addr_of_mut!((*call_info).args).cast();
        (*args_ptr).value = datum;
        (*args_ptr).isnull = false;

        let result = pg_sys::to_jsonb(call_info);
        let is_null = (*call_info).isnull;
        pg_sys::pfree(call_info.cast());
        pg_sys::pfree(function_info.cast());
        pg_sys::list_free_deep((*func_expr).args);
        pg_sys::pfree(func_expr.cast());

        if is_null {
            return Err("Postgres to_jsonb returned null for source slot row".to_owned());
        }
        <JsonB as FromDatum>::from_polymorphic_datum(result, false, pg_sys::JSONBOID)
            .map(|json| json.0)
            .ok_or_else(|| "Postgres to_jsonb returned an unreadable jsonb datum".to_owned())
    }
}

unsafe fn slot_tid_text(slot: *mut pg_sys::TupleTableSlot) -> Result<String, String> {
    unsafe {
        let tid = &raw const (*slot).tts_tid;
        if !pg_sys::ItemPointerIsValid(tid) {
            return Err("source slot has no valid ctid".to_owned());
        }
        let datum = pg_sys::ItemPointerGetDatum(tid);
        pg_output_text(pg_sys::tidout, datum)
    }
}

unsafe fn slot_xmin_text(slot: *mut pg_sys::TupleTableSlot) -> Result<String, String> {
    unsafe {
        let mut should_free = false;
        let tuple = pg_sys::ExecFetchSlotHeapTuple(slot, false, &raw mut should_free);
        if tuple.is_null() || (*tuple).t_data.is_null() {
            return Err("source slot has no heap tuple for xmin".to_owned());
        }
        let xmin = (*(*tuple).t_data).t_choice.t_heap.t_xmin;
        let text = pg_output_text(pg_sys::xidout, pg_sys::TransactionIdGetDatum(xmin));
        if should_free {
            pg_sys::pfree(tuple.cast());
        }
        text
    }
}

unsafe fn pg_output_text(
    func: unsafe fn(pg_sys::FunctionCallInfo) -> pg_sys::Datum,
    datum: pg_sys::Datum,
) -> Result<String, String> {
    unsafe {
        let cstr = direct_function_call::<&CStr>(func, &[Some(datum)])
            .ok_or_else(|| "Postgres output function returned null".to_owned())?;
        let text = cstr.to_str().map_err(|err| err.to_string())?.to_owned();
        pg_sys::pfree(cstr.as_ptr().cast_mut().cast());
        Ok(text)
    }
}

fn semantic_subject_state(
    index_kind: SemanticIndexKind,
    index_name: &str,
    expected_json: &str,
    subject_id: &str,
) -> Result<SubjectSemanticState, String> {
    match index_kind {
        SemanticIndexKind::Row => semantic_row_subject_state(index_name, expected_json, subject_id),
        SemanticIndexKind::Join => {
            semantic_join_subject_state(index_name, expected_json, subject_id)
        }
    }
}

fn semantic_row_subject_state(
    index_name: &str,
    expected_json: &str,
    subject_id: &str,
) -> Result<SubjectSemanticState, String> {
    let matches_expected_sql = row_predicate_match_sql("sm.body", expected_json);
    let query = format!(
        "WITH latest AS ( \
           SELECT DISTINCT ON (sm.subject_id) \
             sm.subject_id, sm.stale, {} AS matches_expected, sm.updated_at, sm.id \
           FROM otlet.semantic_materializations sm \
           JOIN otlet.semantic_indexes si \
             ON si.task_name = sm.task_name \
            AND si.record_type = sm.record_type \
           WHERE si.name = {} \
             AND sm.subject_id = {} \
           ORDER BY sm.subject_id, sm.updated_at DESC, sm.id DESC \
         ), \
         active_jobs AS ( \
           SELECT DISTINCT j.subject_id \
           FROM otlet.jobs j \
           JOIN otlet.semantic_indexes si ON si.task_name = j.task_name \
           WHERE si.name = {} \
             AND j.subject_id = {} \
             AND j.status IN ('queued', 'running', 'cancel_requested') \
         ) \
         SELECT CASE \
           WHEN a.subject_id IS NOT NULL AND (l.subject_id IS NULL OR l.stale) THEN 'in_flight' \
           WHEN l.subject_id IS NULL THEN 'missing' \
           WHEN l.stale THEN 'stale' \
           WHEN l.matches_expected THEN 'fresh_match' \
           ELSE 'fresh_non_match' \
         END AS semantic_state \
         FROM (VALUES ({}::text)) ss(subject_id) \
         LEFT JOIN latest l USING (subject_id) \
         LEFT JOIN active_jobs a USING (subject_id)",
        matches_expected_sql,
        sql_literal(index_name),
        sql_literal(subject_id),
        sql_literal(index_name),
        sql_literal(subject_id),
        sql_literal(subject_id)
    );

    pgrx::Spi::connect(|client| {
        let table = client
            .select(query.as_str(), Some(1), &[])
            .map_err(to_string)?;
        let row = table.first();
        Ok(row
            .get_by_name::<String, _>("semantic_state")
            .map_err(to_string)?
            .and_then(|state| SubjectSemanticState::from_label(&state))
            .unwrap_or(SubjectSemanticState::Missing))
    })
}

fn semantic_join_subject_state(
    index_name: &str,
    expected_json: &str,
    subject_id: &str,
) -> Result<SubjectSemanticState, String> {
    let query = format!(
        "WITH metadata AS ( \
           SELECT task_name \
           FROM otlet.semantic_join_indexes \
           WHERE name = {} \
         ), \
         current_row AS ( \
           SELECT subject_id, body, stale \
           FROM otlet.semantic_join_index_current_rows({}, false) \
           WHERE subject_id = {} \
         ), \
         active_jobs AS ( \
           SELECT DISTINCT j.subject_id \
           FROM otlet.jobs j \
           JOIN metadata m ON m.task_name = j.task_name \
           WHERE j.subject_id = {} \
             AND j.status IN ('queued', 'running', 'cancel_requested') \
         ) \
         SELECT CASE \
           WHEN a.subject_id IS NOT NULL AND (c.subject_id IS NULL OR c.stale) THEN 'in_flight' \
           WHEN c.subject_id IS NULL THEN 'missing' \
           WHEN c.stale THEN 'stale' \
           WHEN c.body @> {}::jsonb THEN 'fresh_match' \
           ELSE 'fresh_non_match' \
         END AS semantic_state \
         FROM (VALUES ({}::text)) ss(subject_id) \
         LEFT JOIN current_row c USING (subject_id) \
         LEFT JOIN active_jobs a USING (subject_id)",
        sql_literal(index_name),
        sql_literal(index_name),
        sql_literal(subject_id),
        sql_literal(subject_id),
        sql_literal(expected_json),
        sql_literal(subject_id)
    );

    pgrx::Spi::connect(|client| {
        let table = client
            .select(query.as_str(), Some(1), &[])
            .map_err(to_string)?;
        let row = table.first();
        Ok(row
            .get_by_name::<String, _>("semantic_state")
            .map_err(to_string)?
            .and_then(|state| SubjectSemanticState::from_label(&state))
            .unwrap_or(SubjectSemanticState::Missing))
    })
}

fn active_subject_refreshes(task_name: &str, subject_id: &str) -> Result<i64, String> {
    let query = format!(
        "SELECT count(*)::bigint AS active \
         FROM otlet.jobs \
         WHERE task_name = {} \
           AND subject_id = {} \
           AND status IN ('queued', 'running', 'cancel_requested')",
        sql_literal(task_name),
        sql_literal(subject_id)
    );
    spi_i64(&query, "active")
}

fn materialize_semantic_subject(runtime: &RuntimeState, subject_id: &str) -> Result<i64, String> {
    let function_name = match runtime.index_kind {
        SemanticIndexKind::Row => "otlet.materialize_semantic_index_subject",
        SemanticIndexKind::Join => "otlet.materialize_semantic_join_index_subject",
    };
    let query = format!(
        "SELECT {}({}, {})::bigint AS materialized",
        function_name,
        sql_literal(&runtime.index_name),
        sql_literal(subject_id)
    );
    spi_i64(&query, "materialized")
}

fn spi_i64(query: &str, column: &str) -> Result<i64, String> {
    pgrx::Spi::connect(|client| {
        let table = client.select(query, Some(1), &[]).map_err(to_string)?;
        let row = table.first();
        Ok(row
            .get_by_name::<i64, _>(column)
            .map_err(to_string)?
            .unwrap_or(0))
    })
}
