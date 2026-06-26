unsafe fn semantic_pushdown_from_restrictinfos(
    restrictinfos: *mut pg_sys::List,
    foreign_varno: pg_sys::Index,
) -> SemanticPushdown {
    unsafe {
        let mut subjects: Option<Vec<String>> = None;
        for idx in 0..pg_sys::list_length(restrictinfos) {
            let rinfo = pg_sys::list_nth(restrictinfos, idx) as *mut pg_sys::RestrictInfo;
            if rinfo.is_null() {
                continue;
            }
            if let Some(subject_id) = subject_const_filter((*rinfo).clause, foreign_varno) {
                subjects = Some(match subjects.take() {
                    Some(existing) => intersect_subject_ids(&existing, &[subject_id]),
                    None => vec![subject_id],
                });
            }
        }
        SemanticPushdown {
            subjects: subjects
                .map(SubjectPushdown::Subjects)
                .unwrap_or(SubjectPushdown::None),
        }
    }
}

unsafe fn subject_const_filter(
    clause: *mut pg_sys::Expr,
    foreign_varno: pg_sys::Index,
) -> Option<String> {
    unsafe {
        let clause = strip_relabel(clause);
        if clause.is_null() || (*clause).type_ != pg_sys::NodeTag::T_OpExpr {
            return None;
        }
        let op = clause as *mut pg_sys::OpExpr;
        if !is_text_equality_operator((*op).opno) || pg_sys::list_length((*op).args) != 2 {
            return None;
        }

        let left = pg_sys::list_nth((*op).args, 0) as *mut pg_sys::Expr;
        let right = pg_sys::list_nth((*op).args, 1) as *mut pg_sys::Expr;
        if is_subject_id_var(left, foreign_varno) {
            text_const_value(right)
        } else if is_subject_id_var(right, foreign_varno) {
            text_const_value(left)
        } else {
            None
        }
    }
}

unsafe fn is_subject_id_var(node: *mut pg_sys::Expr, foreign_varno: pg_sys::Index) -> bool {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Var {
            return false;
        }
        let var = node as *mut pg_sys::Var;
        varno_matches((*var).varno, foreign_varno)
            && (*var).varattno == 1
            && (*var).vartype == pg_sys::TEXTOID
    }
}

fn varno_matches(varno: i32, foreign_varno: pg_sys::Index) -> bool {
    varno >= 0 && u32::try_from(varno).ok() == Some(foreign_varno)
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
