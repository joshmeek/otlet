unsafe fn fdw_private_from_pushdown(pushdown: &SemanticPushdown) -> *mut pg_sys::List {
    unsafe {
        if !pushdown.has_filters() {
            return ptr::null_mut();
        }
        let subjects = match &pushdown.subjects {
            SubjectPushdown::None => Value::Null,
            SubjectPushdown::Subjects(subject_ids) => json!(subject_ids),
        };
        let payload = json!({ "subjects": subjects });
        let mut list = ptr::null_mut();
        list = append_string_node(list, FDW_PRIVATE_MARKER);
        append_string_node(list, &payload.to_string())
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
        let subjects = payload
            .get("subjects")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            });

        SemanticPushdown {
            subjects: subjects
                .map(SubjectPushdown::Subjects)
                .unwrap_or(SubjectPushdown::None),
        }
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
