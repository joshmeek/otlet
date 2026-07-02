fn nonempty_str(value: &str) -> Option<&str> {
    if value.is_empty() { None } else { Some(value) }
}

unsafe fn pg_cstr_str<'a>(value: *const c_char) -> Option<&'a str> {
    if value.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(value).to_str().ok().and_then(nonempty_str) }
}

fn cstr(value: &str) -> CString {
    CString::new(value).unwrap_or_else(|_| CString::new("").expect("empty CString is valid"))
}

fn pg_cstr(value: &str) -> *mut c_char {
    let cstring = cstr(value);
    unsafe { pg_sys::pstrdup(cstring.as_ptr()) }
}

fn sql_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn sql_identifier(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn source_rows_sql(source_table: &str, subject_column: &str) -> String {
    let subject_identifier = sql_identifier(subject_column);
    let source_table_literal = sql_literal(source_table);
    format!(
        "SELECT (src.{subject_identifier})::text AS subject_id, \
                md5(jsonb_build_object( \
                  '_otlet_mvcc', jsonb_build_object( \
                    'table', {source_table_literal}, \
                    'subject_id', (src.{subject_identifier})::text, \
                    'ctid', src.ctid::text, \
                    'xmin', src.xmin::text \
                  ), \
                  'table', {source_table_literal}, \
                  'row', to_jsonb(src) \
                )::text) AS source_hash, \
                otlet.semantic_content_hash(jsonb_build_object( \
                  '_otlet_mvcc', jsonb_build_object( \
                    'table', {source_table_literal}, \
                    'subject_id', (src.{subject_identifier})::text, \
                    'ctid', src.ctid::text, \
                    'xmin', src.xmin::text \
                  ), \
                  'table', {source_table_literal}, \
                  'row', to_jsonb(src) \
                )) AS content_hash \
         FROM {source_table} AS src"
    )
}

fn row_predicate_match_sql(
    body_expr: &str,
    expected_json: &str,
) -> String {
    format!("{body_expr} @> {}::jsonb", sql_literal(expected_json))
}

fn to_string<E: std::fmt::Display>(err: E) -> String {
    err.to_string()
}
