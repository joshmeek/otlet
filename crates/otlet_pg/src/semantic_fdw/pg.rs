unsafe fn strip_relabel(node: *mut pg_sys::Expr) -> *mut pg_sys::Expr {
    unsafe {
        if !node.is_null() && (*node).type_ == pg_sys::NodeTag::T_RelabelType {
            (*(node as *mut pg_sys::RelabelType)).arg
        } else {
            node
        }
    }
}

unsafe fn is_text_equality_operator(opno: pg_sys::Oid) -> bool {
    unsafe {
        let opname = pg_sys::get_opname(opno);
        if opname.is_null() || CStr::from_ptr(opname).to_bytes() != b"=" {
            return false;
        }
        let mut left = pg_sys::InvalidOid;
        let mut right = pg_sys::InvalidOid;
        pg_sys::op_input_types(opno, &mut left, &mut right);
        left == pg_sys::TEXTOID && right == pg_sys::TEXTOID
    }
}

fn scalar_i64(client: &mut pgrx::spi::SpiClient, query: &str) -> Result<i64, String> {
    let table = client.update(query, Some(1), &[]).map_err(to_string)?;
    Ok(table
        .first()
        .get_one::<i64>()
        .map_err(to_string)?
        .unwrap_or_default())
}

fn scalar_select_i64(client: &pgrx::spi::SpiClient, query: &str) -> Result<i64, String> {
    let table = client.select(query, Some(1), &[]).map_err(to_string)?;
    Ok(table
        .first()
        .get_one::<i64>()
        .map_err(to_string)?
        .unwrap_or_default())
}

fn sql_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn sql_identifier(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn sql_subject_filter(column: &str, subjects: &SubjectPushdown) -> String {
    match subjects.subjects() {
        None => String::new(),
        Some([]) => " AND false".to_string(),
        Some([subject_id]) => format!(" AND {column} = {}", sql_literal(subject_id)),
        Some(subject_ids) => format!(
            " AND {column} = ANY ({}::text[])",
            sql_text_array(subject_ids)
        ),
    }
}

fn sql_text_array(subject_ids: &[String]) -> String {
    format!(
        "ARRAY[{}]",
        subject_ids
            .iter()
            .map(|subject_id| sql_literal(subject_id))
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn unique_subject_ids(subject_ids: &[String]) -> Vec<String> {
    let mut unique = Vec::new();
    for subject_id in subject_ids {
        if !unique.contains(subject_id) {
            unique.push(subject_id.clone());
        }
    }
    unique
}

fn intersect_subject_ids(left: &[String], right: &[String]) -> Vec<String> {
    left.iter()
        .filter(|subject_id| right.contains(subject_id))
        .cloned()
        .collect()
}

fn cstr(value: &str) -> CString {
    CString::new(value).expect("static explain label contains no nul")
}

unsafe fn explain_text(label: &str, value: &str, es: *mut pg_sys::ExplainState) {
    unsafe {
        pg_sys::ExplainPropertyText(cstr(label).as_ptr(), cstr(value).as_ptr(), es);
    }
}

unsafe fn explain_integer(label: &str, value: i64, es: *mut pg_sys::ExplainState) {
    unsafe {
        pg_sys::ExplainPropertyInteger(cstr(label).as_ptr(), ptr::null(), value, es);
    }
}

unsafe fn explain_float(label: &str, value: f64, unit: &str, es: *mut pg_sys::ExplainState) {
    unsafe {
        pg_sys::ExplainPropertyFloat(cstr(label).as_ptr(), cstr(unit).as_ptr(), value, 2, es);
    }
}

fn to_string(err: impl std::fmt::Display) -> String {
    err.to_string()
}
