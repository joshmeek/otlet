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
