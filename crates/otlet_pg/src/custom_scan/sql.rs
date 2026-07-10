const fn nonempty_str(value: &str) -> Option<&str> {
    if value.is_empty() { None } else { Some(value) }
}

unsafe fn pg_cstr_str<'pg>(value: *const c_char) -> Option<&'pg str> {
    if value.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(value).to_str().ok().and_then(nonempty_str) }
}

fn cstr(value: &str) -> CString {
    CString::new(value).unwrap_or_default()
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

fn source_rows_sql(
    source_table: &str,
    subject_column: &str,
    input_columns_sql: &str,
    input_shaping_sql: &str,
) -> String {
    let subject_identifier = sql_identifier(subject_column);
    let source_table_literal = sql_literal(source_table);
    // Build the MVCC+row envelope once; both hashes read the same object.
    format!(
        "SELECT projected.subject_id, \
                md5(projected.input_obj::text) AS source_hash, \
                otlet.semantic_content_hash(projected.input_obj, {input_shaping_sql}::jsonb) AS content_hash \
         FROM ( \
           SELECT (src.{subject_identifier})::text AS subject_id, \
                  jsonb_build_object( \
                    '_otlet_mvcc', jsonb_build_object( \
                      'table', {source_table_literal}, \
                      'subject_id', (src.{subject_identifier})::text, \
                      'ctid', src.ctid::text, \
                      'xmin', src.xmin::text \
                    ), \
                    'table', {source_table_literal}, \
                    'row', otlet.semantic_project_row(to_jsonb(src), {input_columns_sql}::text[]) \
                  ) AS input_obj \
           FROM {source_table} AS src \
         ) projected"
    )
}

fn to_string<E: std::fmt::Display>(err: E) -> String {
    err.to_string()
}
