use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::ffi::CString;
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const CONTEXT_TOKENS: u32 = 4096;
const BATCH_TOKENS: usize = 512;
const MAX_TOKEN_PIECE_BYTES: usize = 16 * 1024;

#[derive(Deserialize)]
struct Claim {
    job_id: i64,
    claim_token: String,
    claim_status: String,
    task_name: String,
    prompt: String,
    prompt_hash: String,
    runtime_options: Value,
    model_policy: Value,
    evidence_limits: Value,
}

struct Config {
    database_url: String,
    psql: String,
    worker_id: String,
    protocol_version: i32,
    runtime_identity_hash: String,
    model_name: String,
    model_path: PathBuf,
    model_sha256: String,
    poll_interval: Duration,
    once: bool,
}

impl Config {
    fn from_env() -> Result<Self, String> {
        let protocol_version = env_required("OTLET_PORTABLE_PROTOCOL_VERSION")?
            .parse::<i32>()
            .map_err(|_| "OTLET_PORTABLE_PROTOCOL_VERSION must be an integer".to_owned())?;
        let runtime_identity_hash = env_required("OTLET_PORTABLE_RUNTIME_IDENTITY_HASH")?;
        let model_sha256 = env_required("OTLET_MODEL_SHA256")?.to_ascii_lowercase();
        if !is_sha256(&runtime_identity_hash) || !is_sha256(&model_sha256) {
            return Err("portable runtime and model hashes must be lowercase SHA-256".to_owned());
        }
        let poll_ms = std::env::var("OTLET_PORTABLE_POLL_MS")
            .ok()
            .map(|value| value.parse::<u64>())
            .transpose()
            .map_err(|_| "OTLET_PORTABLE_POLL_MS must be an integer".to_owned())?
            .unwrap_or(1000)
            .clamp(100, 60_000);
        let once = std::env::args().any(|arg| arg == "--once")
            || env_bool("OTLET_PORTABLE_ONCE").unwrap_or(false);

        Ok(Self {
            database_url: env_required("OTLET_DATABASE_URL")?,
            psql: std::env::var("OTLET_PSQL").unwrap_or_else(|_| "psql".to_owned()),
            worker_id: env_required("OTLET_PORTABLE_WORKER_ID")?,
            protocol_version,
            runtime_identity_hash,
            model_name: env_required("OTLET_MODEL_NAME")?,
            model_path: PathBuf::from(env_required("OTLET_MODEL_PATH")?),
            model_sha256,
            poll_interval: Duration::from_millis(poll_ms),
            once,
        })
    }
}

struct Database {
    url: String,
    psql: String,
}

impl Database {
    fn query(&self, sql: &str) -> Result<Vec<String>, String> {
        let mut child = Command::new(&self.psql)
            .args([
                "--no-psqlrc",
                "--quiet",
                "--tuples-only",
                "--no-align",
                "--set",
                "ON_ERROR_STOP=1",
                "--dbname",
                &self.url,
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|err| format!("could not start psql: {err}"))?;
        child
            .stdin
            .as_mut()
            .ok_or("psql stdin is unavailable")?
            .write_all(sql.as_bytes())
            .map_err(|err| format!("could not write psql request: {err}"))?;
        let output = child
            .wait_with_output()
            .map_err(|err| format!("could not wait for psql: {err}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let message = stderr.lines().next().unwrap_or("database request failed");
            return Err(format!("psql failed: {}", truncate(message, 512)));
        }
        let stdout = String::from_utf8(output.stdout)
            .map_err(|_| "psql returned non-UTF-8 output".to_owned())?;
        Ok(stdout
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_owned)
            .collect())
    }

    fn claim(&self, config: &Config) -> Result<Vec<Claim>, String> {
        let sql = format!(
            "SELECT jsonb_build_object(\
               'job_id', c.job_id, \
               'claim_token', c.claim_token, \
               'claim_status', c.claim_status, \
               'task_name', c.task_name, \
               'prompt', c.prompt, \
               'prompt_hash', c.prompt_hash, \
               'runtime_options', c.runtime_options, \
               'model_policy', c.model_policy, \
               'evidence_limits', c.evidence_limits\
             )::text \
             FROM otlet.portable_claim_jobs({}, {}, {}, 1) c;\n",
            sql_text(&config.worker_id),
            config.protocol_version,
            sql_text(&config.runtime_identity_hash)
        );
        self.query(&sql)?
            .into_iter()
            .map(|line| {
                serde_json::from_str(&line)
                    .map_err(|err| format!("portable claim response is invalid: {err}"))
            })
            .collect()
    }

    fn complete(
        &self,
        config: &Config,
        claim: &Claim,
        raw_output: &str,
        output: &Value,
        actions: &Value,
        trace_summary: &Value,
    ) -> Result<(), String> {
        let sql = format!(
            "SELECT job_status \
             FROM otlet.portable_complete_job(\
               {}, {}, {}, {}, {}, {}::jsonb, {}, {}::jsonb, \
               prompt_hash => {}, trace_summary => {}::jsonb, model_name => {}\
             );\n",
            sql_text(&config.worker_id),
            config.protocol_version,
            sql_text(&config.runtime_identity_hash),
            claim.job_id,
            sql_text(&claim.claim_token),
            sql_text(&output.to_string()),
            sql_text(raw_output),
            sql_text(&actions.to_string()),
            sql_text(&claim.prompt_hash),
            sql_text(&trace_summary.to_string()),
            sql_text(&config.model_name)
        );
        let rows = self.query(&sql)?;
        if rows.as_slice() != ["complete"] {
            return Err(format!(
                "portable completion returned unexpected state: {rows:?}"
            ));
        }
        Ok(())
    }

    fn fail(
        &self,
        config: &Config,
        claim: &Claim,
        error: &str,
        raw_output: Option<&str>,
    ) -> Result<(), String> {
        let raw = raw_output.map_or_else(|| "NULL".to_owned(), sql_text);
        let sql = format!(
            "SELECT job_status \
             FROM otlet.portable_fail_job(\
               {}, {}, {}, {}, {}, {}, raw_output => {}, \
               prompt_hash => {}, schema_validation_status => 'failed', \
               trace_summary => '{{\"trace_version\":\"otlet_portable_worker_trace_v1\",\"schema_validation_status\":\"failed\"}}'::jsonb, \
               model_name => {}\
             );\n",
            sql_text(&config.worker_id),
            config.protocol_version,
            sql_text(&config.runtime_identity_hash),
            claim.job_id,
            sql_text(&claim.claim_token),
            sql_text(error),
            raw,
            sql_text(&claim.prompt_hash),
            sql_text(&config.model_name)
        );
        let rows = self.query(&sql)?;
        if !matches!(rows.as_slice(), [state] if state == "failed" || state == "canceled") {
            return Err(format!(
                "portable failure returned unexpected state: {rows:?}"
            ));
        }
        Ok(())
    }

    fn cancel(&self, config: &Config, claim: &Claim) -> Result<(), String> {
        let sql = format!(
            "SELECT job_status FROM otlet.portable_cancel_job({}, {}, {}, {}, {}, 'canceled before portable inference');\n",
            sql_text(&config.worker_id),
            config.protocol_version,
            sql_text(&config.runtime_identity_hash),
            claim.job_id,
            sql_text(&claim.claim_token)
        );
        let rows = self.query(&sql)?;
        if rows.as_slice() != ["canceled"] {
            return Err(format!(
                "portable cancellation returned unexpected state: {rows:?}"
            ));
        }
        Ok(())
    }
}

struct LocalModel {
    model: *mut llama_cpp_sys_4::llama_model,
    context: *mut llama_cpp_sys_4::llama_context,
    vocab: *const llama_cpp_sys_4::llama_vocab,
    threads: i32,
}

impl LocalModel {
    fn load(path: &Path, threads: i32) -> Result<Self, String> {
        let path = CString::new(path.as_os_str().as_encoded_bytes())
            .map_err(|_| "model path contains a null byte".to_owned())?;
        unsafe { llama_cpp_sys_4::llama_backend_init() };
        let mut model_params = unsafe { llama_cpp_sys_4::llama_model_default_params() };
        model_params.n_gpu_layers = 0;
        let model =
            unsafe { llama_cpp_sys_4::llama_model_load_from_file(path.as_ptr(), model_params) };
        if model.is_null() {
            return Err("local GGUF model load failed".to_owned());
        }

        let mut context_params = unsafe { llama_cpp_sys_4::llama_context_default_params() };
        context_params.n_ctx = CONTEXT_TOKENS;
        context_params.n_batch = BATCH_TOKENS as u32;
        context_params.n_ubatch = 128;
        context_params.n_threads = threads;
        context_params.n_threads_batch = threads;
        context_params.no_perf = true;
        let context = unsafe { llama_cpp_sys_4::llama_init_from_model(model, context_params) };
        if context.is_null() {
            unsafe { llama_cpp_sys_4::llama_model_free(model) };
            return Err("local GGUF context start failed".to_owned());
        }
        let vocab = unsafe { llama_cpp_sys_4::llama_model_get_vocab(model) };
        if vocab.is_null() {
            unsafe {
                llama_cpp_sys_4::llama_free(context);
                llama_cpp_sys_4::llama_model_free(model);
            }
            return Err("local GGUF model has no vocabulary".to_owned());
        }
        Ok(Self {
            model,
            context,
            vocab,
            threads,
        })
    }

    fn infer(
        &mut self,
        prompt: &str,
        max_tokens: usize,
        max_output_bytes: usize,
    ) -> Result<Inference, String> {
        unsafe {
            llama_cpp_sys_4::llama_set_n_threads(self.context, self.threads, self.threads);
            let memory = llama_cpp_sys_4::llama_get_memory(self.context);
            if !memory.is_null() {
                llama_cpp_sys_4::llama_memory_clear(memory, true);
            }
        }
        let tokens = tokenize(self.vocab, prompt)?;
        if tokens.is_empty() {
            return Err("prompt produced no tokens".to_owned());
        }
        if tokens.len().saturating_add(max_tokens) > CONTEXT_TOKENS as usize {
            return Err("prompt and generation exceed the 4096-token context".to_owned());
        }

        let mut batch = Batch::new(BATCH_TOKENS)?;
        let start = Instant::now();
        for (chunk_index, chunk) in tokens.chunks(BATCH_TOKENS).enumerate() {
            batch.reset();
            let start_position = chunk_index * BATCH_TOKENS;
            for (index, token) in chunk.iter().copied().enumerate() {
                batch.add(
                    token,
                    i32::try_from(start_position + index)
                        .map_err(|_| "prompt position overflowed".to_owned())?,
                    start_position + index + 1 == tokens.len(),
                )?;
            }
            let status = unsafe { llama_cpp_sys_4::llama_decode(self.context, batch.value) };
            if status != 0 {
                return Err(format!("prompt decode failed with status {status}"));
            }
        }

        let sampler = Sampler::greedy()?;
        let mut bytes = Vec::with_capacity(
            max_tokens
                .saturating_mul(8)
                .min(max_output_bytes)
                .min(64 * 1024),
        );
        let mut piece = vec![0_u8; 128];
        let mut completion = JsonCompletion::new();
        let mut generated_tokens = 0_i64;

        for position in tokens.len()..tokens.len() + max_tokens {
            let token =
                unsafe { llama_cpp_sys_4::llama_sampler_sample(sampler.value, self.context, -1) };
            if unsafe { llama_cpp_sys_4::llama_vocab_is_eog(self.vocab, token) } {
                break;
            }
            unsafe { llama_cpp_sys_4::llama_sampler_accept(sampler.value, token) };
            generated_tokens += 1;
            let piece_start = bytes.len();
            token_to_piece(self.vocab, token, &mut piece, &mut bytes)?;
            if bytes.len() > max_output_bytes {
                return Err("model output exceeds the database raw-output limit".to_owned());
            }
            if let Some(end) = completion.observe(&bytes[piece_start..]) {
                bytes.truncate(end);
                break;
            }

            batch.reset();
            batch.add(
                token,
                i32::try_from(position).map_err(|_| "generation position overflowed".to_owned())?,
                true,
            )?;
            let status = unsafe { llama_cpp_sys_4::llama_decode(self.context, batch.value) };
            if status != 0 {
                return Err(format!("generation decode failed with status {status}"));
            }
        }

        let raw_output = String::from_utf8(bytes)
            .map_err(|_| "model output was not valid UTF-8".to_owned())?
            .trim()
            .to_owned();
        Ok(Inference {
            raw_output,
            prompt_tokens: i64::try_from(tokens.len()).unwrap_or(i64::MAX),
            generated_tokens,
            generate_ms: i64::try_from(start.elapsed().as_millis()).unwrap_or(i64::MAX),
        })
    }
}

impl Drop for LocalModel {
    fn drop(&mut self) {
        unsafe {
            llama_cpp_sys_4::llama_free(self.context);
            llama_cpp_sys_4::llama_model_free(self.model);
            llama_cpp_sys_4::llama_backend_free();
        }
    }
}

struct Batch {
    value: llama_cpp_sys_4::llama_batch,
    capacity: usize,
}

impl Batch {
    fn new(capacity: usize) -> Result<Self, String> {
        let capacity_i32 = i32::try_from(capacity).map_err(|_| "batch is too large".to_owned())?;
        let value = unsafe { llama_cpp_sys_4::llama_batch_init(capacity_i32, 0, 1) };
        if value.token.is_null()
            || value.pos.is_null()
            || value.n_seq_id.is_null()
            || value.seq_id.is_null()
            || value.logits.is_null()
        {
            unsafe { llama_cpp_sys_4::llama_batch_free(value) };
            return Err("llama.cpp batch allocation failed".to_owned());
        }
        Ok(Self { value, capacity })
    }

    const fn reset(&mut self) {
        self.value.n_tokens = 0;
    }

    fn add(
        &mut self,
        token: llama_cpp_sys_4::llama_token,
        position: llama_cpp_sys_4::llama_pos,
        logits: bool,
    ) -> Result<(), String> {
        let index = usize::try_from(self.value.n_tokens)
            .map_err(|_| "batch token index is invalid".to_owned())?;
        if index >= self.capacity {
            return Err("llama.cpp batch capacity exceeded".to_owned());
        }
        let sequence = unsafe { *self.value.seq_id.add(index) };
        if sequence.is_null() {
            return Err("llama.cpp batch sequence is unavailable".to_owned());
        }
        unsafe {
            *self.value.token.add(index) = token;
            *self.value.pos.add(index) = position;
            *self.value.n_seq_id.add(index) = 1;
            *sequence = 0;
            *self.value.logits.add(index) = i8::from(logits);
        }
        self.value.n_tokens += 1;
        Ok(())
    }
}

impl Drop for Batch {
    fn drop(&mut self) {
        unsafe { llama_cpp_sys_4::llama_batch_free(self.value) };
    }
}

struct Sampler {
    value: *mut llama_cpp_sys_4::llama_sampler,
}

impl Sampler {
    fn greedy() -> Result<Self, String> {
        let value = unsafe { llama_cpp_sys_4::llama_sampler_init_greedy() };
        if value.is_null() {
            return Err("llama.cpp sampler start failed".to_owned());
        }
        Ok(Self { value })
    }
}

impl Drop for Sampler {
    fn drop(&mut self) {
        unsafe { llama_cpp_sys_4::llama_sampler_free(self.value) };
    }
}

struct Inference {
    raw_output: String,
    prompt_tokens: i64,
    generated_tokens: i64,
    generate_ms: i64,
}

struct JsonCompletion {
    depth: i32,
    in_string: bool,
    escape: bool,
    seen_open: bool,
    bytes_seen: usize,
}

impl JsonCompletion {
    const fn new() -> Self {
        Self {
            depth: 0,
            in_string: false,
            escape: false,
            seen_open: false,
            bytes_seen: 0,
        }
    }

    fn observe(&mut self, bytes: &[u8]) -> Option<usize> {
        for (index, byte) in bytes.iter().copied().enumerate() {
            if self.in_string {
                if self.escape {
                    self.escape = false;
                } else if byte == b'\\' {
                    self.escape = true;
                } else if byte == b'"' {
                    self.in_string = false;
                }
                continue;
            }
            match byte {
                b'"' => self.in_string = true,
                b'{' => {
                    self.depth += 1;
                    self.seen_open = true;
                }
                b'}' => {
                    self.depth -= 1;
                    if self.seen_open && self.depth == 0 {
                        return Some(self.bytes_seen + index + 1);
                    }
                    if self.depth < 0 {
                        return Some(self.bytes_seen + index);
                    }
                }
                _ => {}
            }
        }
        self.bytes_seen += bytes.len();
        None
    }
}

fn tokenize(
    vocab: *const llama_cpp_sys_4::llama_vocab,
    prompt: &str,
) -> Result<Vec<llama_cpp_sys_4::llama_token>, String> {
    let prompt = CString::new(prompt).map_err(|_| "prompt contains a null byte".to_owned())?;
    let prompt_len =
        i32::try_from(prompt.as_bytes().len()).map_err(|_| "prompt is too large".to_owned())?;
    let required = unsafe {
        llama_cpp_sys_4::llama_tokenize(
            vocab,
            prompt.as_ptr(),
            prompt_len,
            std::ptr::null_mut(),
            0,
            true,
            true,
        )
    };
    if required == i32::MIN {
        return Err("llama.cpp returned an invalid token count".to_owned());
    }
    let capacity =
        usize::try_from(required.abs()).map_err(|_| "prompt token count overflowed".to_owned())?;
    let mut tokens = vec![0; capacity];
    let actual = unsafe {
        llama_cpp_sys_4::llama_tokenize(
            vocab,
            prompt.as_ptr(),
            prompt_len,
            tokens.as_mut_ptr(),
            i32::try_from(tokens.len()).map_err(|_| "prompt has too many tokens".to_owned())?,
            true,
            true,
        )
    };
    if actual < 0 {
        return Err("llama.cpp tokenization failed".to_owned());
    }
    tokens.truncate(usize::try_from(actual).map_err(|_| "token count overflowed".to_owned())?);
    Ok(tokens)
}

fn token_to_piece(
    vocab: *const llama_cpp_sys_4::llama_vocab,
    token: llama_cpp_sys_4::llama_token,
    buffer: &mut Vec<u8>,
    output: &mut Vec<u8>,
) -> Result<(), String> {
    let mut size = unsafe {
        llama_cpp_sys_4::llama_token_to_piece(
            vocab,
            token,
            buffer.as_mut_ptr().cast(),
            i32::try_from(buffer.len()).map_err(|_| "token buffer is too large".to_owned())?,
            0,
            true,
        )
    };
    if size < 0 {
        let required = usize::try_from(size.checked_neg().ok_or("invalid token piece size")?)
            .map_err(|_| "token piece size overflowed".to_owned())?;
        if required > MAX_TOKEN_PIECE_BYTES {
            return Err("token piece exceeds the byte limit".to_owned());
        }
        buffer.resize(required, 0);
        size = unsafe {
            llama_cpp_sys_4::llama_token_to_piece(
                vocab,
                token,
                buffer.as_mut_ptr().cast(),
                i32::try_from(buffer.len()).map_err(|_| "token buffer is too large".to_owned())?,
                0,
                true,
            )
        };
    }
    if size > 0 {
        let size = usize::try_from(size).map_err(|_| "token piece size overflowed".to_owned())?;
        if size > buffer.len() {
            return Err("token piece exceeded its buffer".to_owned());
        }
        output.extend_from_slice(&buffer[..size]);
    }
    Ok(())
}

fn process_claim(
    database: &Database,
    config: &Config,
    model: &mut LocalModel,
    claim: &Claim,
) -> Result<(), String> {
    if claim.claim_status == "cancel_requested" {
        database.cancel(config, claim)?;
        log_event("job_canceled", claim, None);
        return Ok(());
    }
    let Some(direct) = claim.model_policy.get("direct").and_then(Value::as_object) else {
        database.fail(config, claim, "portable_model_policy_missing", None)?;
        log_event("job_failed", claim, Some("model_policy_missing"));
        return Ok(());
    };
    if direct.get("name").and_then(Value::as_str) != Some(config.model_name.as_str())
        || direct.get("artifact_hash").and_then(Value::as_str) != Some(config.model_sha256.as_str())
    {
        database.fail(config, claim, "portable_model_identity_mismatch", None)?;
        log_event("job_failed", claim, Some("model_identity_mismatch"));
        return Ok(());
    }
    let max_tokens = claim
        .runtime_options
        .get("max_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(512);
    let max_tokens = usize::try_from(max_tokens.clamp(1, 4096)).unwrap_or(4096);
    let max_output_bytes = claim
        .evidence_limits
        .get("max_raw_output_bytes")
        .and_then(Value::as_u64)
        .unwrap_or(1024 * 1024)
        .clamp(1, 16 * 1024 * 1024);
    let max_output_bytes = usize::try_from(max_output_bytes).unwrap_or(16 * 1024 * 1024);
    let inference = match model.infer(&claim.prompt, max_tokens, max_output_bytes) {
        Ok(inference) => inference,
        Err(error) => {
            database.fail(config, claim, &truncate(&error, 1024), None)?;
            log_event("job_failed", claim, Some("local_inference_failed"));
            return Ok(());
        }
    };
    let envelope: Value = match serde_json::from_str(&inference.raw_output) {
        Ok(value) => value,
        Err(_) => {
            database.fail(
                config,
                claim,
                "portable_model_output_invalid_json",
                Some(&inference.raw_output),
            )?;
            log_event("job_failed", claim, Some("invalid_model_json"));
            return Ok(());
        }
    };
    let (Some(output), Some(actions)) = (envelope.get("output"), envelope.get("actions")) else {
        database.fail(
            config,
            claim,
            "portable_model_output_invalid_envelope",
            Some(&inference.raw_output),
        )?;
        log_event("job_failed", claim, Some("invalid_model_envelope"));
        return Ok(());
    };
    let trace = json!({
        "trace_version": "otlet_portable_worker_trace_v1",
        "prompt_hash": claim.prompt_hash,
        "prompt_tokens": inference.prompt_tokens,
        "generated_tokens": inference.generated_tokens,
        "generate_ms": inference.generate_ms,
        "schema_validation_status": "not_run",
        "runtime": "local_llama_cpp"
    });
    if let Err(error) = database.complete(
        config,
        claim,
        &inference.raw_output,
        output,
        actions,
        &trace,
    ) {
        database.fail(
            config,
            claim,
            "portable_result_rejected_by_database",
            Some(&inference.raw_output),
        )?;
        log_event(
            "job_failed",
            claim,
            Some(&format!(
                "database_validation_failed:{}",
                truncate(&error, 160)
            )),
        );
        return Ok(());
    }
    log_event("job_completed", claim, None);
    Ok(())
}

fn runtime_identity() -> Value {
    json!({
        "engine": "llama.cpp",
        "protocol_version": 1,
        "transport": "postgres_psql",
        "worker": "otlet-portable-worker",
        "worker_version": env!("CARGO_PKG_VERSION")
    })
}

fn main() {
    if std::env::args().any(|arg| arg == "--print-runtime-identity") {
        println!("{}", runtime_identity());
        return;
    }
    if let Err(error) = run() {
        eprintln!(
            "{}",
            json!({"event":"worker_error","error":truncate(&error, 1024)})
        );
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let config = Config::from_env()?;
    let actual_hash = sha256_file(&config.model_path)?;
    if actual_hash != config.model_sha256 {
        return Err("local GGUF SHA-256 does not match OTLET_MODEL_SHA256".to_owned());
    }
    let threads = std::env::var("OTLET_LLAMA_THREADS")
        .ok()
        .and_then(|value| value.parse::<i32>().ok())
        .filter(|value| *value > 0)
        .unwrap_or_else(|| {
            i32::try_from(
                std::thread::available_parallelism()
                    .map(std::num::NonZero::get)
                    .unwrap_or(4)
                    .min(6),
            )
            .unwrap_or(4)
        });
    let mut model = LocalModel::load(&config.model_path, threads)?;
    let database = Database {
        url: config.database_url.clone(),
        psql: config.psql.clone(),
    };
    log_worker("worker_started", &config, None);

    loop {
        let claims = database.claim(&config)?;
        for claim in &claims {
            if let Err(error) = process_claim(&database, &config, &mut model, claim) {
                log_event("job_error", claim, Some(&truncate(&error, 512)));
            }
        }
        if config.once {
            break;
        }
        std::thread::sleep(config.poll_interval);
    }
    log_worker("worker_stopped", &config, None);
    Ok(())
}

fn log_event(event: &str, claim: &Claim, reason: Option<&str>) {
    eprintln!(
        "{}",
        json!({
            "event": event,
            "job_id": claim.job_id,
            "task_name": claim.task_name,
            "reason": reason
        })
    );
}

fn log_worker(event: &str, config: &Config, reason: Option<&str>) {
    eprintln!(
        "{}",
        json!({
            "event": event,
            "worker_id": config.worker_id,
            "model_name": config.model_name,
            "protocol_version": config.protocol_version,
            "reason": reason
        })
    );
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|err| format!("could not open local GGUF: {err}"))?;
    let mut digest = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|err| format!("could not read local GGUF: {err}"))?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

fn sql_text(value: &str) -> String {
    let mut hex = String::with_capacity(value.len() * 2);
    for byte in value.as_bytes() {
        use std::fmt::Write as _;
        let _ = write!(hex, "{byte:02x}");
    }
    format!("convert_from(decode('{hex}', 'hex'), 'UTF8')")
}

fn env_required(name: &str) -> Result<String, String> {
    std::env::var(name).map_err(|_| format!("{name} is required"))
}

fn env_bool(name: &str) -> Option<bool> {
    match std::env::var(name).ok()?.as_str() {
        "1" | "true" | "on" | "yes" => Some(true),
        "0" | "false" | "off" | "no" => Some(false),
        _ => None,
    }
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn truncate(value: &str, limit: usize) -> String {
    value.chars().take(limit).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_completion_handles_split_escapes() {
        let mut completion = JsonCompletion::new();
        assert_eq!(completion.observe(br#" {"value":"a\"#), None);
        assert_eq!(completion.observe(br#""b"}"#), Some(17));
    }

    #[test]
    fn sql_text_contains_only_hex_payload() {
        assert_eq!(
            sql_text("a'\n🙂"),
            "convert_from(decode('61270af09f9982', 'hex'), 'UTF8')"
        );
    }
}
