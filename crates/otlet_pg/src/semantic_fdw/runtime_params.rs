unsafe fn resolve_runtime_pushdown(
    node: *mut pg_sys::ForeignScanState,
    mut pushdown: SemanticPushdown,
    fdw_expr_states: *mut pg_sys::List,
    outer_expr_typid: pg_sys::Oid,
) -> SemanticPushdown {
    unsafe {
        if pushdown.subject_outer.is_none()
            && pushdown.subject_param_filters.is_empty()
            && pushdown.body_contains_params.is_empty()
            && pushdown.body_field_equals_params.is_empty()
            && pushdown.stale_param.is_none()
            && pushdown.source_hash_param.is_none()
        {
            return pushdown;
        }

        let mut current_subjects = pushdown.subjects().map(|subjects| subjects.to_vec());
        if let Some(outer_ref) = pushdown.subject_outer {
            match runtime_outer_subject_value(node, outer_ref, fdw_expr_states, outer_expr_typid) {
                RuntimeParam::Value(value) => {
                    current_subjects = Some(match current_subjects.take() {
                        Some(existing) => intersect_subject_ids(&existing, &[value]),
                        None => vec![value],
                    });
                    pushdown.subject_outer = None;
                }
                RuntimeParam::Null => {
                    mark_empty_result(&mut pushdown, "outer source subject is null");
                    pushdown.subject_outer = None;
                }
                RuntimeParam::Unresolved => {}
            }
        }
        let mut unresolved = Vec::new();
        for filter in &pushdown.subject_param_filters {
            match runtime_subject_values(node, filter) {
                Some(subject_ids) => {
                    let subject_ids = unique_subject_ids(&subject_ids);
                    current_subjects = Some(match current_subjects.take() {
                        Some(existing) => intersect_subject_ids(&existing, &subject_ids),
                        None => subject_ids,
                    });
                }
                None => unresolved.push(filter.clone()),
            }
        }

        if let Some(subjects) = current_subjects {
            pushdown.subjects = SubjectPushdown::Subjects(subjects);
        }
        pushdown.subject_param_filters = unresolved;

        let mut unresolved_body_contains = Vec::new();
        let body_contains_params = std::mem::take(&mut pushdown.body_contains_params);
        for param_id in body_contains_params {
            match runtime_jsonb_param_text(node, param_id) {
                RuntimeParam::Value(filter) => pushdown.body_contains.push(filter),
                RuntimeParam::Null => {
                    mark_empty_result(&mut pushdown, "external body containment param is null");
                }
                RuntimeParam::Unresolved => unresolved_body_contains.push(param_id),
            }
        }
        pushdown.body_contains_params = unresolved_body_contains;

        let mut unresolved_body_field_equals = Vec::new();
        let body_field_equals_params = std::mem::take(&mut pushdown.body_field_equals_params);
        for (field, param_id) in body_field_equals_params {
            match runtime_text_param(node, param_id) {
                RuntimeParam::Value(value) => pushdown.body_field_equals.push((field, value)),
                RuntimeParam::Null => {
                    mark_empty_result(&mut pushdown, "external body field param is null");
                }
                RuntimeParam::Unresolved => unresolved_body_field_equals.push((field, param_id)),
            }
        }
        pushdown.body_field_equals_params = unresolved_body_field_equals;

        if let Some(param_id) = pushdown.stale_param {
            match runtime_bool_param(node, param_id) {
                RuntimeParam::Value(value) => {
                    pushdown.stale = Some(match pushdown.stale {
                        Some(existing) if existing != value => true,
                        _ => value,
                    });
                    pushdown.stale_param = None;
                }
                RuntimeParam::Null => {
                    mark_empty_result(&mut pushdown, "external stale param is null");
                    pushdown.stale_param = None;
                }
                RuntimeParam::Unresolved => {}
            }
        }

        if let Some(param_id) = pushdown.source_hash_param {
            match runtime_text_param(node, param_id) {
                RuntimeParam::Value(value) => {
                    pushdown.source_hash = Some(value);
                    pushdown.source_hash_param = None;
                }
                RuntimeParam::Null => {
                    mark_empty_result(&mut pushdown, "external source_hash param is null");
                    pushdown.source_hash_param = None;
                }
                RuntimeParam::Unresolved => {}
            }
        }
        pushdown
    }
}

fn mark_empty_result(pushdown: &mut SemanticPushdown, reason: &str) {
    if pushdown.empty_result_reason.is_none() {
        pushdown.empty_result_reason = Some(reason.to_string());
    }
    pushdown.subjects = SubjectPushdown::Subjects(Vec::new());
}

unsafe fn runtime_subject_values(
    node: *mut pg_sys::ForeignScanState,
    filter: &SubjectParamFilter,
) -> Option<Vec<String>> {
    unsafe {
        match filter {
            SubjectParamFilter::TextEq(param_ref) => match runtime_text_param(node, *param_ref) {
                RuntimeParam::Value(value) => Some(vec![value]),
                RuntimeParam::Null => Some(Vec::new()),
                RuntimeParam::Unresolved => None,
            },
            SubjectParamFilter::TextEqOutput(param_ref, typid) => {
                let param = runtime_datum_param(node, *param_ref, *typid)?;
                if param.isnull {
                    return Some(Vec::new());
                }
                datum_to_text(param.value, *typid).map(|value| vec![value])
            }
            SubjectParamFilter::TextArrayAny(param_ref) => {
                let Some(param) = runtime_datum_param(node, *param_ref, pg_sys::TEXTARRAYOID)
                else {
                    return None;
                };
                if param.isnull {
                    return Some(Vec::new());
                }
                let array = <Array<'_, String> as FromDatum>::from_polymorphic_datum(
                    param.value,
                    false,
                    pg_sys::TEXTARRAYOID,
                )?;
                let mut values = Vec::new();
                for value in array {
                    if let Some(value) = value {
                        values.push(value);
                    }
                }
                Some(values)
            }
        }
    }
}

unsafe fn runtime_outer_subject_value(
    node: *mut pg_sys::ForeignScanState,
    outer_ref: OuterVarRef,
    fdw_expr_states: *mut pg_sys::List,
    outer_expr_typid: pg_sys::Oid,
) -> RuntimeParam<String> {
    unsafe {
        match runtime_fdw_expr_subject_value(node, fdw_expr_states, outer_expr_typid) {
            RuntimeParam::Unresolved => {}
            value => return value,
        }
        if node.is_null() || outer_ref.attno <= 0 {
            return RuntimeParam::Unresolved;
        }
        let econtext = (*node).ss.ps.ps_ExprContext;
        if econtext.is_null() || (*econtext).ecxt_outertuple.is_null() {
            return RuntimeParam::Unresolved;
        }

        let mut isnull = false;
        let value = pg_sys::slot_getattr(
            (*econtext).ecxt_outertuple,
            outer_ref.attno as std::ffi::c_int,
            &mut isnull,
        );
        if isnull {
            return RuntimeParam::Null;
        }
        datum_to_text(value, outer_ref.typid)
            .map(RuntimeParam::Value)
            .unwrap_or(RuntimeParam::Unresolved)
    }
}

unsafe fn runtime_fdw_expr_subject_value(
    node: *mut pg_sys::ForeignScanState,
    fdw_expr_states: *mut pg_sys::List,
    typid: pg_sys::Oid,
) -> RuntimeParam<String> {
    unsafe {
        if node.is_null() || fdw_expr_states.is_null() || pg_sys::list_length(fdw_expr_states) < 1 {
            return RuntimeParam::Unresolved;
        }
        let econtext = (*node).ss.ps.ps_ExprContext;
        if econtext.is_null() {
            return RuntimeParam::Unresolved;
        }
        let expr_state = pg_sys::list_nth(fdw_expr_states, 0) as *mut pg_sys::ExprState;
        if expr_state.is_null() {
            return RuntimeParam::Unresolved;
        }
        let mut isnull = false;
        let value = pg_sys::ExecEvalExpr(expr_state, econtext, &mut isnull);
        if isnull {
            return RuntimeParam::Null;
        }
        let typid = if typid == pg_sys::InvalidOid {
            pg_sys::TEXTOID
        } else {
            typid
        };
        datum_to_text(value, typid)
            .map(RuntimeParam::Value)
            .unwrap_or(RuntimeParam::Unresolved)
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

unsafe fn runtime_text_param(
    node: *mut pg_sys::ForeignScanState,
    param_ref: RuntimeParamRef,
) -> RuntimeParam<String> {
    unsafe {
        let Some(param) = runtime_datum_param(node, param_ref, pg_sys::TEXTOID) else {
            return RuntimeParam::Unresolved;
        };
        if param.isnull {
            return RuntimeParam::Null;
        }
        <String as FromDatum>::from_polymorphic_datum(param.value, false, pg_sys::TEXTOID)
            .map(RuntimeParam::Value)
            .unwrap_or(RuntimeParam::Unresolved)
    }
}

unsafe fn runtime_bool_param(
    node: *mut pg_sys::ForeignScanState,
    param_ref: RuntimeParamRef,
) -> RuntimeParam<bool> {
    unsafe {
        let Some(param) = runtime_datum_param(node, param_ref, pg_sys::BOOLOID) else {
            return RuntimeParam::Unresolved;
        };
        if param.isnull {
            return RuntimeParam::Null;
        }
        <bool as FromDatum>::from_polymorphic_datum(param.value, false, pg_sys::BOOLOID)
            .map(RuntimeParam::Value)
            .unwrap_or(RuntimeParam::Unresolved)
    }
}

unsafe fn runtime_jsonb_param_text(
    node: *mut pg_sys::ForeignScanState,
    param_ref: RuntimeParamRef,
) -> RuntimeParam<String> {
    unsafe {
        let Some(param) = runtime_datum_param(node, param_ref, pg_sys::JSONBOID) else {
            return RuntimeParam::Unresolved;
        };
        if param.isnull {
            return RuntimeParam::Null;
        }
        let Some(jsonb) =
            <JsonB as FromDatum>::from_polymorphic_datum(param.value, false, pg_sys::JSONBOID)
        else {
            return RuntimeParam::Unresolved;
        };
        serde_json::to_string(&jsonb.0)
            .map(RuntimeParam::Value)
            .unwrap_or(RuntimeParam::Unresolved)
    }
}

struct RuntimeDatumParam {
    value: pg_sys::Datum,
    isnull: bool,
}

unsafe fn runtime_datum_param(
    node: *mut pg_sys::ForeignScanState,
    param_ref: RuntimeParamRef,
    expected_type: pg_sys::Oid,
) -> Option<RuntimeDatumParam> {
    unsafe {
        match param_ref {
            RuntimeParamRef::Extern(param_id) => {
                let param = external_param(node, param_id)?;
                if param.ptype != expected_type {
                    return None;
                }
                Some(RuntimeDatumParam {
                    value: param.value,
                    isnull: param.isnull,
                })
            }
            RuntimeParamRef::Exec(param_id) => {
                let param = exec_param(node, param_id)?;
                Some(RuntimeDatumParam {
                    value: param.value,
                    isnull: param.isnull,
                })
            }
        }
    }
}

unsafe fn external_param(
    node: *mut pg_sys::ForeignScanState,
    param_id: i32,
) -> Option<pg_sys::ParamExternData> {
    unsafe {
        if node.is_null() || param_id <= 0 {
            return None;
        }
        let estate = (*node).ss.ps.state;
        if estate.is_null() {
            return None;
        }
        let params = (*estate).es_param_list_info;
        if params.is_null() || param_id > (*params).numParams {
            return None;
        }
        if let Some(fetch) = (*params).paramFetch {
            let mut workspace = pg_sys::ParamExternData::default();
            let fetched = fetch(params, param_id, false, &mut workspace);
            if fetched.is_null() {
                None
            } else {
                Some(*fetched)
            }
        } else {
            Some(*(*params).params.as_ptr().add((param_id - 1) as usize))
        }
    }
}

unsafe fn exec_param(
    node: *mut pg_sys::ForeignScanState,
    param_id: i32,
) -> Option<pg_sys::ParamExecData> {
    unsafe {
        if node.is_null() || param_id < 0 {
            return None;
        }
        let estate = (*node).ss.ps.state;
        if estate.is_null() || (*estate).es_param_exec_vals.is_null() {
            return None;
        }
        let param = *(*estate).es_param_exec_vals.add(param_id as usize);
        if !param.execPlan.is_null() {
            pgrx::warning!(
                "otlet semantic FDW could not resolve {} before scan start",
                param_ref_log_label(RuntimeParamRef::Exec(param_id))
            );
            return None;
        }
        Some(param)
    }
}
