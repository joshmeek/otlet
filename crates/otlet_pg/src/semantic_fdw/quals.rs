unsafe fn semantic_pushdown_from_restrictinfos(
    restrictinfos: *mut pg_sys::List,
    foreign_varno: pg_sys::Index,
) -> SemanticPushdown {
    unsafe {
        if restrictinfos.is_null() {
            return SemanticPushdown::none();
        }
        let mut current_subjects: Option<Vec<String>> = None;
        let mut subject_outer = None;
        let mut subject_param_filters = Vec::new();
        let mut body_contains = Vec::new();
        let mut body_contains_params = Vec::new();
        let mut body_field_equals = Vec::new();
        let mut body_field_equals_params = Vec::new();
        let mut stale = None;
        let mut stale_param = None;
        let mut source_hash = None;
        let mut source_hash_param = None;
        for idx in 0..pg_sys::list_length(restrictinfos) {
            let rinfo = pg_sys::list_nth(restrictinfos, idx) as *mut pg_sys::RestrictInfo;
            if rinfo.is_null() {
                continue;
            }
            if let Some(filter) = subject_id_filter_from_clause((*rinfo).clause, foreign_varno) {
                match filter {
                    SubjectClauseFilter::Values(subject_ids) => {
                        let subject_ids = unique_subject_ids(&subject_ids);
                        current_subjects = Some(match current_subjects.take() {
                            Some(existing) => intersect_subject_ids(&existing, &subject_ids),
                            None => subject_ids,
                        });
                    }
                    SubjectClauseFilter::Param(filter) => subject_param_filters.push(filter),
                    SubjectClauseFilter::Outer(outer_ref) => subject_outer = Some(outer_ref),
                }
            }
            if let Some(filter) = body_filter_from_clause((*rinfo).clause, foreign_varno) {
                match filter {
                    BodyPushdownFilter::Contains(filter) => body_contains.push(filter),
                    BodyPushdownFilter::ContainsParam(param_id) => {
                        body_contains_params.push(param_id);
                    }
                    BodyPushdownFilter::FieldEquals(field, value) => {
                        body_field_equals.push((field, value));
                    }
                    BodyPushdownFilter::FieldEqualsParam(field, param_id) => {
                        body_field_equals_params.push((field, param_id));
                    }
                }
            }
            if let Some(filter) = stale_filter_from_clause((*rinfo).clause, foreign_varno) {
                match filter {
                    StaleFilter::Value(value) => {
                        stale = Some(match stale {
                            Some(existing) if existing != value => true,
                            _ => value,
                        });
                    }
                    StaleFilter::Param(param_id) => stale_param = Some(param_id),
                }
            }
            if let Some(filter) = source_hash_filter_from_clause((*rinfo).clause, foreign_varno) {
                match filter {
                    SourceHashFilter::Value(value) => source_hash = Some(value),
                    SourceHashFilter::Param(param_id) => source_hash_param = Some(param_id),
                }
            }
        }
        SemanticPushdown {
            subjects: current_subjects
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

unsafe fn subject_id_filter_from_clause(
    clause: *mut pg_sys::Expr,
    foreign_varno: pg_sys::Index,
) -> Option<SubjectClauseFilter> {
    unsafe {
        let clause = strip_relabel(clause);
        if clause.is_null() {
            return None;
        }
        match (*clause).type_ {
            pg_sys::NodeTag::T_OpExpr => {
                let op = clause as *mut pg_sys::OpExpr;
                if !is_text_equality_operator((*op).opno) || pg_sys::list_length((*op).args) != 2 {
                    return None;
                }

                let left = pg_sys::list_nth((*op).args, 0) as *mut pg_sys::Expr;
                let right = pg_sys::list_nth((*op).args, 1) as *mut pg_sys::Expr;
                if is_subject_id_var(left, foreign_varno) {
                    text_const_value(right)
                        .map(|value| SubjectClauseFilter::Values(vec![value]))
                        .or_else(|| {
                            text_param_ref(right).map(|param_ref| {
                                SubjectClauseFilter::Param(SubjectParamFilter::TextEq(param_ref))
                            })
                        })
                        .or_else(|| {
                            text_output_param_ref(right).map(|(param_ref, typid)| {
                                SubjectClauseFilter::Param(SubjectParamFilter::TextEqOutput(
                                    param_ref, typid,
                                ))
                            })
                        })
                        .or_else(|| {
                            outer_subject_ref(right, foreign_varno).map(SubjectClauseFilter::Outer)
                        })
                } else if is_subject_id_var(right, foreign_varno) {
                    text_const_value(left)
                        .map(|value| SubjectClauseFilter::Values(vec![value]))
                        .or_else(|| {
                            text_param_ref(left).map(|param_ref| {
                                SubjectClauseFilter::Param(SubjectParamFilter::TextEq(param_ref))
                            })
                        })
                        .or_else(|| {
                            text_output_param_ref(left).map(|(param_ref, typid)| {
                                SubjectClauseFilter::Param(SubjectParamFilter::TextEqOutput(
                                    param_ref, typid,
                                ))
                            })
                        })
                        .or_else(|| {
                            outer_subject_ref(left, foreign_varno).map(SubjectClauseFilter::Outer)
                        })
                } else {
                    None
                }
            }
            pg_sys::NodeTag::T_ScalarArrayOpExpr => {
                let op = clause as *mut pg_sys::ScalarArrayOpExpr;
                if !(*op).useOr
                    || !is_text_equality_operator((*op).opno)
                    || pg_sys::list_length((*op).args) != 2
                {
                    return None;
                }
                let left = pg_sys::list_nth((*op).args, 0) as *mut pg_sys::Expr;
                let right = pg_sys::list_nth((*op).args, 1) as *mut pg_sys::Expr;
                if is_subject_id_var(left, foreign_varno) {
                    text_array_values(right)
                        .map(SubjectClauseFilter::Values)
                        .or_else(|| {
                            text_array_param_ref(right).map(|param_ref| {
                                SubjectClauseFilter::Param(SubjectParamFilter::TextArrayAny(
                                    param_ref,
                                ))
                            })
                        })
                } else {
                    None
                }
            }
            _ => None,
        }
    }
}

unsafe fn subject_join_clauses(
    root: *mut pg_sys::PlannerInfo,
    baserel: *mut pg_sys::RelOptInfo,
    foreign_varno: pg_sys::Index,
) -> (*mut pg_sys::List, pg_sys::Relids) {
    unsafe {
        let mut clauses: *mut pg_sys::List = ptr::null_mut();
        let mut required_outer: pg_sys::Relids = ptr::null_mut();
        if baserel.is_null() {
            return (clauses, required_outer);
        }

        collect_subject_join_clauses(
            root,
            (*baserel).joininfo,
            foreign_varno,
            &mut clauses,
            &mut required_outer,
        );
        let implied_equalities = pg_sys::generate_implied_equalities_for_column(
            root,
            baserel,
            Some(subject_id_eclass_member),
            ptr::null_mut(),
            ptr::null_mut(),
        );
        collect_subject_join_clauses(
            root,
            implied_equalities,
            foreign_varno,
            &mut clauses,
            &mut required_outer,
        );

        (clauses, required_outer)
    }
}

unsafe extern "C-unwind" fn subject_id_eclass_member(
    _root: *mut pg_sys::PlannerInfo,
    rel: *mut pg_sys::RelOptInfo,
    _ec: *mut pg_sys::EquivalenceClass,
    em: *mut pg_sys::EquivalenceMember,
    _arg: *mut std::ffi::c_void,
) -> bool {
    unsafe {
        !rel.is_null()
            && !em.is_null()
            && !(*em).em_expr.is_null()
            && is_subject_id_var((*em).em_expr, (*rel).relid)
    }
}

unsafe fn collect_subject_join_clauses(
    root: *mut pg_sys::PlannerInfo,
    candidates: *mut pg_sys::List,
    foreign_varno: pg_sys::Index,
    clauses: &mut *mut pg_sys::List,
    required_outer: &mut pg_sys::Relids,
) {
    unsafe {
        if candidates.is_null() {
            return;
        }
        for idx in 0..pg_sys::list_length(candidates) {
            let rinfo = pg_sys::list_nth(candidates, idx) as *mut pg_sys::RestrictInfo;
            if rinfo.is_null() || (*rinfo).clause.is_null() {
                continue;
            }
            if !subject_join_clause_references_outer((*rinfo).clause, foreign_varno) {
                continue;
            }

            let varnos = pg_sys::pull_varnos(root, (*rinfo).clause as *mut pg_sys::Node);
            let outer = pg_sys::bms_del_member(pg_sys::bms_copy(varnos), foreign_varno as i32);
            if outer.is_null() || pg_sys::bms_num_members(outer) <= 0 {
                continue;
            }
            *clauses = pg_sys::lappend(*clauses, rinfo.cast());
            *required_outer = pg_sys::bms_add_members(*required_outer, outer);
        }
    }
}

unsafe fn subject_join_clause_references_outer(
    clause: *mut pg_sys::Expr,
    foreign_varno: pg_sys::Index,
) -> bool {
    unsafe {
        let clause = strip_relabel(clause);
        if clause.is_null() || (*clause).type_ != pg_sys::NodeTag::T_OpExpr {
            return false;
        }
        let op = clause as *mut pg_sys::OpExpr;
        if !is_text_equality_operator((*op).opno) || pg_sys::list_length((*op).args) != 2 {
            return false;
        }

        let left = pg_sys::list_nth((*op).args, 0) as *mut pg_sys::Expr;
        let right = pg_sys::list_nth((*op).args, 1) as *mut pg_sys::Expr;
        (is_subject_id_var(left, foreign_varno)
            && outer_subject_ref(right, foreign_varno).is_some())
            || (is_subject_id_var(right, foreign_varno)
                && outer_subject_ref(left, foreign_varno).is_some())
    }
}

unsafe fn outer_subject_ref(
    node: *mut pg_sys::Expr,
    foreign_varno: pg_sys::Index,
) -> Option<OuterVarRef> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() {
            return None;
        }

        let candidate = if (*node).type_ == pg_sys::NodeTag::T_CoerceViaIO {
            let coerce = node as *mut pg_sys::CoerceViaIO;
            if (*coerce).resulttype != pg_sys::TEXTOID {
                return None;
            }
            strip_relabel((*coerce).arg)
        } else {
            node
        };
        if candidate.is_null() || (*candidate).type_ != pg_sys::NodeTag::T_Var {
            return None;
        }

        let var = candidate as *mut pg_sys::Var;
        if varno_matches((*var).varno, foreign_varno) || (*var).varattno <= 0 {
            return None;
        }
        Some(OuterVarRef {
            attno: (*var).varattno,
            typid: (*var).vartype,
        })
    }
}

unsafe fn text_param_ref(node: *mut pg_sys::Expr) -> Option<RuntimeParamRef> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Param {
            return None;
        }
        let param = node as *mut pg_sys::Param;
        if (*param).paramtype != pg_sys::TEXTOID {
            return None;
        }
        param_ref(param)
    }
}

unsafe fn text_output_param_ref(node: *mut pg_sys::Expr) -> Option<(RuntimeParamRef, pg_sys::Oid)> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_CoerceViaIO {
            return None;
        }
        let coerce = node as *mut pg_sys::CoerceViaIO;
        if (*coerce).resulttype != pg_sys::TEXTOID {
            return None;
        }
        let arg = strip_relabel((*coerce).arg);
        if arg.is_null() || (*arg).type_ != pg_sys::NodeTag::T_Param {
            return None;
        }
        let param = arg as *mut pg_sys::Param;
        Some((param_ref(param)?, (*param).paramtype))
    }
}

unsafe fn text_array_param_ref(node: *mut pg_sys::Expr) -> Option<RuntimeParamRef> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Param {
            return None;
        }
        let param = node as *mut pg_sys::Param;
        if (*param).paramtype != pg_sys::TEXTARRAYOID {
            return None;
        }
        param_ref(param)
    }
}

unsafe fn bool_param_ref(node: *mut pg_sys::Expr) -> Option<RuntimeParamRef> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Param {
            return None;
        }
        let param = node as *mut pg_sys::Param;
        if (*param).paramtype != pg_sys::BOOLOID {
            return None;
        }
        param_ref(param)
    }
}

unsafe fn param_ref(param: *mut pg_sys::Param) -> Option<RuntimeParamRef> {
    unsafe {
        match (*param).paramkind {
            pg_sys::ParamKind::PARAM_EXTERN if (*param).paramid > 0 => {
                Some(RuntimeParamRef::Extern((*param).paramid))
            }
            pg_sys::ParamKind::PARAM_EXEC if (*param).paramid >= 0 => {
                Some(RuntimeParamRef::Exec((*param).paramid))
            }
            _ => None,
        }
    }
}

unsafe fn body_filter_from_clause(
    clause: *mut pg_sys::Expr,
    foreign_varno: pg_sys::Index,
) -> Option<BodyPushdownFilter> {
    unsafe {
        let clause = strip_relabel(clause);
        if clause.is_null() || (*clause).type_ != pg_sys::NodeTag::T_OpExpr {
            return None;
        }

        let op = clause as *mut pg_sys::OpExpr;
        if pg_sys::list_length((*op).args) != 2 {
            return None;
        }

        let left = pg_sys::list_nth((*op).args, 0) as *mut pg_sys::Expr;
        let right = pg_sys::list_nth((*op).args, 1) as *mut pg_sys::Expr;

        if is_jsonb_contains_operator((*op).opno) && is_body_var(left, foreign_varno) {
            jsonb_const_text(right)
                .map(BodyPushdownFilter::Contains)
                .or_else(|| jsonb_param_ref(right).map(BodyPushdownFilter::ContainsParam))
        } else {
            body_field_equality_filter((*op).opno, left, right, foreign_varno)
        }
    }
}

unsafe fn stale_filter_from_clause(
    clause: *mut pg_sys::Expr,
    foreign_varno: pg_sys::Index,
) -> Option<StaleFilter> {
    unsafe {
        let clause = strip_relabel(clause);
        if clause.is_null() {
            return None;
        }

        if is_stale_var(clause, foreign_varno) {
            return Some(StaleFilter::Value(true));
        }

        if (*clause).type_ == pg_sys::NodeTag::T_BoolExpr {
            let expr = clause as *mut pg_sys::BoolExpr;
            if (*expr).boolop == pg_sys::BoolExprType::NOT_EXPR
                && pg_sys::list_length((*expr).args) == 1
            {
                let arg = pg_sys::list_nth((*expr).args, 0) as *mut pg_sys::Expr;
                if is_stale_var(arg, foreign_varno) {
                    return Some(StaleFilter::Value(false));
                }
            }
            return None;
        }

        if (*clause).type_ != pg_sys::NodeTag::T_OpExpr {
            return None;
        }
        let op = clause as *mut pg_sys::OpExpr;
        if !is_bool_equality_operator((*op).opno) || pg_sys::list_length((*op).args) != 2 {
            return None;
        }

        let left = pg_sys::list_nth((*op).args, 0) as *mut pg_sys::Expr;
        let right = pg_sys::list_nth((*op).args, 1) as *mut pg_sys::Expr;
        if is_stale_var(left, foreign_varno) {
            bool_const_value(right)
                .map(StaleFilter::Value)
                .or_else(|| bool_param_ref(right).map(StaleFilter::Param))
        } else if is_stale_var(right, foreign_varno) {
            bool_const_value(left)
                .map(StaleFilter::Value)
                .or_else(|| bool_param_ref(left).map(StaleFilter::Param))
        } else {
            None
        }
    }
}

unsafe fn source_hash_filter_from_clause(
    clause: *mut pg_sys::Expr,
    foreign_varno: pg_sys::Index,
) -> Option<SourceHashFilter> {
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
        if is_source_hash_var(left, foreign_varno) {
            text_const_value(right)
                .map(SourceHashFilter::Value)
                .or_else(|| text_param_ref(right).map(SourceHashFilter::Param))
        } else if is_source_hash_var(right, foreign_varno) {
            text_const_value(left)
                .map(SourceHashFilter::Value)
                .or_else(|| text_param_ref(left).map(SourceHashFilter::Param))
        } else {
            None
        }
    }
}

unsafe fn body_field_equality_filter(
    opno: pg_sys::Oid,
    left: *mut pg_sys::Expr,
    right: *mut pg_sys::Expr,
    foreign_varno: pg_sys::Index,
) -> Option<BodyPushdownFilter> {
    unsafe {
        if !is_text_equality_operator(opno) {
            return None;
        }

        if let Some(field) = body_text_field_from_expr(left, foreign_varno) {
            return text_const_value(right)
                .map(|value| BodyPushdownFilter::FieldEquals(field.clone(), value))
                .or_else(|| {
                    text_param_ref(right)
                        .map(|param_ref| BodyPushdownFilter::FieldEqualsParam(field, param_ref))
                });
        }

        body_text_field_from_expr(right, foreign_varno).and_then(|field| {
            text_const_value(left)
                .map(|value| BodyPushdownFilter::FieldEquals(field.clone(), value))
                .or_else(|| {
                    text_param_ref(left)
                        .map(|param_ref| BodyPushdownFilter::FieldEqualsParam(field, param_ref))
                })
        })
    }
}

unsafe fn body_text_field_from_expr(
    node: *mut pg_sys::Expr,
    foreign_varno: pg_sys::Index,
) -> Option<String> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_OpExpr {
            return None;
        }
        let op = node as *mut pg_sys::OpExpr;
        if !is_jsonb_text_extract_operator((*op).opno) || pg_sys::list_length((*op).args) != 2 {
            return None;
        }
        let left = pg_sys::list_nth((*op).args, 0) as *mut pg_sys::Expr;
        let right = pg_sys::list_nth((*op).args, 1) as *mut pg_sys::Expr;
        if is_body_var(left, foreign_varno) {
            text_const_value(right)
        } else {
            None
        }
    }
}

unsafe fn is_subject_id_var(node: *mut pg_sys::Expr, foreign_varno: pg_sys::Index) -> bool {
    unsafe {
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Var {
            return false;
        }
        let var = node as *mut pg_sys::Var;
        varno_matches((*var).varno, foreign_varno)
            && (*var).varattno == 1
            && (*var).vartype == pg_sys::TEXTOID
    }
}

unsafe fn is_body_var(node: *mut pg_sys::Expr, foreign_varno: pg_sys::Index) -> bool {
    unsafe {
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Var {
            return false;
        }
        let var = node as *mut pg_sys::Var;
        varno_matches((*var).varno, foreign_varno)
            && (*var).varattno == 2
            && (*var).vartype == pg_sys::JSONBOID
    }
}

unsafe fn is_stale_var(node: *mut pg_sys::Expr, foreign_varno: pg_sys::Index) -> bool {
    unsafe {
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Var {
            return false;
        }
        let var = node as *mut pg_sys::Var;
        varno_matches((*var).varno, foreign_varno)
            && (*var).varattno == 3
            && (*var).vartype == pg_sys::BOOLOID
    }
}

unsafe fn is_source_hash_var(node: *mut pg_sys::Expr, foreign_varno: pg_sys::Index) -> bool {
    unsafe {
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Var {
            return false;
        }
        let var = node as *mut pg_sys::Var;
        varno_matches((*var).varno, foreign_varno)
            && (*var).varattno == 4
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

unsafe fn bool_const_value(node: *mut pg_sys::Expr) -> Option<bool> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Const {
            return None;
        }
        let value = node as *mut pg_sys::Const;
        if (*value).constisnull || (*value).consttype != pg_sys::BOOLOID {
            return None;
        }
        <bool as FromDatum>::from_polymorphic_datum((*value).constvalue, false, (*value).consttype)
    }
}

unsafe fn jsonb_const_text(node: *mut pg_sys::Expr) -> Option<String> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Const {
            return None;
        }
        let value = node as *mut pg_sys::Const;
        if (*value).constisnull || (*value).consttype != pg_sys::JSONBOID {
            return None;
        }
        let jsonb = <JsonB as FromDatum>::from_polymorphic_datum(
            (*value).constvalue,
            false,
            (*value).consttype,
        )?;
        serde_json::to_string(&jsonb.0).ok()
    }
}

unsafe fn jsonb_param_ref(node: *mut pg_sys::Expr) -> Option<RuntimeParamRef> {
    unsafe {
        let node = strip_relabel(node);
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_Param {
            return None;
        }
        let param = node as *mut pg_sys::Param;
        if (*param).paramtype != pg_sys::JSONBOID {
            return None;
        }
        param_ref(param)
    }
}

unsafe fn text_array_values(node: *mut pg_sys::Expr) -> Option<Vec<String>> {
    unsafe {
        let node = strip_relabel(node);
        if !node.is_null() && (*node).type_ == pg_sys::NodeTag::T_Const {
            let value = node as *mut pg_sys::Const;
            if (*value).constisnull || (*value).consttype != pg_sys::TEXTARRAYOID {
                return None;
            }
            if text_array_const_has_nulls(value) {
                return None;
            }
            let Some(array) = <Array<'_, String> as FromDatum>::from_polymorphic_datum(
                (*value).constvalue,
                false,
                (*value).consttype,
            ) else {
                return None;
            };
            let mut values = Vec::new();
            for value in array {
                let Some(value) = value else {
                    return None;
                };
                values.push(value);
            }
            return Some(values);
        }
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_ArrayExpr {
            return None;
        }
        let array = node as *mut pg_sys::ArrayExpr;
        if (*array).element_typeid != pg_sys::TEXTOID || (*array).multidims {
            return None;
        }
        let mut values = Vec::new();
        for idx in 0..pg_sys::list_length((*array).elements) {
            let element = pg_sys::list_nth((*array).elements, idx) as *mut pg_sys::Expr;
            if let Some(value) = text_const_value(element) {
                values.push(value);
            } else {
                return None;
            }
        }
        Some(values)
    }
}

unsafe fn text_array_const_has_nulls(value: *mut pg_sys::Const) -> bool {
    unsafe {
        let original = (*value).constvalue.cast_mut_ptr::<pg_sys::varlena>();
        if original.is_null() {
            return true;
        }
        let detoasted = pg_sys::pg_detoast_datum(original);
        if detoasted.is_null() {
            return true;
        }
        let has_nulls = pg_sys::array_contains_nulls(detoasted.cast::<pg_sys::ArrayType>());
        if detoasted != original {
            pg_sys::pfree(detoasted.cast());
        }
        has_nulls
    }
}
