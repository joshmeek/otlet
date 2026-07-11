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
    let Value::Object(mut object) = row else {
        return json!({});
    };
    // Move keys out of the source map when possible so infer-now projection
    // avoids cloning column name strings on every row.
    let mut projected = serde_json::Map::with_capacity(input_columns.len());
    for column in input_columns {
        if let Some((key, value)) = object.remove_entry(column) {
            projected.insert(key, value);
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
        let cached = if runtime.join_input_attno > 0 {
            slot_jsonb_attno(slot, runtime.join_input_attno)?
        } else {
            None
        };
        let input = match cached {
            Some(value) => Some(value),
            None => slot_jsonb_attribute(slot, "input")?
                .or_else(|| slot_semantic_join_jsonb_input(slot)),
        };
        let Some(input) = input else {
            return Ok(None);
        };
        match input {
            Value::Object(mut object) => {
                object.entry("_otlet_mvcc").or_insert_with(|| {
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

unsafe fn slot_jsonb_attno(
    slot: *mut pg_sys::TupleTableSlot,
    attno: i16,
) -> Result<Option<Value>, String> {
    unsafe {
        if slot.is_null() || attno <= 0 {
            return Ok(None);
        }
        let mut isnull = false;
        let datum = pg_sys::slot_getattr(slot, std::ffi::c_int::from(attno), &raw mut isnull);
        if isnull {
            return Ok(None);
        }
        <JsonB as FromDatum>::from_polymorphic_datum(datum, false, pg_sys::JSONBOID)
            .map(|json| Some(json.0))
            .ok_or_else(|| "projected semantic join input jsonb was not readable".to_owned())
    }
}

unsafe fn resolve_join_input_attno(
    child_plan: *mut pg_sys::PlanState,
    index_kind: SemanticIndexKind,
) -> i16 {
    unsafe {
        if index_kind != SemanticIndexKind::Join || child_plan.is_null() {
            return 0;
        }
        let tuple_desc = pg_sys::ExecGetResultType(child_plan);
        if tuple_desc.is_null() {
            return 0;
        }
        let natts = (*tuple_desc).natts;
        for idx in 0..natts {
            let attr = pg_sys::TupleDescAttr(tuple_desc, idx);
            if attr.is_null() || (*attr).attisdropped {
                continue;
            }
            let Ok(name) = CStr::from_ptr((*attr).attname.data.as_ptr()).to_str() else {
                continue;
            };
            if name == "input" && (*attr).atttypid == pg_sys::JSONBOID {
                return (*attr).attnum;
            }
        }
        0
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

#[derive(Clone, Copy)]
struct TypedToJsonbScratch {
    function_info: *mut pg_sys::FmgrInfo,
    func_expr: *mut pg_sys::FuncExpr,
    arg: *mut pg_sys::Const,
    call_info: *mut pg_sys::FunctionCallInfoBaseData,
}

unsafe fn typed_to_jsonb(datum: pg_sys::Datum, type_oid: pg_sys::Oid) -> Result<Value, String> {
    unsafe {
        // Backend-local TopMemoryContext scratch (thread_local, not Sync OnceLock).
        // CustomScan has no parallel worker init; only Const datum/type change per row.
        let scratch = typed_to_jsonb_scratch();
        (*scratch.arg).consttype = type_oid;
        (*scratch.arg).constvalue = datum;
        (*scratch.function_info).fn_expr = scratch.func_expr.cast();
        (*scratch.call_info).isnull = false;
        let args_ptr: *mut pg_sys::NullableDatum =
            ptr::addr_of_mut!((*scratch.call_info).args).cast();
        (*args_ptr).value = datum;
        (*args_ptr).isnull = false;

        let result = pg_sys::to_jsonb(scratch.call_info);
        let is_null = (*scratch.call_info).isnull;
        (*scratch.function_info).fn_expr = ptr::null_mut();

        if is_null {
            return Err("Postgres to_jsonb returned null for source slot row".to_owned());
        }
        <JsonB as FromDatum>::from_polymorphic_datum(result, false, pg_sys::JSONBOID)
            .map(|json| json.0)
            .ok_or_else(|| "Postgres to_jsonb returned an unreadable jsonb datum".to_owned())
    }
}

unsafe fn typed_to_jsonb_scratch() -> TypedToJsonbScratch {
    thread_local! {
        static SCRATCH: std::cell::Cell<Option<TypedToJsonbScratch>> =
            const { std::cell::Cell::new(None) };
    }
    if let Some(scratch) = SCRATCH.get() {
        return scratch;
    }
    unsafe {
        let old_context = pg_sys::MemoryContextSwitchTo(pg_sys::TopMemoryContext);
        let function_info = pg_sys::palloc0(size_of::<pg_sys::FmgrInfo>())
            .cast::<pg_sys::FmgrInfo>();
        pg_sys::fmgr_info(pg_sys::F_TO_JSONB.into(), function_info);
        let func_expr = pg_sys::palloc0(size_of::<pg_sys::FuncExpr>()).cast::<pg_sys::FuncExpr>();
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
        (*arg).consttypmod = -1;
        (*arg).constcollid = pg_sys::InvalidOid;
        (*arg).constlen = -1;
        (*arg).constisnull = false;
        (*arg).constbyval = false;
        (*arg).location = -1;
        (*func_expr).args = list_make1(arg.cast());

        let call_info_size =
            size_of::<pg_sys::FunctionCallInfoBaseData>() + size_of::<pg_sys::NullableDatum>();
        let call_info =
            pg_sys::palloc0(call_info_size).cast::<pg_sys::FunctionCallInfoBaseData>();
        (*call_info).flinfo = function_info;
        (*call_info).context = ptr::null_mut();
        (*call_info).resultinfo = ptr::null_mut();
        (*call_info).fncollation = pg_sys::InvalidOid;
        (*call_info).nargs = 1;
        pg_sys::MemoryContextSwitchTo(old_context);

        let scratch = TypedToJsonbScratch {
            function_info,
            func_expr,
            arg,
            call_info,
        };
        SCRATCH.set(Some(scratch));
        scratch
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

// Wait-path: skip materialize while a job is still active; otherwise materialize
// then re-read state in one statement (pure SELECT).
// $1=index_name, $2=subject_id, $3=expected_json, $4=task_name, $5=record_type
const SEMANTIC_ROW_WAIT_MATERIALIZE_STATE_SQL: &str = "WITH active AS ( \
                   SELECT EXISTS ( \
                     SELECT 1 FROM otlet.jobs j \
                     WHERE j.task_name = $4 \
                       AND j.subject_id = $2 \
                       AND j.status IN ('queued', 'running', 'cancel_requested') \
                     LIMIT 1 \
                   ) AS is_active \
                 ), \
                 materialized AS ( \
                   SELECT CASE \
                     WHEN a.is_active THEN 0::bigint \
                     ELSE otlet.materialize_semantic_index_subject($1, $2)::bigint \
                   END AS n \
                   FROM active a \
                 ), \
                 latest AS ( \
                   SELECT sm.subject_id, sm.stale, (sm.body @> $3::jsonb) AS matches_expected \
                   FROM active \
                   LEFT JOIN LATERAL ( \
                     SELECT sm.subject_id, sm.stale, sm.body \
                     FROM otlet.semantic_materializations sm \
                     WHERE NOT active.is_active \
                       AND sm.task_name = $4 \
                       AND sm.record_type = $5 \
                       AND sm.subject_id = $2 \
                     ORDER BY sm.updated_at DESC, sm.id DESC \
                     LIMIT 1 \
                   ) sm ON true \
                 ) \
                 SELECT \
                   active.is_active AS is_active, \
                   CASE \
                     WHEN active.is_active THEN 'in_flight' \
                     WHEN l.subject_id IS NULL THEN 'missing' \
                     WHEN l.stale THEN 'stale' \
                     WHEN l.matches_expected THEN 'fresh_match' \
                     ELSE 'fresh_non_match' \
                   END AS semantic_state \
                 FROM materialized, active \
                 LEFT JOIN latest l ON true";

// $1=index_name, $2=subject_id, $3=expected_json, $4=task_name
const SEMANTIC_JOIN_WAIT_MATERIALIZE_STATE_SQL: &str = "WITH active AS ( \
                   SELECT EXISTS ( \
                     SELECT 1 FROM otlet.jobs j \
                     WHERE j.task_name = $4 \
                       AND j.subject_id = $2 \
                       AND j.status IN ('queued', 'running', 'cancel_requested') \
                     LIMIT 1 \
                   ) AS is_active \
                 ), \
                 materialized AS ( \
                   SELECT CASE \
                     WHEN a.is_active THEN 0::bigint \
                     ELSE otlet.materialize_semantic_join_index_subject($1, $2)::bigint \
                   END AS n \
                   FROM active a \
                 ), \
                 latest AS ( \
                   SELECT sm.subject_id, sm.stale, (sm.body @> $3::jsonb) AS matches_expected \
                   FROM active \
                   LEFT JOIN LATERAL ( \
                     SELECT sm.subject_id, sm.stale, sm.body \
                     FROM otlet.semantic_materializations sm \
                     JOIN otlet.semantic_join_indexes sji \
                       ON sji.task_name = sm.task_name \
                      AND sji.record_type = sm.record_type \
                     WHERE NOT active.is_active \
                       AND sji.name = $1 \
                       AND sm.subject_id = $2 \
                     ORDER BY sm.updated_at DESC, sm.id DESC \
                     LIMIT 1 \
                   ) sm ON true \
                 ) \
                 SELECT \
                   active.is_active AS is_active, \
                   CASE \
                     WHEN active.is_active THEN 'in_flight' \
                     WHEN l.subject_id IS NULL THEN 'missing' \
                     WHEN l.stale THEN 'stale' \
                     WHEN l.matches_expected THEN 'fresh_match' \
                     ELSE 'fresh_non_match' \
                   END AS semantic_state \
                 FROM materialized, active \
                 LEFT JOIN latest l ON true";

fn wait_poll_state_from_spi_table(
    table: pgrx::spi::SpiTupleTable<'_>,
) -> Result<(bool, SubjectSemanticState), String> {
    let row = table.first();
    let is_active = row
        .get_by_name::<bool, _>("is_active")
        .map_err(to_string)?
        .unwrap_or(false);
    let label = row
        .get_by_name::<String, _>("semantic_state")
        .map_err(to_string)?
        .ok_or_else(|| "otlet semantic_state SPI returned null".to_owned())?;
    let state = SubjectSemanticState::from_label(&label).ok_or_else(|| {
        format!("otlet unexpected semantic_state from SPI: {label}")
    })?;
    Ok((is_active, state))
}
