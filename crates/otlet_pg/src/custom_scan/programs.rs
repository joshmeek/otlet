struct LoadedSemanticProgram {
    name: String,
    index_name: String,
    predicate: String,
    expected_json: String,
    program_hash: String,
    compiler_mode: String,
}

struct LoadedSemanticActionProgram {
    name: String,
    index_name: String,
    action_type: String,
    predicate: String,
    expected_json: String,
    program_hash: String,
    compiler_mode: String,
}

fn load_semantic_program(program_name: &str) -> Option<LoadedSemanticProgram> {
    let query = format!(
        "SELECT name, index_name, predicate, expected::text AS expected_json, program_hash, \
                CASE WHEN compiler_version LIKE '%model%' THEN 'model' ELSE 'deterministic' END AS compiler_mode \
         FROM otlet.semantic_programs \
         WHERE name = {} \
         LIMIT 1",
        sql_literal(program_name)
    );
    pgrx::Spi::connect(|client| {
        let table = client.select(query.as_str(), Some(1), &[]).ok()?;
        if table.is_empty() {
            return None;
        }
        let row = table.first();
        Some(LoadedSemanticProgram {
            name: row.get_by_name::<String, _>("name").ok()??,
            index_name: row.get_by_name::<String, _>("index_name").ok()??,
            predicate: row.get_by_name::<String, _>("predicate").ok()??,
            expected_json: row.get_by_name::<String, _>("expected_json").ok()??,
            program_hash: row.get_by_name::<String, _>("program_hash").ok()??,
            compiler_mode: row.get_by_name::<String, _>("compiler_mode").ok()??,
        })
    })
}

fn inline_semantic_program(
    index_name: &str,
    predicate_text: &str,
) -> Option<LoadedSemanticProgram> {
    let expected = compile_semantic_expected_text(predicate_text)?;
    let expected_json = serde_json::to_string(&expected).ok()?;
    let index_literal = sql_literal(index_name);
    let predicate_literal = sql_literal(predicate_text);
    let expected_literal = sql_literal(&expected_json);
    let query = format!(
        "WITH compiled AS ( \
           SELECT {expected_literal}::jsonb AS expected \
         ), hashed AS ( \
           SELECT expected, \
                  md5({index_literal} || chr(31) || {predicate_literal} || chr(31) || expected::text || chr(31) || 'otlet_semantic_program_v1') AS program_hash \
           FROM compiled \
         ) \
         SELECT 'semantic_auto_' || substr(program_hash, 1, 24) AS name, \
                {index_literal}::text AS index_name, \
                {predicate_literal}::text AS predicate, \
                expected::text AS expected_json, \
                program_hash, \
                'deterministic'::text AS compiler_mode \
         FROM hashed \
         WHERE EXISTS (SELECT 1 FROM otlet.semantic_indexes WHERE name = {index_literal}) \
         LIMIT 1"
    );
    pgrx::Spi::connect(|client| {
        let table = client.select(query.as_str(), Some(1), &[]).ok()?;
        if table.is_empty() {
            return None;
        }
        let row = table.first();
        Some(LoadedSemanticProgram {
            name: row.get_by_name::<String, _>("name").ok()??,
            index_name: row.get_by_name::<String, _>("index_name").ok()??,
            predicate: row.get_by_name::<String, _>("predicate").ok()??,
            expected_json: row.get_by_name::<String, _>("expected_json").ok()??,
            program_hash: row.get_by_name::<String, _>("program_hash").ok()??,
            compiler_mode: row.get_by_name::<String, _>("compiler_mode").ok()??,
        })
    })
}

fn inline_semantic_action_program(
    index_name: &str,
    action_type: &str,
    predicate_text: &str,
) -> Option<LoadedSemanticActionProgram> {
    let record_type = semantic_index_record_type(index_name)?;
    let expected =
        compile_semantic_action_expected_text(action_type, &record_type, predicate_text)?;
    let expected_json = serde_json::to_string(&expected).ok()?;
    let index_literal = sql_literal(index_name);
    let action_type_literal = sql_literal(action_type);
    let predicate_literal = sql_literal(predicate_text);
    let expected_literal = sql_literal(&expected_json);
    let query = format!(
        "WITH compiled AS ( \
           SELECT {expected_literal}::jsonb AS expected \
         ), hashed AS ( \
           SELECT expected, \
                  md5({index_literal} || chr(31) || {action_type_literal} || chr(31) || {predicate_literal} || chr(31) || expected::text || chr(31) || 'otlet_semantic_action_program_v1') AS program_hash \
           FROM compiled \
         ) \
         SELECT 'semantic_action_auto_' || substr(program_hash, 1, 24) AS name, \
                {index_literal}::text AS index_name, \
                {action_type_literal}::text AS action_type, \
                {predicate_literal}::text AS predicate, \
                expected::text AS expected_json, \
                program_hash, \
                'deterministic'::text AS compiler_mode \
         FROM hashed \
         WHERE EXISTS (SELECT 1 FROM otlet.semantic_indexes WHERE name = {index_literal}) \
         LIMIT 1"
    );
    pgrx::Spi::connect(|client| {
        let table = client.select(query.as_str(), Some(1), &[]).ok()?;
        if table.is_empty() {
            return None;
        }
        let row = table.first();
        Some(LoadedSemanticActionProgram {
            name: row.get_by_name::<String, _>("name").ok()??,
            index_name: row.get_by_name::<String, _>("index_name").ok()??,
            action_type: row.get_by_name::<String, _>("action_type").ok()??,
            predicate: row.get_by_name::<String, _>("predicate").ok()??,
            expected_json: row.get_by_name::<String, _>("expected_json").ok()??,
            program_hash: row.get_by_name::<String, _>("program_hash").ok()??,
            compiler_mode: row.get_by_name::<String, _>("compiler_mode").ok()??,
        })
    })
}

fn semantic_index_record_type(index_name: &str) -> Option<String> {
    let query = format!(
        "SELECT record_type FROM otlet.semantic_indexes WHERE name = {} LIMIT 1",
        sql_literal(index_name)
    );
    pgrx::Spi::connect(|client| {
        let table = client.select(query.as_str(), Some(1), &[]).ok()?;
        if table.is_empty() {
            return None;
        }
        table.first().get_by_name::<String, _>("record_type").ok()?
    })
}

fn compile_semantic_expected_text(predicate_text: &str) -> Option<Value> {
    let normalized = predicate_text.trim().to_lowercase();
    if normalized == "needs review" || normalized == "needs_review" {
        return Some(json!({ "status": "needs_review" }));
    }

    let (field_name, field_value) = split_semantic_predicate(&normalized)?;
    let mut expected = serde_json::Map::new();
    if field_value == "true" {
        expected.insert(field_name.to_string(), Value::Bool(true));
    } else if field_value == "false" {
        expected.insert(field_name.to_string(), Value::Bool(false));
    } else {
        expected.insert(
            field_name.to_string(),
            Value::String(field_value.replace(' ', "_")),
        );
    }
    Some(Value::Object(expected))
}

fn compile_semantic_action_expected_text(
    action_type: &str,
    record_type: &str,
    predicate_text: &str,
) -> Option<Value> {
    if action_type != "create_record" {
        return None;
    }
    let normalized = predicate_text.trim().to_lowercase();
    if matches!(
        normalized.as_str(),
        "indexed row"
            | "semantic indexed row"
            | "semantic is indexed row"
            | "record semantic is indexed row"
    ) {
        return Some(json!({
            "record_type": record_type,
            "body": { "semantic": "indexed row" }
        }));
    }

    let (field_name, field_value) = split_semantic_predicate(&normalized)?;
    let mut body = serde_json::Map::new();
    if field_value == "true" {
        body.insert(field_name.to_string(), Value::Bool(true));
    } else if field_value == "false" {
        body.insert(field_name.to_string(), Value::Bool(false));
    } else {
        let value = if field_name == "semantic" {
            field_value
        } else {
            field_value.replace(' ', "_")
        };
        body.insert(field_name.to_string(), Value::String(value));
    }

    let mut expected = serde_json::Map::new();
    expected.insert(
        "record_type".to_string(),
        Value::String(record_type.to_string()),
    );
    expected.insert("body".to_string(), Value::Object(body));
    Some(Value::Object(expected))
}

fn split_semantic_predicate(normalized: &str) -> Option<(&str, String)> {
    let (field_name, raw_value) = if let Some((field, value)) = normalized.split_once(" equals ") {
        (field.trim(), value.trim())
    } else if let Some((field, value)) = normalized.split_once(" is ") {
        (field.trim(), value.trim())
    } else if let Some((field, value)) = normalized.split_once('=') {
        (field.trim(), value.trim())
    } else {
        return None;
    };
    if !simple_identifier(field_name) {
        return None;
    }
    let field_value = raw_value.trim_matches('\'').trim().to_string();
    if field_value.is_empty()
        || !field_value.chars().all(|ch| {
            ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_' || ch == ' ' || ch == '-'
        })
    {
        return None;
    }
    Some((field_name, field_value))
}

fn simple_identifier(value: &str) -> bool {
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first.is_ascii_lowercase() || first == '_') {
        return false;
    }
    chars.all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_')
}

fn load_semantic_action_program(program_name: &str) -> Option<LoadedSemanticActionProgram> {
    let query = format!(
        "SELECT name, index_name, action_type, predicate, expected::text AS expected_json, program_hash, \
                CASE WHEN compiler_version LIKE '%model%' THEN 'model' ELSE 'deterministic' END AS compiler_mode \
         FROM otlet.semantic_action_programs \
         WHERE name = {} \
         LIMIT 1",
        sql_literal(program_name)
    );
    pgrx::Spi::connect(|client| {
        let table = client.select(query.as_str(), Some(1), &[]).ok()?;
        if table.is_empty() {
            return None;
        }
        let row = table.first();
        Some(LoadedSemanticActionProgram {
            name: row.get_by_name::<String, _>("name").ok()??,
            index_name: row.get_by_name::<String, _>("index_name").ok()??,
            action_type: row.get_by_name::<String, _>("action_type").ok()??,
            predicate: row.get_by_name::<String, _>("predicate").ok()??,
            expected_json: row.get_by_name::<String, _>("expected_json").ok()??,
            program_hash: row.get_by_name::<String, _>("program_hash").ok()??,
            compiler_mode: row.get_by_name::<String, _>("compiler_mode").ok()??,
        })
    })
}

fn load_semantic_join_program(program_name: &str) -> Option<LoadedSemanticProgram> {
    let query = format!(
        "SELECT name, index_name, predicate, expected::text AS expected_json, program_hash, \
                CASE WHEN compiler_version LIKE '%model%' THEN 'model' ELSE 'deterministic' END AS compiler_mode \
         FROM otlet.semantic_join_programs \
         WHERE name = {} \
         LIMIT 1",
        sql_literal(program_name)
    );
    pgrx::Spi::connect(|client| {
        let table = client.select(query.as_str(), Some(1), &[]).ok()?;
        if table.is_empty() {
            return None;
        }
        let row = table.first();
        Some(LoadedSemanticProgram {
            name: row.get_by_name::<String, _>("name").ok()??,
            index_name: row.get_by_name::<String, _>("index_name").ok()??,
            predicate: row.get_by_name::<String, _>("predicate").ok()??,
            expected_json: row.get_by_name::<String, _>("expected_json").ok()??,
            program_hash: row.get_by_name::<String, _>("program_hash").ok()??,
            compiler_mode: row.get_by_name::<String, _>("compiler_mode").ok()??,
        })
    })
}
