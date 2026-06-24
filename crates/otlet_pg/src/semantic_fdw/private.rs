unsafe fn fdw_private_from_pushdown(pushdown: &SemanticPushdown) -> *mut pg_sys::List {
    unsafe {
        if !pushdown.has_filters() {
            return ptr::null_mut();
        }

        let subjects = match &pushdown.subjects {
            SubjectPushdown::None => Value::Null,
            SubjectPushdown::Subjects(subject_ids) => json!(subject_ids),
        };
        let body_field_equals: Vec<String> = pushdown
            .body_field_equals
            .iter()
            .filter_map(|(field, value)| encode_body_field_equals(field, value))
            .collect();
        let body_field_equals_params: Vec<String> = pushdown
            .body_field_equals_params
            .iter()
            .filter_map(|(field, param_ref)| encode_body_field_equals_param(field, *param_ref))
            .collect();
        let payload = json!({
            "subjects": subjects,
            "subject_outer": pushdown.subject_outer.map(encode_outer_var_ref),
            "subject_param_filters": pushdown.subject_param_filters.iter().map(encode_subject_param_filter).collect::<Vec<_>>(),
            "body_contains": &pushdown.body_contains,
            "body_contains_params": pushdown.body_contains_params.iter().map(|param_ref| encode_param_ref(*param_ref)).collect::<Vec<_>>(),
            "body_field_equals": body_field_equals,
            "body_field_equals_params": body_field_equals_params,
            "stale": pushdown.stale,
            "stale_param": pushdown.stale_param.map(encode_param_ref),
            "source_hash": &pushdown.source_hash,
            "source_hash_param": pushdown.source_hash_param.map(encode_param_ref)
        });
        let mut list = ptr::null_mut();
        list = append_string_node(list, FDW_PRIVATE_MARKER);
        append_string_node(list, &payload.to_string())
    }
}

unsafe fn append_string_node(list: *mut pg_sys::List, value: &str) -> *mut pg_sys::List {
    unsafe {
        let node = string_node(value);
        if node.is_null() {
            return list;
        }
        if list.is_null() {
            pg_sys::list_make1_impl(
                pg_sys::NodeTag::T_List,
                pg_sys::ListCell {
                    ptr_value: node as *mut std::ffi::c_void,
                },
            )
        } else {
            pg_sys::lappend(list, node as *mut std::ffi::c_void)
        }
    }
}

unsafe fn outer_subject_fdw_exprs(
    scan_clauses: *mut pg_sys::List,
    foreign_varno: pg_sys::Index,
) -> *mut pg_sys::List {
    unsafe {
        if scan_clauses.is_null() {
            return ptr::null_mut();
        }
        for idx in 0..pg_sys::list_length(scan_clauses) {
            let rinfo = pg_sys::list_nth(scan_clauses, idx) as *mut pg_sys::RestrictInfo;
            if rinfo.is_null() {
                continue;
            }
            let expr = outer_subject_expr_from_clause((*rinfo).clause, foreign_varno);
            if !expr.is_null() {
                return append_expr_node(ptr::null_mut(), expr);
            }
        }
        ptr::null_mut()
    }
}

unsafe fn outer_subject_expr_from_clause(
    clause: *mut pg_sys::Expr,
    foreign_varno: pg_sys::Index,
) -> *mut pg_sys::Expr {
    unsafe {
        let clause = strip_relabel(clause);
        if clause.is_null() || (*clause).type_ != pg_sys::NodeTag::T_OpExpr {
            return ptr::null_mut();
        }
        let op = clause as *mut pg_sys::OpExpr;
        if !is_text_equality_operator((*op).opno) || pg_sys::list_length((*op).args) != 2 {
            return ptr::null_mut();
        }

        let left = pg_sys::list_nth((*op).args, 0) as *mut pg_sys::Expr;
        let right = pg_sys::list_nth((*op).args, 1) as *mut pg_sys::Expr;
        if is_subject_id_var(left, foreign_varno)
            && outer_subject_ref(right, foreign_varno).is_some()
        {
            right
        } else if is_subject_id_var(right, foreign_varno)
            && outer_subject_ref(left, foreign_varno).is_some()
        {
            left
        } else {
            ptr::null_mut()
        }
    }
}

unsafe fn append_expr_node(list: *mut pg_sys::List, expr: *mut pg_sys::Expr) -> *mut pg_sys::List {
    unsafe {
        let expr = pg_sys::copyObjectImpl(expr.cast()).cast::<std::ffi::c_void>();
        if expr.is_null() {
            return list;
        }
        if list.is_null() {
            pg_sys::list_make1_impl(
                pg_sys::NodeTag::T_List,
                pg_sys::ListCell { ptr_value: expr },
            )
        } else {
            pg_sys::lappend(list, expr)
        }
    }
}

unsafe fn init_fdw_expr_states(node: *mut pg_sys::ForeignScanState) -> *mut pg_sys::List {
    unsafe {
        if node.is_null() || (*node).ss.ps.plan.is_null() {
            return ptr::null_mut();
        }
        let scan = (*node).ss.ps.plan as *mut pg_sys::ForeignScan;
        if (*scan).fdw_exprs.is_null() {
            return ptr::null_mut();
        }
        pg_sys::ExecInitExprList((*scan).fdw_exprs, &mut (*node).ss.ps)
    }
}

unsafe fn first_fdw_expr_typid(node: *mut pg_sys::ForeignScanState) -> pg_sys::Oid {
    unsafe {
        if node.is_null() || (*node).ss.ps.plan.is_null() {
            return pg_sys::InvalidOid;
        }
        let scan = (*node).ss.ps.plan as *mut pg_sys::ForeignScan;
        if (*scan).fdw_exprs.is_null() || pg_sys::list_length((*scan).fdw_exprs) < 1 {
            return pg_sys::InvalidOid;
        }
        pg_sys::exprType(pg_sys::list_nth((*scan).fdw_exprs, 0).cast())
    }
}

unsafe fn string_node(value: &str) -> *mut pg_sys::String {
    unsafe {
        CString::new(value)
            .map(|value| pg_sys::makeString(pg_sys::pstrdup(value.as_ptr())))
            .unwrap_or(ptr::null_mut())
    }
}

fn encode_body_field_equals(field: &str, value: &str) -> Option<String> {
    let mut object = serde_json::Map::new();
    object.insert("field".to_string(), Value::String(field.to_string()));
    object.insert("value".to_string(), Value::String(value.to_string()));
    serde_json::to_string(&Value::Object(object)).ok()
}

fn decode_body_field_equals(filter: &str) -> Option<(String, String)> {
    let value = serde_json::from_str::<Value>(filter).ok()?;
    let object = value.as_object()?;
    let field = object.get("field")?.as_str()?.to_string();
    let value = object.get("value")?.as_str()?.to_string();
    Some((field, value))
}

fn encode_body_field_equals_param(field: &str, param_ref: RuntimeParamRef) -> Option<String> {
    let mut object = serde_json::Map::new();
    object.insert("field".to_string(), Value::String(field.to_string()));
    object.insert(
        "param".to_string(),
        Value::String(encode_param_ref(param_ref)),
    );
    serde_json::to_string(&Value::Object(object)).ok()
}

fn decode_body_field_equals_param(filter: &str) -> Option<(String, RuntimeParamRef)> {
    let value = serde_json::from_str::<Value>(filter).ok()?;
    let object = value.as_object()?;
    let field = object.get("field")?.as_str()?.to_string();
    let param_ref = object
        .get("param")
        .and_then(|value| value.as_str())
        .and_then(decode_param_ref)
        .or_else(|| {
            object
                .get("param_id")
                .and_then(|value| value.as_i64())
                .and_then(|param_id| i32::try_from(param_id).ok())
                .map(RuntimeParamRef::Extern)
        })?;
    Some((field, param_ref))
}

fn encode_subject_param_filter(filter: &SubjectParamFilter) -> String {
    match filter {
        SubjectParamFilter::TextEq(param_ref) => {
            format!("text_eq:{}", encode_param_ref(*param_ref))
        }
        SubjectParamFilter::TextEqOutput(param_ref, typid) => {
            format!("text_eq_output:{}:{}", encode_param_ref(*param_ref), typid)
        }
        SubjectParamFilter::TextArrayAny(param_ref) => {
            format!("text_array_any:{}", encode_param_ref(*param_ref))
        }
    }
}

fn decode_subject_param_filter(filter: &str) -> Option<SubjectParamFilter> {
    let (kind, encoded) = filter.split_once(':')?;
    match kind {
        "text_eq" => Some(SubjectParamFilter::TextEq(decode_param_ref(encoded)?)),
        "text_eq_output" => {
            let (encoded_param, encoded_typid) = encoded.rsplit_once(':')?;
            Some(SubjectParamFilter::TextEqOutput(
                decode_param_ref(encoded_param)?,
                pg_sys::Oid::from(encoded_typid.parse::<u32>().ok()?),
            ))
        }
        "text_array_any" => Some(SubjectParamFilter::TextArrayAny(decode_param_ref(encoded)?)),
        _ => None,
    }
}

fn encode_outer_var_ref(outer_ref: OuterVarRef) -> String {
    format!("{}:{}", outer_ref.attno, outer_ref.typid)
}

fn decode_outer_var_ref(encoded: &str) -> Option<OuterVarRef> {
    let (attno, typid) = encoded.split_once(':')?;
    Some(OuterVarRef {
        attno: attno.parse::<i16>().ok()?,
        typid: pg_sys::Oid::from(typid.parse::<u32>().ok()?),
    })
}

fn outer_var_ref_label(outer_ref: OuterVarRef) -> String {
    format!("outer att{}::{}", outer_ref.attno, outer_ref.typid)
}

fn subject_param_filter_label(filter: &SubjectParamFilter) -> String {
    match filter {
        SubjectParamFilter::TextEq(param_ref) => {
            format!("subject_id = {}", param_ref_label(*param_ref))
        }
        SubjectParamFilter::TextEqOutput(param_ref, typid) => {
            format!(
                "subject_id = output({}::{typid})",
                param_ref_label(*param_ref)
            )
        }
        SubjectParamFilter::TextArrayAny(param_ref) => {
            format!("subject_id = ANY({})", param_ref_label(*param_ref))
        }
    }
}

fn param_ref_log_label(param_ref: RuntimeParamRef) -> String {
    match param_ref {
        RuntimeParamRef::Extern(param_id) => format!("external ${param_id}"),
        RuntimeParamRef::Exec(param_id) => format!("executor param {param_id}"),
    }
}

fn encode_param_ref(param_ref: RuntimeParamRef) -> String {
    match param_ref {
        RuntimeParamRef::Extern(param_id) => format!("extern:{param_id}"),
        RuntimeParamRef::Exec(param_id) => format!("exec:{param_id}"),
    }
}

fn decode_param_ref(encoded: &str) -> Option<RuntimeParamRef> {
    if let Some((kind, value)) = encoded.split_once(':') {
        let param_id = value.parse::<i32>().ok()?;
        match kind {
            "extern" => Some(RuntimeParamRef::Extern(param_id)),
            "exec" => Some(RuntimeParamRef::Exec(param_id)),
            _ => None,
        }
    } else {
        encoded.parse::<i32>().ok().map(RuntimeParamRef::Extern)
    }
}

fn param_ref_label(param_ref: RuntimeParamRef) -> String {
    match param_ref {
        RuntimeParamRef::Extern(param_id) => format!("${param_id}"),
        RuntimeParamRef::Exec(param_id) => format!("EXEC[{param_id}]"),
    }
}

unsafe fn semantic_pushdown_from_fdw_private(
    node: *mut pg_sys::ForeignScanState,
) -> SemanticPushdown {
    unsafe {
        if node.is_null() || (*node).ss.ps.plan.is_null() {
            return SemanticPushdown::none();
        }
        let scan = (*node).ss.ps.plan as *mut pg_sys::ForeignScan;
        let private = (*scan).fdw_private;
        if private.is_null() || pg_sys::list_length(private) < 2 {
            return SemanticPushdown::none();
        }
        let Some(marker) = string_node_value(pg_sys::list_nth(private, 0) as *mut pg_sys::String)
        else {
            return SemanticPushdown::none();
        };
        if marker != FDW_PRIVATE_MARKER {
            return SemanticPushdown::none();
        }
        let Some(payload_text) =
            string_node_value(pg_sys::list_nth(private, 1) as *mut pg_sys::String)
        else {
            return SemanticPushdown::none();
        };
        let Ok(payload) = serde_json::from_str::<Value>(&payload_text) else {
            return SemanticPushdown::none();
        };

        let subject_ids = payload
            .get("subjects")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            })
            .filter(|values| !values.is_empty());
        let subject_outer = payload
            .get("subject_outer")
            .and_then(Value::as_str)
            .and_then(decode_outer_var_ref);
        let subject_param_filters = json_string_array(&payload, "subject_param_filters")
            .into_iter()
            .filter_map(|value| decode_subject_param_filter(&value))
            .collect();
        let body_contains = json_string_array(&payload, "body_contains");
        let body_contains_params = json_string_array(&payload, "body_contains_params")
            .into_iter()
            .filter_map(|value| decode_param_ref(&value))
            .collect();
        let body_field_equals = json_string_array(&payload, "body_field_equals")
            .into_iter()
            .filter_map(|value| decode_body_field_equals(&value))
            .collect();
        let body_field_equals_params = json_string_array(&payload, "body_field_equals_params")
            .into_iter()
            .filter_map(|value| decode_body_field_equals_param(&value))
            .collect();
        let stale = payload.get("stale").and_then(Value::as_bool);
        let stale_param = payload
            .get("stale_param")
            .and_then(Value::as_str)
            .and_then(decode_param_ref);
        let source_hash = payload
            .get("source_hash")
            .and_then(Value::as_str)
            .map(str::to_string);
        let source_hash_param = payload
            .get("source_hash_param")
            .and_then(Value::as_str)
            .and_then(decode_param_ref);

        SemanticPushdown {
            subjects: subject_ids
                .map(SubjectPushdown::Subjects)
                .unwrap_or(SubjectPushdown::None),
            subject_outer,
            subject_param_filters,
            body_contains,
            body_contains_params,
            body_field_equals,
            body_field_equals_params,
            stale,
            stale_param,
            source_hash,
            source_hash_param,
            empty_result_reason: None,
        }
    }
}

fn json_string_array(payload: &Value, key: &str) -> Vec<String> {
    payload
        .get(key)
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
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
