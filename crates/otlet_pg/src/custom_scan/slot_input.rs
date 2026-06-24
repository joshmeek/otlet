fn refresh_runtime_subject_state(
    runtime: &mut RuntimeState,
    subject_id: &str,
) -> Result<SubjectSemanticState, String> {
    let state = with_latest_snapshot(|| {
        semantic_subject_state(
            runtime.index_kind,
            runtime.predicate_kind,
            &runtime.index_name,
            &runtime.expected_json,
            runtime.action_type.as_deref(),
            subject_id,
        )
    })?;
    runtime
        .semantic_states
        .insert(subject_id.to_string(), state);
    runtime.subject_state_refreshes = runtime.subject_state_refreshes.saturating_add(1);
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
    let row = unsafe { slot_row_json(slot, runtime.source_reltype)? };
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

unsafe fn semantic_join_slot_input(
    runtime: &RuntimeState,
    subject_id: &str,
    slot: *mut pg_sys::TupleTableSlot,
) -> Result<Option<Value>, String> {
    unsafe {
        let input = match slot_jsonb_attribute(slot, "input")? {
            Some(input) => Some(input),
            None => slot_semantic_join_jsonb_input(slot)?,
        };
        let Some(input) = input else {
            return Ok(None);
        };
        match input {
            Value::Object(mut object) => {
                object.entry("_otlet_mvcc".to_string()).or_insert_with(|| {
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

unsafe fn slot_semantic_join_jsonb_input(
    slot: *mut pg_sys::TupleTableSlot,
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
            if attr.is_null() || (*attr).attisdropped || (*attr).atttypid != pg_sys::JSONBOID {
                continue;
            }
            let mut isnull = false;
            let datum = pg_sys::slot_getattr(slot, (*attr).attnum as std::ffi::c_int, &mut isnull);
            if isnull {
                continue;
            }
            let Some(json) =
                <JsonB as FromDatum>::from_polymorphic_datum(datum, false, pg_sys::JSONBOID)
            else {
                continue;
            };
            if semantic_join_input_shape(&json.0) {
                return Ok(Some(json.0));
            }
        }
        Ok(None)
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
            let datum = pg_sys::slot_getattr(slot, (*attr).attnum as std::ffi::c_int, &mut isnull);
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
        let flinfo =
            pg_sys::palloc0(std::mem::size_of::<pg_sys::FmgrInfo>()).cast::<pg_sys::FmgrInfo>();
        pg_sys::fmgr_info(pg_sys::F_TO_JSONB.into(), flinfo);

        let func_expr =
            pg_sys::palloc0(std::mem::size_of::<pg_sys::FuncExpr>()).cast::<pg_sys::FuncExpr>();
        (*func_expr).xpr.type_ = pg_sys::NodeTag::T_FuncExpr;
        (*func_expr).funcid = pg_sys::F_TO_JSONB.into();
        (*func_expr).funcresulttype = pg_sys::JSONBOID;
        (*func_expr).funcretset = false;
        (*func_expr).funcvariadic = false;
        (*func_expr).funcformat = pg_sys::CoercionForm::COERCE_EXPLICIT_CALL;
        (*func_expr).funccollid = pg_sys::InvalidOid;
        (*func_expr).inputcollid = pg_sys::InvalidOid;
        (*func_expr).location = -1;

        let arg = pg_sys::palloc0(std::mem::size_of::<pg_sys::Const>()).cast::<pg_sys::Const>();
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
        (*flinfo).fn_expr = func_expr.cast();

        let fcinfo_size = std::mem::size_of::<pg_sys::FunctionCallInfoBaseData>()
            + std::mem::size_of::<pg_sys::NullableDatum>();
        let fcinfo = pg_sys::palloc0(fcinfo_size).cast::<pg_sys::FunctionCallInfoBaseData>();
        (*fcinfo).flinfo = flinfo;
        (*fcinfo).context = ptr::null_mut();
        (*fcinfo).resultinfo = ptr::null_mut();
        (*fcinfo).fncollation = pg_sys::InvalidOid;
        (*fcinfo).isnull = false;
        (*fcinfo).nargs = 1;
        let args_ptr: *mut pg_sys::NullableDatum = ptr::addr_of_mut!((*fcinfo).args).cast();
        (*args_ptr).value = datum;
        (*args_ptr).isnull = false;

        let result = pg_sys::to_jsonb(fcinfo);
        let is_null = (*fcinfo).isnull;
        pg_sys::pfree(fcinfo.cast());
        pg_sys::pfree(flinfo.cast());
        pg_sys::list_free_deep((*func_expr).args);
        pg_sys::pfree(func_expr.cast());

        if is_null {
            return Err("Postgres to_jsonb returned null for source slot row".to_string());
        }
        <JsonB as FromDatum>::from_polymorphic_datum(result, false, pg_sys::JSONBOID)
            .map(|json| json.0)
            .ok_or_else(|| "Postgres to_jsonb returned an unreadable jsonb datum".to_string())
    }
}

unsafe fn slot_tid_text(slot: *mut pg_sys::TupleTableSlot) -> Result<String, String> {
    unsafe {
        let tid = &raw const (*slot).tts_tid;
        if !pg_sys::ItemPointerIsValid(tid) {
            return Err("source slot has no valid ctid".to_string());
        }
        let datum = pg_sys::ItemPointerGetDatum(tid);
        pg_output_text(pg_sys::tidout, datum)
    }
}

unsafe fn slot_xmin_text(slot: *mut pg_sys::TupleTableSlot) -> Result<String, String> {
    unsafe {
        let mut should_free = false;
        let tuple = pg_sys::ExecFetchSlotHeapTuple(slot, false, &mut should_free);
        if tuple.is_null() || (*tuple).t_data.is_null() {
            return Err("source slot has no heap tuple for xmin".to_string());
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
            .ok_or_else(|| "Postgres output function returned null".to_string())?;
        let text = cstr.to_str().map_err(|err| err.to_string())?.to_string();
        pg_sys::pfree(cstr.as_ptr() as *mut std::ffi::c_void);
        Ok(text)
    }
}

fn semantic_subject_state(
    index_kind: SemanticIndexKind,
    predicate_kind: SemanticPredicateKind,
    index_name: &str,
    expected_json: &str,
    action_type: Option<&str>,
    subject_id: &str,
) -> Result<SubjectSemanticState, String> {
    match index_kind {
        SemanticIndexKind::Row => semantic_row_subject_state(
            predicate_kind,
            index_name,
            expected_json,
            action_type,
            subject_id,
        ),
        SemanticIndexKind::Join => {
            semantic_join_subject_state(index_name, expected_json, subject_id)
        }
    }
}

fn semantic_row_subject_state(
    predicate_kind: SemanticPredicateKind,
    index_name: &str,
    expected_json: &str,
    action_type: Option<&str>,
    subject_id: &str,
) -> Result<SubjectSemanticState, String> {
    let matches_expected_sql = row_predicate_match_sql(
        predicate_kind,
        "sm.body",
        "sm.record_id",
        "sm.subject_id",
        "si.task_name",
        expected_json,
        action_type,
    )?;
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
