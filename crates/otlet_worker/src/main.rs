use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{
    Arc, Mutex, TryLockError,
    atomic::{AtomicBool, AtomicU8, Ordering},
};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const CONTEXT_TOKENS: u32 = 4096;
const BATCH_TOKENS: usize = 512;
const UBATCH_TOKENS: u32 = 128;
const MAX_TOKEN_PIECE_BYTES: usize = 16 * 1024;
const MAX_PSQL_REQUEST_BYTES: usize = 128 * 1024 * 1024;
const MAX_PSQL_STDOUT_BYTES: usize = 64 * 1024 * 1024;
const MAX_PSQL_STDERR_BYTES: usize = 64 * 1024;
const MAX_PSQL_RESULT_BYTES: usize = 32 * 1024 * 1024;
const PSQL_CONNECT_TIMEOUT_SECONDS: &str = "5";
const PSQL_QUERY_TIMEOUT: Duration = Duration::from_secs(30);
const PSQL_TERMINAL_TIMEOUT: Duration = Duration::from_secs(30);
const PSQL_POLL_INTERVAL: Duration = Duration::from_millis(10);
const LOAD_POLICY: &str = "eager_single_resident_model";
const DEVICE_POLICY: &str = "cpu_only_n_gpu_layers_0";
const RSS_POLICY: &str = "linux_proc_status_vmrss_fail_closed";
const LLAMA_CPP_SYS_VERSION: &str = "0.3.1";
const LLAMA_CPP_REVISION: &str = "94a220cd6";
const SUPPORTED_RUNTIME_OPTIONS: &[&str] = &[
    "reasoning",
    "max_tokens",
    "max_attempt_ms",
    "inference_cache",
    "max_worker_rss_bytes",
    "generation_trace",
    "llama_threads",
    "llama_batch_threads",
];
const CLAIM_ACTIVE: u8 = 0;
const CLAIM_CANCELED: u8 = 1;
const CLAIM_LOST: u8 = 2;
const CLAIM_TIMED_OUT: u8 = 3;

#[derive(Deserialize)]
struct Claim {
    job_id: i64,
    workload_revision_hash: String,
    claim_token: String,
    claim_status: String,
    selection_role: String,
    task_name: String,
    prompt: String,
    prompt_hash: String,
    runtime_options: Value,
    model: Value,
    evidence_limits: Value,
    #[serde(skip, default = "Instant::now")]
    attempt_deadline: Instant,
    #[serde(skip)]
    claim_rss_bytes: u64,
}

#[derive(Clone)]
struct Config {
    database_url: String,
    psql: String,
    worker_id: String,
    protocol_version: i32,
    runtime_identity_hash: String,
    incarnation_nonce: Option<String>,
    model_name: String,
    model_path: PathBuf,
    model_sha256: String,
    poll_interval: Duration,
    renew_interval: Duration,
    once: bool,
    preflight_only: bool,
    require_tls: bool,
    runtime_dir: PathBuf,
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
        let preflight_only = std::env::args().any(|arg| arg == "--preflight");
        let renew_ms = std::env::var("OTLET_PORTABLE_RENEW_MS")
            .ok()
            .map(|value| value.parse::<u64>())
            .transpose()
            .map_err(|_| "OTLET_PORTABLE_RENEW_MS must be an integer".to_owned())?
            .unwrap_or(1000)
            .clamp(100, 60_000);

        Ok(Self {
            database_url: passwordless_database_url(env_required("OTLET_DATABASE_URL")?)?,
            psql: std::env::var("OTLET_PSQL").unwrap_or_else(|_| "psql".to_owned()),
            worker_id: env_required("OTLET_PORTABLE_WORKER_ID")?,
            protocol_version,
            runtime_identity_hash,
            incarnation_nonce: None,
            model_name: env_required("OTLET_MODEL_NAME")?,
            model_path: PathBuf::from(env_required("OTLET_MODEL_PATH")?),
            model_sha256,
            poll_interval: Duration::from_millis(poll_ms),
            renew_interval: Duration::from_millis(renew_ms),
            once,
            preflight_only,
            require_tls: env_bool_default("OTLET_PORTABLE_REQUIRE_TLS", true)?,
            runtime_dir: PathBuf::from(
                std::env::var("OTLET_PORTABLE_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_owned()),
            ),
        })
    }
}

struct RuntimeOptions {
    max_tokens: usize,
    max_worker_rss_bytes: u64,
    llama_threads: i32,
    llama_batch_threads: i32,
}

impl RuntimeOptions {
    fn parse(value: &Value) -> Result<Self, String> {
        let object = value
            .as_object()
            .ok_or("runtime_options must be an object")?;
        for key in object.keys() {
            if !SUPPORTED_RUNTIME_OPTIONS.contains(&key.as_str()) {
                return Err(format!("unsupported runtime option: {key}"));
            }
        }

        if let Some(value) = object.get("reasoning") {
            match value.as_str() {
                Some("on" | "off") => {}
                Some(_) => return Err("runtime_options.reasoning must be on or off".to_owned()),
                None => return Err("runtime_options.reasoning must be a string".to_owned()),
            }
        }
        let max_tokens = bounded_runtime_integer(object, "max_tokens", 512, 1, 4096)?;
        if let Some(value) = object.get("max_attempt_ms") {
            let valid_string = value.as_str().is_some_and(|raw| {
                !raw.is_empty() && raw.bytes().all(|byte| byte.is_ascii_digit())
            });
            if value.as_u64().is_none() && !valid_string {
                return Err(
                    "runtime_options.max_attempt_ms must be a non-negative integer".to_owned(),
                );
            }
        }
        match object.get("inference_cache") {
            Some(Value::Bool(false)) => {}
            Some(Value::Bool(true)) | None => {
                return Err("runtime_options.inference_cache must be false".to_owned());
            }
            Some(_) => return Err("runtime_options.inference_cache must be a boolean".to_owned()),
        }
        let max_worker_rss_bytes =
            required_runtime_integer(object, "max_worker_rss_bytes", 1, 70_368_744_177_664)?;
        match object.get("generation_trace") {
            Some(Value::Bool(false)) | None => {}
            Some(Value::Bool(true)) => {
                return Err("runtime_options.generation_trace must be false".to_owned());
            }
            Some(_) => return Err("runtime_options.generation_trace must be a boolean".to_owned()),
        }
        let llama_threads = required_runtime_integer(object, "llama_threads", 1, 1024)? as i32;
        let llama_batch_threads =
            required_runtime_integer(object, "llama_batch_threads", 1, 1024)? as i32;

        Ok(Self {
            max_tokens: max_tokens as usize,
            max_worker_rss_bytes,
            llama_threads,
            llama_batch_threads,
        })
    }
}

fn required_runtime_integer(
    object: &serde_json::Map<String, Value>,
    name: &str,
    min: u64,
    max: u64,
) -> Result<u64, String> {
    if !object.contains_key(name) {
        return Err(format!("runtime_options.{name} is required"));
    }
    bounded_runtime_integer(object, name, min, min, max)
}

fn bounded_runtime_integer(
    object: &serde_json::Map<String, Value>,
    name: &str,
    default: u64,
    min: u64,
    max: u64,
) -> Result<u64, String> {
    let Some(value) = object.get(name) else {
        return Ok(default);
    };
    let value = value
        .as_u64()
        .ok_or_else(|| format!("runtime_options.{name} must be an integer"))?;
    if !(min..=max).contains(&value) {
        return Err(format!(
            "runtime_options.{name} must be between {min} and {max}"
        ));
    }
    Ok(value)
}

#[derive(Clone)]
struct Database {
    url: String,
    psql: String,
    child: Arc<Mutex<()>>,
}

impl Database {
    fn query(&self, sql: &str) -> Result<Vec<String>, String> {
        self.query_until(sql, Instant::now() + PSQL_QUERY_TIMEOUT)
    }

    fn command(&self) -> Command {
        let mut command = Command::new(&self.psql);
        command
            .args([
                "--no-psqlrc",
                "--no-password",
                "--quiet",
                "--tuples-only",
                "--no-align",
                "--set",
                "ON_ERROR_STOP=1",
            ])
            .arg("--dbname")
            .arg(&self.url)
            .env("PGCONNECT_TIMEOUT", PSQL_CONNECT_TIMEOUT_SECONDS);
        command
    }

    fn query_until(&self, sql: &str, deadline: Instant) -> Result<Vec<String>, String> {
        if sql.len() > MAX_PSQL_REQUEST_BYTES {
            return Err(coded(
                "database_request_too_large",
                "database request exceeds the portable byte limit",
            ));
        }
        let _child = loop {
            match self.child.try_lock() {
                Ok(child) => break child,
                Err(TryLockError::WouldBlock) => {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        return Err(database_request_timeout());
                    }
                    thread::sleep(PSQL_POLL_INTERVAL.min(remaining));
                }
                Err(TryLockError::Poisoned(_)) => {
                    return Err(coded(
                        "database_child_unavailable",
                        "database child process lock is poisoned",
                    ));
                }
            }
        };
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(database_request_timeout());
        }
        let statement_timeout_ms = u64::try_from(remaining.as_millis())
            .unwrap_or(u64::MAX)
            .max(1);
        let prefix = format!(
            "SET statement_timeout = {statement_timeout_ms};\nSET lock_timeout = {statement_timeout_ms};\n"
        );
        if prefix.len().saturating_add(sql.len()) > MAX_PSQL_REQUEST_BYTES {
            return Err(coded(
                "database_request_too_large",
                "database request exceeds the portable byte limit",
            ));
        }

        let mut child = self
            .command()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|err| format!("could not start psql: {err}"))?;
        let Some(mut stdin) = child.stdin.take() else {
            kill_and_reap(&mut child);
            return Err("psql stdin is unavailable".to_owned());
        };
        let Some(stdout) = child.stdout.take() else {
            kill_and_reap(&mut child);
            return Err("psql stdout is unavailable".to_owned());
        };
        let Some(stderr) = child.stderr.take() else {
            kill_and_reap(&mut child);
            return Err("psql stderr is unavailable".to_owned());
        };

        let (status, written, stdout, stderr, timed_out) = thread::scope(|scope| {
            let writer = scope.spawn(move || {
                stdin
                    .write_all(prefix.as_bytes())
                    .and_then(|()| stdin.write_all(sql.as_bytes()))
                    .map_err(|err| format!("could not write psql request: {err}"))
            });
            let stdout_reader =
                scope.spawn(move || read_bounded(stdout, MAX_PSQL_STDOUT_BYTES, "stdout"));
            let stderr_reader =
                scope.spawn(move || read_bounded(stderr, MAX_PSQL_STDERR_BYTES, "stderr"));
            let mut timed_out = false;
            let status = loop {
                match child.try_wait() {
                    Ok(Some(status)) => break Ok(status),
                    Ok(None) => {
                        let remaining = deadline.saturating_duration_since(Instant::now());
                        if remaining.is_zero() {
                            timed_out = true;
                            let _ = child.kill();
                            break child
                                .wait()
                                .map_err(|err| format!("could not reap psql: {err}"));
                        }
                        thread::sleep(PSQL_POLL_INTERVAL.min(remaining));
                    }
                    Err(err) => {
                        kill_and_reap(&mut child);
                        break Err(format!("could not wait for psql: {err}"));
                    }
                }
            };
            (
                status,
                writer
                    .join()
                    .map_err(|_| "psql stdin writer panicked".to_owned())
                    .and_then(|result| result),
                stdout_reader
                    .join()
                    .map_err(|_| "psql stdout reader panicked".to_owned())
                    .and_then(|result| result),
                stderr_reader
                    .join()
                    .map_err(|_| "psql stderr reader panicked".to_owned())
                    .and_then(|result| result),
                timed_out,
            )
        });
        if timed_out || Instant::now() >= deadline {
            return Err(database_request_timeout());
        }
        let status = status?;
        let stdout = stdout?;
        let stderr = stderr?;
        if !status.success() {
            let stderr = String::from_utf8_lossy(&stderr);
            let message = stderr.lines().next().unwrap_or("database request failed");
            return Err(format!("psql failed: {}", truncate(message, 512)));
        }
        written?;
        parse_rows(stdout, MAX_PSQL_RESULT_BYTES)
    }

    fn terminal_query(&self, sql: &str) -> Result<Vec<String>, String> {
        let deadline = Instant::now() + PSQL_TERMINAL_TIMEOUT;
        for attempt in 0..3 {
            match self.query_until(sql, deadline) {
                Ok(rows) => return Ok(rows),
                Err(error) if attempt < 2 && is_connection_error(&error) => {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        return Err(database_request_timeout());
                    }
                    thread::sleep(Duration::from_millis(200).min(remaining));
                }
                Err(error) => return Err(error),
            }
        }
        unreachable!()
    }

    fn heartbeat(
        &self,
        config: &Config,
        state: &str,
        model_status: Option<&str>,
        error_code: Option<&str>,
    ) -> Result<String, String> {
        let model_status = model_status.map_or_else(|| "NULL".to_owned(), sql_text);
        let error_code = error_code.map_or_else(|| "NULL".to_owned(), sql_text);
        let incarnation_nonce = config
            .incarnation_nonce
            .as_deref()
            .map_or_else(|| "NULL".to_owned(), sql_text);
        let sql = format!(
            "SELECT desired_state, registered_model_name, registered_model_artifact_hash, registered_model_artifact_bytes FROM otlet.portable_worker_heartbeat({}, {}, {}, {}, {}, {}, {});\n",
            sql_text(&config.worker_id),
            config.protocol_version,
            sql_text(&config.runtime_identity_hash),
            incarnation_nonce,
            sql_text(state),
            model_status,
            error_code
        );
        let rows = self.query(&sql)?;
        match rows.as_slice() {
            [row] => {
                let mut fields = row.split('|');
                let (
                    Some(state),
                    Some(model_name),
                    Some(artifact_hash),
                    Some(artifact_bytes),
                    None,
                ) = (
                    fields.next(),
                    fields.next(),
                    fields.next(),
                    fields.next(),
                    fields.next(),
                )
                else {
                    return Err(coded(
                        "database_contract_invalid",
                        "portable heartbeat returned an invalid row",
                    ));
                };
                validate_registered_model(config, model_name, artifact_hash, artifact_bytes)?;
                Ok(state.to_owned())
            }
            _ => Err(coded(
                "database_contract_invalid",
                "portable heartbeat returned an unexpected row count",
            )),
        }
    }

    fn start(&self, config: &Config) -> Result<(String, String), String> {
        let sql = format!(
            "SELECT incarnation_nonce, desired_state, registered_model_name, registered_model_artifact_hash, registered_model_artifact_bytes FROM otlet.portable_start_worker({}, {}, {});\n",
            sql_text(&config.worker_id),
            config.protocol_version,
            sql_text(&config.runtime_identity_hash)
        );
        let rows = self.query(&sql)?;
        let [row] = rows.as_slice() else {
            return Err(coded(
                "database_contract_invalid",
                "portable start returned an unexpected row count",
            ));
        };
        let mut fields = row.split('|');
        let (
            Some(incarnation_nonce),
            Some(state),
            Some(model_name),
            Some(artifact_hash),
            Some(artifact_bytes),
            None,
        ) = (
            fields.next(),
            fields.next(),
            fields.next(),
            fields.next(),
            fields.next(),
            fields.next(),
        )
        else {
            return Err(coded(
                "database_contract_invalid",
                "portable start returned an invalid row",
            ));
        };
        if !is_uuid(incarnation_nonce) {
            return Err(coded(
                "database_contract_invalid",
                "portable start returned an invalid incarnation nonce",
            ));
        }
        validate_registered_model(config, model_name, artifact_hash, artifact_bytes)?;
        Ok((incarnation_nonce.to_owned(), state.to_owned()))
    }

    fn preflight_contract(&self, config: &Config) -> Result<(), String> {
        let sql = format!(
            "WITH rpc AS (\
               SELECT count(*) AS functions, \
                      count(*) FILTER (WHERE p.prosecdef) AS definers, \
                      count(*) FILTER (WHERE p.proconfig @> ARRAY['search_path=pg_catalog, otlet, pg_temp']) AS fixed_paths, \
                      count(*) FILTER (WHERE pg_catalog.has_function_privilege(current_user, p.oid, 'EXECUTE')) AS executable \
               FROM pg_catalog.pg_proc p \
               JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace \
               WHERE n.nspname = 'otlet' \
                 AND p.proname IN (\
                   'portable_start_worker', 'portable_claim_jobs', 'portable_renew_job', 'portable_record_attempt', \
                   'portable_complete_job', 'portable_fail_job', 'portable_cancel_job', \
                   'portable_worker_heartbeat'\
                 )\
             ), protocol AS (\
               SELECT count(*) AS compatible \
               FROM otlet.portable_protocol_status \
               WHERE protocol_version = {} AND status = 'active'\
             ) \
             SELECT rpc.functions, rpc.definers, rpc.fixed_paths, rpc.executable, protocol.compatible \
             FROM rpc CROSS JOIN protocol;\n",
            config.protocol_version
        );
        match self.query(&sql)?.as_slice() {
            [row] if row == "8|8|8|8|1" => Ok(()),
            [row] if row.ends_with("|0") => Err(coded(
                "protocol_incompatible",
                "portable protocol version is not active",
            )),
            _ => Err(coded(
                "database_contract_missing",
                "portable worker functions or grants are incomplete",
            )),
        }
    }

    fn tls_active(&self) -> Result<bool, String> {
        let rows = self.query(
            "SELECT ssl::text FROM pg_catalog.pg_stat_ssl WHERE pid = pg_catalog.pg_backend_pid();\n",
        )?;
        Ok(rows.as_slice() == ["true"])
    }

    fn claim(&self, config: &Config, default_llama_threads: i32) -> Result<Vec<Claim>, String> {
        let attempt_start = Instant::now();
        let claim_rss_bytes = process_rss_bytes()?;
        let sql = format!(
            "SELECT jsonb_build_object(\
               'job_id', c.job_id, \
               'workload_revision_hash', c.workload_revision_hash, \
               'claim_token', c.claim_token, \
               'claim_status', c.claim_status, \
               'selection_role', c.selection_role, \
               'task_name', c.task_name, \
               'prompt', c.prompt, \
               'prompt_hash', c.prompt_hash, \
               'runtime_options', c.runtime_options, \
               'model', c.model, \
               'evidence_limits', c.evidence_limits\
             )::text \
             FROM otlet.portable_claim_jobs({}, {}, {}, {}, {}, {}, 1) c;\n",
            sql_text(&config.worker_id),
            config.protocol_version,
            sql_text(&config.runtime_identity_hash),
            sql_text(required_incarnation_nonce(config)?),
            claim_rss_bytes,
            default_llama_threads
        );
        self.query(&sql)?
            .into_iter()
            .map(|line| parse_claim(&line, attempt_start, claim_rss_bytes))
            .collect()
    }

    fn renew(
        &self,
        config: &Config,
        job_id: i64,
        claim_token: &str,
        timeout: Duration,
    ) -> Result<String, String> {
        let sql = format!(
            "SELECT job_status FROM otlet.portable_renew_job({}, {}, {}, {}, {}, {});\n",
            sql_text(&config.worker_id),
            config.protocol_version,
            sql_text(&config.runtime_identity_hash),
            sql_text(required_incarnation_nonce(config)?),
            job_id,
            sql_text(claim_token)
        );
        let rows = self.query_until(&sql, Instant::now() + timeout)?;
        match rows.as_slice() {
            [state] if state == "running" || state == "cancel_requested" => Ok(state.clone()),
            _ => Err(format!(
                "portable renewal returned unexpected state: {rows:?}"
            )),
        }
    }

    fn complete(
        &self,
        config: &Config,
        claim: &Claim,
        raw_output: &str,
        output: &Value,
        actions: &Value,
        trace_summary: &Value,
    ) -> Result<String, String> {
        let sql = format!(
            "SELECT job_status \
             FROM otlet.portable_complete_job(\
               {}, {}, {}, {}, {}, {}, {}::jsonb, {}, {}::jsonb, \
               prompt_hash => {}, trace_summary => {}::jsonb\
             );\n",
            sql_text(&config.worker_id),
            config.protocol_version,
            sql_text(&config.runtime_identity_hash),
            sql_text(required_incarnation_nonce(config)?),
            claim.job_id,
            sql_text(&claim.claim_token),
            sql_text(&output.to_string()),
            sql_text(raw_output),
            sql_text(&actions.to_string()),
            sql_text(&claim.prompt_hash),
            sql_text(&trace_summary.to_string())
        );
        let rows = self.terminal_query(&sql)?;
        match rows.as_slice() {
            [state] if state == "complete" || state == "canceled" || state == "queued" => {
                Ok(state.clone())
            }
            _ => Err(format!(
                "portable completion returned unexpected state: {rows:?}"
            )),
        }
    }

    fn fail(
        &self,
        config: &Config,
        claim: &Claim,
        error: &str,
        raw_output: Option<&str>,
        candidate_output: Option<&Value>,
        trace_summary: &Value,
    ) -> Result<String, String> {
        let raw = raw_output.map_or_else(|| "NULL".to_owned(), sql_text);
        let candidate = candidate_output
            .map(|output| format!("{}::jsonb", sql_text(&output.to_string())))
            .unwrap_or_else(|| "NULL".to_owned());
        let timeout = error == "attempt_timeout";
        let selection_reason = if timeout {
            sql_text("attempt_timeout")
        } else {
            "NULL".to_owned()
        };
        let mut trace_summary = trace_summary.clone();
        let trace = trace_summary
            .as_object_mut()
            .ok_or("portable trace summary must be an object")?;
        trace.insert(
            "schema_validation_status".to_owned(),
            Value::String("failed".to_owned()),
        );
        if timeout {
            trace.insert(
                "schema_force".to_owned(),
                Value::String("attempt_timeout_before_schema_validation".to_owned()),
            );
            trace.insert(
                "stop_reason".to_owned(),
                Value::String("attempt_timeout".to_owned()),
            );
        }
        let sql = format!(
            "SELECT job_status \
             FROM otlet.portable_fail_job(\
               {}, {}, {}, {}, {}, {}, {}, raw_output => {}, \
               prompt_hash => {}, schema_validation_status => 'failed', \
               trace_summary => {}::jsonb, selection_reason => {}, \
               candidate_output => {}\
             );\n",
            sql_text(&config.worker_id),
            config.protocol_version,
            sql_text(&config.runtime_identity_hash),
            sql_text(required_incarnation_nonce(config)?),
            claim.job_id,
            sql_text(&claim.claim_token),
            sql_text(error),
            raw,
            sql_text(&claim.prompt_hash),
            sql_text(&trace_summary.to_string()),
            selection_reason,
            candidate
        );
        let rows = self.terminal_query(&sql)?;
        match rows.as_slice() {
            [state] if state == "failed" || state == "canceled" || state == "queued" => {
                Ok(state.clone())
            }
            _ => Err(format!(
                "portable failure returned unexpected state: {rows:?}"
            )),
        }
    }

    fn cancel(&self, config: &Config, claim: &Claim) -> Result<(), String> {
        let sql = format!(
            "SELECT job_status FROM otlet.portable_cancel_job({}, {}, {}, {}, {}, {}, 'canceled before portable inference');\n",
            sql_text(&config.worker_id),
            config.protocol_version,
            sql_text(&config.runtime_identity_hash),
            sql_text(required_incarnation_nonce(config)?),
            claim.job_id,
            sql_text(&claim.claim_token)
        );
        let rows = self.terminal_query(&sql)?;
        if rows.as_slice() != ["canceled"] {
            return Err(format!(
                "portable cancellation returned unexpected state: {rows:?}"
            ));
        }
        Ok(())
    }
}

fn database_request_timeout() -> String {
    coded(
        "database_request_timeout",
        "database request exceeded its deadline",
    )
}

fn kill_and_reap(child: &mut std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn read_bounded(reader: impl Read, limit: usize, stream: &str) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    reader
        .take(u64::try_from(limit).unwrap_or(u64::MAX).saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|err| format!("could not read psql {stream}: {err}"))?;
    if bytes.len() > limit {
        return Err(coded(
            &format!("database_{stream}_too_large"),
            &format!("psql {stream} exceeds the portable byte limit"),
        ));
    }
    Ok(bytes)
}

fn parse_rows(stdout: Vec<u8>, limit: usize) -> Result<Vec<String>, String> {
    let stdout =
        String::from_utf8(stdout).map_err(|_| "psql returned non-UTF-8 output".to_owned())?;
    let mut result_bytes = 0_usize;
    let mut rows = Vec::new();
    for row in stdout
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        result_bytes = result_bytes.saturating_add(row.len());
        if result_bytes > limit {
            return Err(coded(
                "database_result_too_large",
                "database result exceeds the portable byte limit",
            ));
        }
        rows.push(row.to_owned());
    }
    Ok(rows)
}

fn required_incarnation_nonce(config: &Config) -> Result<&str, String> {
    config.incarnation_nonce.as_deref().ok_or_else(|| {
        coded(
            "worker_not_started",
            "portable worker incarnation has not started",
        )
    })
}

fn validate_registered_model(
    config: &Config,
    model_name: &str,
    artifact_hash: &str,
    artifact_bytes: &str,
) -> Result<(), String> {
    if model_name != config.model_name {
        return Err(coded(
            "model_not_allowlisted",
            "portable worker is registered for another model",
        ));
    }
    if artifact_hash != config.model_sha256 {
        return Err(coded(
            "model_hash_mismatch",
            "portable worker model hash does not match its registration",
        ));
    }
    let artifact_bytes = artifact_bytes.parse::<u64>().map_err(|_| {
        coded(
            "database_contract_invalid",
            "portable worker returned invalid model bytes",
        )
    })?;
    let local_bytes = std::fs::metadata(&config.model_path)
        .map_err(|_| {
            coded(
                "model_artifact_unreadable",
                "local GGUF metadata is unavailable",
            )
        })?
        .len();
    if artifact_bytes != local_bytes {
        return Err(coded(
            "model_artifact_size_mismatch",
            "portable worker model bytes do not match its registration",
        ));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ArtifactStamp {
    bytes: u64,
    modified_ms: u128,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
    #[cfg(unix)]
    changed_seconds: i64,
    #[cfg(unix)]
    changed_nanoseconds: i64,
}

impl ArtifactStamp {
    #[cfg(unix)]
    fn same_file(self, other: Self) -> bool {
        self.device == other.device && self.inode == other.inode
    }

    #[cfg(not(unix))]
    fn same_file(self, other: Self) -> bool {
        self == other
    }
}

#[derive(Debug)]
struct VerifiedArtifact {
    path: PathBuf,
    file: File,
    sha256: String,
    stamp: ArtifactStamp,
}

impl VerifiedArtifact {
    fn open(path: &Path) -> Result<Self, String> {
        let path_stamp = regular_artifact_stamp(path)?;
        let mut file = open_artifact(path).map_err(|_| {
            coded(
                "model_artifact_unreadable",
                "local GGUF could not be opened",
            )
        })?;
        let stamp = file
            .metadata()
            .map(|metadata| artifact_stamp(&metadata))
            .map_err(|_| {
                coded(
                    "model_artifact_unreadable",
                    "local GGUF metadata is unavailable",
                )
            })?;
        if stamp != path_stamp || regular_artifact_stamp(path)? != stamp {
            return Err(coded(
                "model_artifact_path_replaced",
                "local GGUF path changed while opening",
            ));
        }
        let sha256 = sha256_open_file(&mut file)?;
        file.rewind().map_err(|_| {
            coded(
                "model_artifact_unreadable",
                "local GGUF could not be rewound",
            )
        })?;
        let artifact = Self {
            path: path.to_path_buf(),
            file,
            sha256,
            stamp,
        };
        artifact.ensure_unchanged()?;
        Ok(artifact)
    }

    fn bytes(&self) -> u64 {
        self.stamp.bytes
    }

    #[cfg(target_os = "linux")]
    fn load_path(&self) -> Result<String, String> {
        use std::os::fd::AsRawFd;

        Ok(format!("/proc/self/fd/{}", self.file.as_raw_fd()))
    }

    #[cfg(not(target_os = "linux"))]
    fn load_path(&self) -> Result<String, String> {
        Err(coded(
            "model_artifact_descriptor_unavailable",
            "verified model loading requires Linux /proc",
        ))
    }

    fn ensure_unchanged(&self) -> Result<(), String> {
        let metadata = std::fs::symlink_metadata(&self.path).map_err(|_| {
            coded(
                "model_artifact_path_replaced",
                "local GGUF path disappeared after verification",
            )
        })?;
        if !metadata.file_type().is_file() {
            return Err(coded(
                "model_artifact_path_replaced",
                "local GGUF path was replaced after verification",
            ));
        }
        let path_stamp = artifact_stamp(&metadata);
        if !self.stamp.same_file(path_stamp) {
            return Err(coded(
                "model_artifact_path_replaced",
                "local GGUF path was replaced after verification",
            ));
        }
        let file_stamp = self
            .file
            .metadata()
            .map(|metadata| artifact_stamp(&metadata))
            .map_err(|_| {
                coded(
                    "model_artifact_changed_after_verification",
                    "verified local GGUF metadata is unavailable",
                )
            })?;
        if file_stamp != self.stamp || path_stamp != self.stamp {
            return Err(coded(
                "model_artifact_changed_after_verification",
                "local GGUF changed after verification",
            ));
        }
        Ok(())
    }
}

fn open_artifact(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(0o400000);
    }
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(0x100);
    }
    options.open(path)
}

fn regular_artifact_stamp(path: &Path) -> Result<ArtifactStamp, String> {
    let metadata = std::fs::symlink_metadata(path).map_err(|_| {
        coded(
            "model_artifact_unreadable",
            "local GGUF metadata is unavailable",
        )
    })?;
    if metadata.file_type().is_symlink() {
        return Err(coded(
            "model_artifact_symlink_rejected",
            "local GGUF path must not be a symlink",
        ));
    }
    if !metadata.file_type().is_file() {
        return Err(coded(
            "model_artifact_not_regular",
            "local GGUF path is not a regular file",
        ));
    }
    Ok(artifact_stamp(&metadata))
}

fn artifact_stamp(metadata: &std::fs::Metadata) -> ArtifactStamp {
    #[cfg(unix)]
    use std::os::unix::fs::MetadataExt;

    ArtifactStamp {
        bytes: metadata.len(),
        modified_ms: metadata
            .modified()
            .ok()
            .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
            .map_or(0, |duration| duration.as_millis()),
        #[cfg(unix)]
        device: metadata.dev(),
        #[cfg(unix)]
        inode: metadata.ino(),
        #[cfg(unix)]
        changed_seconds: metadata.ctime(),
        #[cfg(unix)]
        changed_nanoseconds: metadata.ctime_nsec(),
    }
}

fn sha256_open_file(file: &mut File) -> Result<String, String> {
    let mut digest = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|_| coded("model_artifact_unreadable", "local GGUF could not be read"))?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

struct LocalModel {
    model: *mut llama_cpp_sys_4::llama_model,
    context: *mut llama_cpp_sys_4::llama_context,
    vocab: *const llama_cpp_sys_4::llama_vocab,
    default_threads: i32,
    artifact: VerifiedArtifact,
    model_memory_bytes: u64,
    model_parameters: u64,
    context_window_tokens: u32,
    load_ms: u64,
    context_ms: u64,
}

impl LocalModel {
    fn load(artifact: VerifiedArtifact, threads: i32) -> Result<Self, String> {
        let path = CString::new(artifact.load_path()?)
            .map_err(|_| "model path contains a null byte".to_owned())?;
        artifact.ensure_unchanged()?;
        unsafe {
            llama_cpp_sys_4::llama_log_set(Some(discard_llama_log), std::ptr::null_mut());
            llama_cpp_sys_4::llama_backend_init();
        }
        let mut model_params = unsafe { llama_cpp_sys_4::llama_model_default_params() };
        model_params.n_gpu_layers = 0;
        let load_start = Instant::now();
        let model =
            unsafe { llama_cpp_sys_4::llama_model_load_from_file(path.as_ptr(), model_params) };
        let load_ms = u64::try_from(load_start.elapsed().as_millis()).unwrap_or(u64::MAX);
        if model.is_null() {
            artifact.ensure_unchanged()?;
            return Err("local GGUF model load failed".to_owned());
        }
        if let Err(error) = artifact.ensure_unchanged() {
            unsafe { llama_cpp_sys_4::llama_model_free(model) };
            return Err(error);
        }

        let mut context_params = unsafe { llama_cpp_sys_4::llama_context_default_params() };
        context_params.n_ctx = CONTEXT_TOKENS;
        context_params.n_batch = BATCH_TOKENS as u32;
        context_params.n_ubatch = UBATCH_TOKENS;
        context_params.n_threads = threads;
        context_params.n_threads_batch = threads;
        context_params.no_perf = true;
        let context_start = Instant::now();
        let context = unsafe { llama_cpp_sys_4::llama_init_from_model(model, context_params) };
        let context_ms = u64::try_from(context_start.elapsed().as_millis()).unwrap_or(u64::MAX);
        if context.is_null() {
            unsafe { llama_cpp_sys_4::llama_model_free(model) };
            return Err("local GGUF context start failed".to_owned());
        }
        let context_window_tokens = unsafe { llama_cpp_sys_4::llama_n_ctx(context) };
        if context_window_tokens != CONTEXT_TOKENS {
            unsafe {
                llama_cpp_sys_4::llama_free(context);
                llama_cpp_sys_4::llama_model_free(model);
            }
            return Err(format!(
                "local GGUF context is {context_window_tokens} tokens, expected {CONTEXT_TOKENS}"
            ));
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
            default_threads: threads,
            artifact,
            model_memory_bytes: unsafe { llama_cpp_sys_4::llama_model_size(model) },
            model_parameters: unsafe { llama_cpp_sys_4::llama_model_n_params(model) },
            context_window_tokens,
            load_ms,
            context_ms,
        })
    }

    fn infer(
        &mut self,
        prompt: &str,
        max_tokens: usize,
        max_output_bytes: usize,
        threads: i32,
        batch_threads: i32,
        signal: &ClaimSignal,
    ) -> Result<Inference, String> {
        self.artifact.ensure_unchanged()?;
        let _abort = AbortGuard::new(self.context, signal);
        unsafe {
            llama_cpp_sys_4::llama_set_n_threads(self.context, threads, batch_threads);
            let memory = llama_cpp_sys_4::llama_get_memory(self.context);
            if !memory.is_null() {
                llama_cpp_sys_4::llama_memory_clear(memory, true);
            }
        }
        let tokens = tokenize(self.vocab, prompt)?;
        signal.ensure_active()?;
        if tokens.is_empty() {
            return Err("prompt produced no tokens".to_owned());
        }
        if tokens.len().saturating_add(max_tokens) > self.context_window_tokens as usize {
            return Err(format!(
                "prompt and generation exceed the {}-token context",
                self.context_window_tokens
            ));
        }

        let mut batch = Batch::new(BATCH_TOKENS)?;
        let start = Instant::now();
        for (chunk_index, chunk) in tokens.chunks(BATCH_TOKENS).enumerate() {
            signal.ensure_active()?;
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
                signal.ensure_active()?;
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
            signal.ensure_active()?;
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
                signal.ensure_active()?;
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

unsafe extern "C" fn discard_llama_log(
    _level: llama_cpp_sys_4::ggml_log_level,
    _text: *const std::ffi::c_char,
    _user_data: *mut std::ffi::c_void,
) {
}

unsafe extern "C" fn abort_on_claim_change(data: *mut std::ffi::c_void) -> bool {
    let state = unsafe { &*data.cast::<ClaimState>() };
    state.value() != CLAIM_ACTIVE
}

struct AbortGuard<'a> {
    context: *mut llama_cpp_sys_4::llama_context,
    _signal: &'a ClaimSignal,
}

impl<'a> AbortGuard<'a> {
    fn new(context: *mut llama_cpp_sys_4::llama_context, signal: &'a ClaimSignal) -> Self {
        unsafe {
            llama_cpp_sys_4::llama_set_abort_callback(
                context,
                Some(abort_on_claim_change),
                Arc::as_ptr(&signal.state).cast_mut().cast(),
            );
        }
        Self {
            context,
            _signal: signal,
        }
    }
}

impl Drop for AbortGuard<'_> {
    fn drop(&mut self) {
        unsafe {
            llama_cpp_sys_4::llama_set_abort_callback(self.context, None, std::ptr::null_mut());
        }
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

#[derive(Clone)]
struct ClaimSignal {
    state: Arc<ClaimState>,
}

struct ClaimState {
    value: AtomicU8,
    deadline: Instant,
}

impl ClaimState {
    fn value(&self) -> u8 {
        if self.value.load(Ordering::Acquire) == CLAIM_ACTIVE && Instant::now() >= self.deadline {
            let _ = self.value.compare_exchange(
                CLAIM_ACTIVE,
                CLAIM_TIMED_OUT,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
        }
        self.value.load(Ordering::Acquire)
    }
}

impl ClaimSignal {
    fn new(deadline: Instant) -> Self {
        Self {
            state: Arc::new(ClaimState {
                value: AtomicU8::new(CLAIM_ACTIVE),
                deadline,
            }),
        }
    }

    fn set(&self, state: u8) {
        self.state.value();
        let _ = self.state.value.compare_exchange(
            CLAIM_ACTIVE,
            state,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
    }

    fn state(&self) -> u8 {
        self.state.value()
    }

    fn remaining(&self) -> Duration {
        self.state
            .deadline
            .saturating_duration_since(Instant::now())
    }

    fn ensure_active(&self) -> Result<(), String> {
        match self.state() {
            CLAIM_ACTIVE => Ok(()),
            CLAIM_CANCELED => Err("portable claim was canceled".to_owned()),
            CLAIM_LOST => Err("portable claim was lost".to_owned()),
            _ => Err("attempt_timeout".to_owned()),
        }
    }
}

struct LeaseGuard {
    signal: ClaimSignal,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl LeaseGuard {
    fn start(database: Database, config: Config, claim: &Claim) -> Self {
        let signal = ClaimSignal::new(claim.attempt_deadline);
        let thread_signal = signal.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let job_id = claim.job_id;
        let claim_token = claim.claim_token.clone();
        let task_name = claim.task_name.clone();
        let workload_revision_hash = claim.workload_revision_hash.clone();
        let handle = thread::spawn(move || {
            while !thread_stop.load(Ordering::Acquire) {
                let remaining = thread_signal.remaining();
                if remaining.is_zero() {
                    thread_signal.set(CLAIM_TIMED_OUT);
                    break;
                }
                thread::park_timeout(config.renew_interval.min(remaining));
                if thread_stop.load(Ordering::Acquire) {
                    break;
                }
                if thread_signal.state() == CLAIM_TIMED_OUT {
                    break;
                }
                let renew_timeout = PSQL_QUERY_TIMEOUT.min(thread_signal.remaining());
                if renew_timeout.is_zero() {
                    thread_signal.set(CLAIM_TIMED_OUT);
                    break;
                }
                match database.renew(&config, job_id, &claim_token, renew_timeout) {
                    Ok(state) if state == "cancel_requested" => {
                        thread_signal.set(CLAIM_CANCELED);
                        log_job(
                            "job_cancel_observed",
                            job_id,
                            &task_name,
                            &workload_revision_hash,
                            None,
                        );
                        break;
                    }
                    Ok(_) => {}
                    Err(error) => {
                        if error.contains("portable attempt deadline expired") {
                            thread_signal.set(CLAIM_TIMED_OUT);
                        } else {
                            thread_signal.set(CLAIM_LOST);
                        }
                        let timeout = thread_signal.state() == CLAIM_TIMED_OUT;
                        log_job(
                            if timeout {
                                "job_attempt_timed_out"
                            } else {
                                "job_claim_lost"
                            },
                            job_id,
                            &task_name,
                            &workload_revision_hash,
                            Some(if timeout {
                                "attempt_timeout"
                            } else if is_connection_error(&error) {
                                "database_unavailable"
                            } else {
                                "lease_renewal_rejected"
                            }),
                        );
                        break;
                    }
                }
            }
        });
        Self {
            signal,
            stop,
            handle: Some(handle),
        }
    }

    fn signal(&self) -> ClaimSignal {
        self.signal.clone()
    }
}

impl Drop for LeaseGuard {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(handle) = self.handle.take() {
            handle.thread().unpark();
            let _ = handle.join();
        }
    }
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

fn runtime_trace(
    claim: &Claim,
    model: &LocalModel,
    options: Option<&RuntimeOptions>,
    rss_before: Option<u64>,
    rss_after: Option<u64>,
    inference: Option<&Inference>,
) -> Value {
    let budget = options.map(|options| options.max_worker_rss_bytes);
    let final_rss = rss_after.or(rss_before).unwrap_or(claim.claim_rss_bytes);
    let admission_rss = claim.claim_rss_bytes.max(rss_before.unwrap_or(0));
    let (admission, admission_reason) = match (budget, rss_before) {
        (Some(budget), Some(_)) if admission_rss <= budget => {
            ("allowed", "loaded_worker_rss_within_job_budget")
        }
        (Some(_), Some(_)) => ("rejected", "observed_worker_rss_exceeds_job_budget"),
        (Some(_), None) => ("not_evaluated", "pre_inference_rss_not_recorded"),
        (None, _) => ("not_evaluated", "worker_memory_budget_unavailable"),
    };
    let (post_enforcement, post_enforcement_reason) = match (budget, rss_after) {
        (Some(budget), Some(rss)) if rss <= budget => {
            ("allowed", "post_inference_rss_within_job_budget")
        }
        (Some(_), Some(_)) => ("rejected", "post_inference_rss_exceeds_job_budget"),
        (Some(_), None) => ("not_evaluated", "post_inference_rss_not_recorded"),
        (None, _) => ("not_evaluated", "worker_memory_budget_unavailable"),
    };
    json!({
        "trace_version": "otlet_portable_worker_trace_v1",
        "workload_revision_hash": claim.workload_revision_hash,
        "prompt_hash": claim.prompt_hash,
        "prompt_tokens": inference.map(|inference| inference.prompt_tokens),
        "generated_tokens": inference.map(|inference| inference.generated_tokens),
        "generate_ms": inference.map(|inference| inference.generate_ms),
        "schema_validation_status": "not_run",
        "runtime": "local_llama_cpp",
        "runtime_fingerprint_version": "otlet_portable_runtime_contract_v1",
        "runtime_fingerprint": {
            "artifact": {
                "sha256": model.artifact.sha256.as_str(),
                "bytes": model.artifact.bytes(),
                "verification": "sha256_verified_file_descriptor_load"
            },
            "context": {
                "tokens": model.context_window_tokens,
                "batch_tokens": BATCH_TOKENS,
                "ubatch_tokens": UBATCH_TOKENS,
                "decode_threads": options.map(|options| options.llama_threads),
                "batch_threads": options.map(|options| options.llama_batch_threads)
            },
            "runtime": {
                "load_policy": LOAD_POLICY,
                "device_policy": DEVICE_POLICY,
                "rss_policy": RSS_POLICY
            }
        },
        "model_load_ms": 0,
        "model_context_ms": 0,
        "resident_model_load_ms": model.load_ms,
        "resident_model_context_ms": model.context_ms,
        "model_memory_bytes": model.model_memory_bytes,
        "model_parameters": model.model_parameters,
        "context_window_tokens": model.context_window_tokens,
        "model_device_policy": DEVICE_POLICY,
        "memory_accounting_policy": "linux_proc_status_vmrss_resident_model",
        "model_cache_hit": true,
        "inference_cache_hit": false,
        "effective_llama_threads": options.map(|options| options.llama_threads),
        "effective_llama_batch_threads": options.map(|options| options.llama_batch_threads),
        "worker_process_rss_bytes": final_rss,
        "worker_memory_sample_policy": RSS_POLICY,
        "worker_memory_budget_bytes": budget,
        "memory": {
            "worker_memory_sample_policy": RSS_POLICY,
            "worker_memory_budget_bytes": budget,
            "worker_memory_budget_policy": "max_worker_rss_bytes_fail_closed",
            "claim": { "process_rss_bytes": claim.claim_rss_bytes },
            "before": rss_before.map(|rss| json!({ "process_rss_bytes": rss })).unwrap_or_else(|| json!({})),
            "after": rss_after.map(|rss| json!({ "process_rss_bytes": rss })).unwrap_or_else(|| json!({})),
            "admission": {
                "decision": admission,
                "reason": admission_reason,
                "policy": "portable_claim_and_pre_inference_rss_v1"
            },
            "post_inference_enforcement": {
                "decision": post_enforcement,
                "reason": post_enforcement_reason,
                "policy": "max_worker_rss_bytes_fail_closed"
            }
        }
    })
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
    if !matches!(claim.selection_role.as_str(), "direct" | "cheap" | "strong") {
        return Err("portable claim selection role is invalid".to_owned());
    }
    let Some(selected_model) = claim.model.as_object() else {
        let trace = runtime_trace(claim, model, None, None, None, None);
        let state = database.fail(
            config,
            claim,
            "portable_model_identity_missing",
            None,
            None,
            &trace,
        )?;
        log_failure_state(&state, claim, "model_identity_missing");
        return Ok(());
    };
    let artifact_identity = selected_model
        .get("artifact_identity")
        .and_then(Value::as_object);
    if selected_model.get("name").and_then(Value::as_str) != Some(config.model_name.as_str())
        || selected_model.get("artifact_hash").and_then(Value::as_str)
            != Some(config.model_sha256.as_str())
        || artifact_identity
            .and_then(|identity| identity.get("sha256"))
            .and_then(Value::as_str)
            != Some(config.model_sha256.as_str())
        || artifact_identity
            .and_then(|identity| identity.get("bytes"))
            .and_then(Value::as_u64)
            != Some(model.artifact.bytes())
    {
        let trace = runtime_trace(claim, model, None, None, None, None);
        let state = database.fail(
            config,
            claim,
            "portable_model_identity_mismatch",
            None,
            None,
            &trace,
        )?;
        log_failure_state(&state, claim, "model_identity_mismatch");
        return Ok(());
    }
    let options = match RuntimeOptions::parse(&claim.runtime_options) {
        Ok(options) => options,
        Err(_) => {
            let trace = runtime_trace(claim, model, None, None, None, None);
            let state = database.fail(
                config,
                claim,
                "portable_runtime_options_rejected",
                None,
                None,
                &trace,
            )?;
            log_failure_state(&state, claim, "runtime_options_rejected");
            return Ok(());
        }
    };
    let max_output_bytes = claim
        .evidence_limits
        .get("max_raw_output_bytes")
        .and_then(Value::as_u64)
        .unwrap_or(1024 * 1024)
        .clamp(1, 16 * 1024 * 1024);
    let max_output_bytes = usize::try_from(max_output_bytes).unwrap_or(16 * 1024 * 1024);
    let rss_before = match process_rss_bytes() {
        Ok(rss) => rss,
        Err(_) => {
            let trace = runtime_trace(claim, model, Some(&options), None, None, None);
            let state = database.fail(
                config,
                claim,
                "portable_worker_rss_unavailable",
                None,
                None,
                &trace,
            )?;
            log_failure_state(&state, claim, "worker_rss_unavailable");
            return Ok(());
        }
    };
    if enforce_worker_rss_budget(rss_before, options.max_worker_rss_bytes).is_err() {
        let trace = runtime_trace(claim, model, Some(&options), Some(rss_before), None, None);
        let state = database.fail(
            config,
            claim,
            "portable_worker_rss_budget_exceeded",
            None,
            None,
            &trace,
        )?;
        log_failure_state(&state, claim, "worker_rss_budget_exceeded");
        return Ok(());
    }
    let lease = LeaseGuard::start(database.clone(), config.clone(), claim);
    let signal = lease.signal();
    let inference = model.infer(
        &claim.prompt,
        options.max_tokens,
        max_output_bytes,
        options.llama_threads,
        options.llama_batch_threads,
        &signal,
    );
    let inference_state = signal.state();
    drop(lease);
    let artifact_state = model.artifact.ensure_unchanged();
    match signal.state() {
        CLAIM_CANCELED => {
            database.cancel(config, claim)?;
            log_event("job_canceled", claim, Some("cancel_requested"));
            return Ok(());
        }
        CLAIM_LOST => {
            log_event("job_abandoned", claim, Some("claim_lost"));
            return Ok(());
        }
        CLAIM_TIMED_OUT if inference_state == CLAIM_TIMED_OUT => {
            let trace = runtime_trace(claim, model, Some(&options), Some(rss_before), None, None);
            let state = database.fail(config, claim, "attempt_timeout", None, None, &trace)?;
            log_failure_state(&state, claim, "attempt_timeout");
            return Ok(());
        }
        _ => {}
    }
    let inference = match artifact_state {
        Ok(()) => inference,
        Err(error) => Err(error),
    };
    let rss_after = match process_rss_bytes() {
        Ok(rss) => rss,
        Err(_) => {
            let trace = runtime_trace(
                claim,
                model,
                Some(&options),
                Some(rss_before),
                None,
                inference.as_ref().ok(),
            );
            let state = database.fail(
                config,
                claim,
                "portable_worker_rss_unavailable",
                None,
                None,
                &trace,
            )?;
            log_failure_state(&state, claim, "worker_rss_unavailable");
            return Ok(());
        }
    };
    let trace = runtime_trace(
        claim,
        model,
        Some(&options),
        Some(rss_before),
        Some(rss_after),
        inference.as_ref().ok(),
    );
    if enforce_worker_rss_budget(rss_after, options.max_worker_rss_bytes).is_err() {
        let state = database.fail(
            config,
            claim,
            "portable_worker_rss_budget_exceeded",
            None,
            None,
            &trace,
        )?;
        log_failure_state(&state, claim, "worker_rss_budget_exceeded");
        return Ok(());
    }
    let inference = match inference {
        Ok(inference) => inference,
        Err(error) => {
            let state =
                database.fail(config, claim, &truncate(&error, 1024), None, None, &trace)?;
            log_failure_state(&state, claim, "local_inference_failed");
            return Ok(());
        }
    };
    let envelope: Value = match serde_json::from_str(&inference.raw_output) {
        Ok(value) => value,
        Err(_) => {
            let state = database.fail(
                config,
                claim,
                "portable_model_output_invalid_json",
                Some(&inference.raw_output),
                None,
                &trace,
            )?;
            log_failure_state(&state, claim, "invalid_model_json");
            return Ok(());
        }
    };
    let (Some(output), Some(actions)) = (envelope.get("output"), envelope.get("actions")) else {
        let state = database.fail(
            config,
            claim,
            "portable_model_output_invalid_envelope",
            Some(&inference.raw_output),
            None,
            &trace,
        )?;
        log_failure_state(&state, claim, "invalid_model_envelope");
        return Ok(());
    };
    match database.complete(
        config,
        claim,
        &inference.raw_output,
        output,
        actions,
        &trace,
    ) {
        Ok(state) if state == "complete" => log_event("job_completed", claim, None),
        Ok(state) if state == "queued" => {
            log_event("job_escalated", claim, Some("cheap_attempt_rejected"))
        }
        Ok(_) => log_event("job_canceled", claim, Some("cancel_requested")),
        Err(error) if is_connection_error(&error) => {
            log_event(
                "job_terminal_uncertain",
                claim,
                Some("database_unavailable"),
            );
        }
        Err(error) if is_claim_loss(&error) => {
            log_event("job_abandoned", claim, Some("claim_lost"));
        }
        Err(_) => {
            let state = database.fail(
                config,
                claim,
                "portable_result_rejected_by_database",
                Some(&inference.raw_output),
                Some(output),
                &trace,
            )?;
            log_failure_state(&state, claim, "database_validation_failed");
        }
    }
    Ok(())
}

fn log_failure_state(state: &str, claim: &Claim, reason: &str) {
    if state == "queued" {
        log_event("job_escalated", claim, Some(reason));
    } else if state == "canceled" {
        log_event("job_canceled", claim, Some("cancel_requested"));
    } else {
        log_event("job_failed", claim, Some(reason));
    }
}

fn runtime_identity() -> Value {
    json!({
        "engine": "llama.cpp",
        "protocol_version": 1,
        "runtime_contract": {
            "version": "otlet_runtime_capabilities_v1",
            "supported_runtime_options": SUPPORTED_RUNTIME_OPTIONS,
            "schema_behavior": {
                "input": "postgres_jsonb_shaped_snapshot",
                "response": "json_object_output_actions_envelope",
                "decode_constraint": "greedy_balanced_json_object_then_database_validation",
                "validation": "postgres_authoritative_json_schema_subset",
                "unsupported_schema": "rejected_at_task_registration",
                "supported_types": [
                    "object", "array", "string", "number", "integer", "boolean", "null"
                ],
                "supported_keywords": [
                    "$schema", "$id", "title", "description", "default", "examples",
                    "type", "enum", "const", "required", "properties",
                    "additionalProperties", "items", "minLength", "maxLength", "minimum",
                    "maximum", "exclusiveMinimum", "exclusiveMaximum", "minItems",
                    "maxItems", "minProperties", "maxProperties"
                ],
                "additional_properties": "boolean_only",
                "items": "one_schema"
            },
            "context_limits": {
                "context_window_tokens": CONTEXT_TOKENS,
                "batch_tokens": BATCH_TOKENS,
                "ubatch_tokens": UBATCH_TOKENS,
                "max_generation_tokens": 4096
            },
            "cancellation": {
                "policy": "claim_signal_before_inference_and_llama_abort_during_decode_generation",
                "claim_loss": "authoritative",
                "attempt_deadline": "monotonic_worker_and_database_deadline"
            },
            "tracing": {
                "summary": "otlet_portable_worker_trace_v1",
                "generation_trace": "unsupported_must_be_false",
                "raw_prompt_storage": "none"
            },
            "artifact_formats": {
                "accepted": ["gguf"],
                "verification": "sha256_verified_open_regular_file_descriptor",
                "symlinks": "rejected"
            },
            "runtime_build": {
                "engine": "llama.cpp",
                "crate": "llama-cpp-sys-4",
                "crate_version": LLAMA_CPP_SYS_VERSION,
                "revision": LLAMA_CPP_REVISION,
                "features": {
                    "native": cfg!(feature = "native"),
                    "openmp": cfg!(feature = "openmp")
                }
            },
            "device_settings": {
                "policy": DEVICE_POLICY,
                "gpu_layers": 0,
                "load_policy": LOAD_POLICY
            },
            "resource_admission": {
                "budget_option": "max_worker_rss_bytes",
                "rss_policy": RSS_POLICY,
                "required_evidence": ["current_rss_bytes", "artifact_bytes"],
                "process_slots": 1
            }
        },
        "transport": "postgres_psql",
        "worker": "otlet-portable-worker",
        "worker_version": env!("CARGO_PKG_VERSION")
    })
}

fn deployment_preflight(
    database: &Database,
    config: &Config,
) -> Result<(String, VerifiedArtifact), String> {
    check_runtime_dir(&config.runtime_dir)?;

    let desired = database.heartbeat(config, "starting", Some("verifying"), None)?;
    database.preflight_contract(config)?;
    if config.require_tls && !database.tls_active()? {
        return Err(coded(
            "tls_not_active",
            "database connection did not negotiate TLS",
        ));
    }

    let artifact = VerifiedArtifact::open(&config.model_path)?;
    if artifact.sha256 != config.model_sha256 {
        return Err(coded(
            "model_hash_mismatch",
            "local GGUF SHA-256 does not match OTLET_MODEL_SHA256",
        ));
    }
    Ok((desired, artifact))
}

fn check_runtime_dir(runtime_dir: &Path) -> Result<(), String> {
    if !runtime_dir.is_dir() {
        return Err(coded(
            "runtime_path_unwritable",
            "portable runtime directory does not exist",
        ));
    }
    let probe = runtime_dir.join(format!(
        ".otlet-preflight-{}-{}",
        std::process::id(),
        timestamp_ms()
    ));
    let result = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
        .and_then(|mut file| file.write_all(b"otlet preflight\n"))
        .and_then(|()| std::fs::remove_file(&probe));
    result.map_err(|_| {
        let _ = std::fs::remove_file(&probe);
        coded(
            "runtime_path_unwritable",
            "portable runtime directory is not writable",
        )
    })
}

fn main() {
    if std::env::args().any(|arg| arg == "--print-runtime-identity") {
        println!("{}", runtime_identity());
        return;
    }
    let preflight_only = std::env::args().any(|arg| arg == "--preflight");
    if let Err(error) = run() {
        eprintln!(
            "{}",
            json!({
                "event": if preflight_only { "preflight_failed" } else { "worker_error" },
                "reason": error_code(&error),
                "timestamp_ms": timestamp_ms()
            })
        );
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut config = Config::from_env()?;
    let database = Database {
        url: config.database_url.clone(),
        psql: config.psql.clone(),
        child: Arc::new(Mutex::new(())),
    };
    let mut database_unavailable = false;
    let (_, verified_artifact) =
        deployment_preflight_until_available(&database, &config, &mut database_unavailable)?;
    log_preflight(&config);
    if config.preflight_only {
        database.heartbeat(&config, "stopped", Some("verified"), None)?;
        return Ok(());
    }
    let (incarnation_nonce, desired) = database.start(&config)?;
    config.incarnation_nonce = Some(incarnation_nonce);
    if desired == "draining" {
        database.heartbeat(&config, "drained", Some("verified"), None)?;
        log_worker("worker_drained", &config, None);
        return Ok(());
    }
    heartbeat_until_available(
        &database,
        &config,
        "starting",
        Some("loading"),
        &mut database_unavailable,
    )?;
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
    let mut model = match LocalModel::load(verified_artifact, threads) {
        Ok(model) => model,
        Err(error) => {
            let _ = database.heartbeat(&config, "error", Some("error"), Some(error_code(&error)));
            return Err(error);
        }
    };
    log_worker("worker_started", &config, None);

    loop {
        let desired = heartbeat_until_available(
            &database,
            &config,
            "idle",
            Some("ready"),
            &mut database_unavailable,
        )?;
        if desired == "paused" {
            database.heartbeat(&config, "paused", Some("ready"), None)?;
            log_worker("worker_paused", &config, None);
            if config.once {
                break;
            }
            thread::sleep(config.poll_interval);
            continue;
        }
        if desired == "draining" {
            database.heartbeat(&config, "drained", Some("ready"), None)?;
            log_worker("worker_drained", &config, None);
            return Ok(());
        }
        let claims = match database.claim(&config, model.default_threads) {
            Ok(claims) => claims,
            Err(error) if is_connection_error(&error) && !config.once => {
                if !database_unavailable {
                    log_worker("database_unavailable", &config, Some("claim_failed"));
                    database_unavailable = true;
                }
                thread::sleep(config.poll_interval);
                continue;
            }
            Err(error) => return Err(error),
        };
        for claim in &claims {
            if let Err(error) = process_claim(&database, &config, &mut model, claim) {
                log_event("job_error", claim, Some(error_code(&error)));
            }
        }
        if config.once {
            break;
        }
        thread::sleep(config.poll_interval);
    }
    let _ = database.heartbeat(&config, "stopped", Some("ready"), None);
    log_worker("worker_stopped", &config, None);
    Ok(())
}

fn deployment_preflight_until_available(
    database: &Database,
    config: &Config,
    unavailable: &mut bool,
) -> Result<(String, VerifiedArtifact), String> {
    loop {
        match deployment_preflight(database, config) {
            Ok(preflight) => {
                if *unavailable {
                    log_worker("database_recovered", config, None);
                    *unavailable = false;
                }
                return Ok(preflight);
            }
            Err(error) if !config.once && !config.preflight_only && is_connection_error(&error) => {
                if !*unavailable {
                    log_worker("database_unavailable", config, Some(error_code(&error)));
                    *unavailable = true;
                }
                thread::sleep(config.poll_interval);
            }
            Err(error) => {
                let reason = error_code(&error);
                let _ = database.heartbeat(config, "error", Some("error"), Some(reason));
                return Err(error);
            }
        }
    }
}

fn heartbeat_until_available(
    database: &Database,
    config: &Config,
    state: &str,
    model_status: Option<&str>,
    unavailable: &mut bool,
) -> Result<String, String> {
    loop {
        match database.heartbeat(config, state, model_status, None) {
            Ok(desired) => {
                if *unavailable {
                    log_worker("database_recovered", config, None);
                    *unavailable = false;
                }
                return Ok(desired);
            }
            Err(error) if is_connection_error(&error) && !config.once => {
                if !*unavailable {
                    log_worker("database_unavailable", config, Some("heartbeat_failed"));
                    *unavailable = true;
                }
                thread::sleep(config.poll_interval);
            }
            Err(error) => return Err(error),
        }
    }
}

fn log_event(event: &str, claim: &Claim, reason: Option<&str>) {
    log_job(
        event,
        claim.job_id,
        &claim.task_name,
        &claim.workload_revision_hash,
        reason,
    );
}

fn log_job(
    event: &str,
    job_id: i64,
    task_name: &str,
    workload_revision_hash: &str,
    reason: Option<&str>,
) {
    eprintln!(
        "{}",
        json!({
            "event": event,
            "job_id": job_id,
            "task_name": task_name,
            "workload_revision_hash": workload_revision_hash,
            "reason": reason,
            "timestamp_ms": timestamp_ms()
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
            "reason": reason,
            "timestamp_ms": timestamp_ms()
        })
    );
}

fn log_preflight(config: &Config) {
    eprintln!(
        "{}",
        json!({
            "event": "preflight_passed",
            "worker_id": config.worker_id,
            "model_name": config.model_name,
            "protocol_version": config.protocol_version,
            "tls_required": config.require_tls,
            "timestamp_ms": timestamp_ms()
        })
    );
}

fn timestamp_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn process_rss_bytes() -> Result<u64, String> {
    let status = std::fs::read_to_string("/proc/self/status").map_err(|_| {
        coded(
            "worker_rss_unavailable",
            "portable worker requires Linux /proc VmRSS",
        )
    })?;
    process_rss_bytes_from(&status).ok_or_else(|| {
        coded(
            "worker_rss_unavailable",
            "portable worker could not parse Linux /proc VmRSS",
        )
    })
}

fn process_rss_bytes_from(status: &str) -> Option<u64> {
    let mut fields = status
        .lines()
        .find_map(|line| line.strip_prefix("VmRSS:"))?
        .split_ascii_whitespace();
    let kib = fields.next()?.parse::<u64>().ok()?;
    (fields.next() == Some("kB") && fields.next().is_none()).then(|| kib.checked_mul(1024))?
}

fn enforce_worker_rss_budget(rss_bytes: u64, max_worker_rss_bytes: u64) -> Result<(), String> {
    if rss_bytes > max_worker_rss_bytes {
        return Err("portable_worker_rss_budget_exceeded".to_owned());
    }
    Ok(())
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

fn passwordless_database_url(url: String) -> Result<String, String> {
    let Some(rest) = url
        .strip_prefix("postgresql://")
        .or_else(|| url.strip_prefix("postgres://"))
    else {
        return Err("OTLET_DATABASE_URL must be a PostgreSQL URI".to_owned());
    };
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    if rest[..authority_end]
        .rsplit_once('@')
        .is_some_and(|(userinfo, _)| userinfo.contains(':'))
    {
        return Err(
            "OTLET_DATABASE_URL must not contain a password; use a libpq credential source"
                .to_owned(),
        );
    }
    if let Some(query) = url.split_once('?').map(|(_, query)| query) {
        for parameter in query.split('#').next().unwrap_or(query).split('&') {
            let name = parameter
                .split_once('=')
                .map_or(parameter, |(name, _)| name);
            let Some(name) = percent_decode(name) else {
                continue;
            };
            if name.eq_ignore_ascii_case(b"password") || name.eq_ignore_ascii_case(b"sslpassword") {
                return Err(
                    "OTLET_DATABASE_URL must not contain a password; use a libpq credential source"
                        .to_owned(),
                );
            }
            if name.eq_ignore_ascii_case(b"connect_timeout") {
                return Err(
                    "OTLET_DATABASE_URL must not set connect_timeout; the worker fixes it at 5 seconds"
                        .to_owned(),
                );
            }
        }
    }
    Ok(url)
}

fn percent_decode(value: &str) -> Option<Vec<u8>> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            decoded
                .push(hex_value(*bytes.get(index + 1)?)? * 16 + hex_value(*bytes.get(index + 2)?)?);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    Some(decoded)
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn env_bool(name: &str) -> Option<bool> {
    match std::env::var(name).ok()?.as_str() {
        "1" | "true" | "on" | "yes" => Some(true),
        "0" | "false" | "off" | "no" => Some(false),
        _ => None,
    }
}

fn env_bool_default(name: &str, default: bool) -> Result<bool, String> {
    match std::env::var(name) {
        Ok(_) => env_bool(name).ok_or_else(|| {
            coded(
                "configuration_invalid",
                &format!("{name} must be a boolean"),
            )
        }),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(_) => Err(coded(
            "configuration_invalid",
            &format!("{name} is not valid UTF-8"),
        )),
    }
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

fn is_identity_hash(value: &str) -> bool {
    value
        .strip_prefix("otlet:v1:sha256:")
        .is_some_and(is_sha256)
}

fn parse_claim(line: &str, attempt_start: Instant, claim_rss_bytes: u64) -> Result<Claim, String> {
    let mut claim: Claim = serde_json::from_str(line)
        .map_err(|err| format!("portable claim response is invalid: {err}"))?;
    if !is_identity_hash(&claim.workload_revision_hash) {
        return Err(coded(
            "database_contract_invalid",
            "portable claim workload revision hash is invalid",
        ));
    }
    let attempt_budget_ms = claim
        .evidence_limits
        .get("max_attempt_ms")
        .and_then(Value::as_u64)
        .filter(|value| (1..=3_600_000).contains(value))
        .ok_or_else(|| {
            coded(
                "database_contract_invalid",
                "portable claim attempt budget is invalid",
            )
        })?;
    claim.attempt_deadline = attempt_start
        .checked_add(Duration::from_millis(attempt_budget_ms))
        .ok_or_else(|| {
            coded(
                "database_contract_invalid",
                "portable claim attempt deadline overflowed",
            )
        })?;
    claim.claim_rss_bytes = claim_rss_bytes;
    Ok(claim)
}

fn is_connection_error(error: &str) -> bool {
    let error = error.to_ascii_lowercase();
    [
        "otlet_error:database_request_timeout:",
        "canceling statement due to lock timeout",
        "canceling statement due to statement timeout",
        "connection refused",
        "connection timed out",
        "timeout expired",
        "could not connect to server",
        "could not translate host name",
        "server closed the connection unexpectedly",
        "terminating connection due to administrator command",
        "the database system is starting up",
        "the database system is shutting down",
        "no route to host",
    ]
    .iter()
    .any(|needle| error.contains(needle))
}

fn is_claim_loss(error: &str) -> bool {
    let error = error.to_ascii_lowercase();
    error.contains("otlet_error:claim_lost:")
        || error.contains("claim is stale")
        || error.contains("claim token")
        || error.contains("belongs to another worker")
        || error.contains("identity is not authorized")
        || error.contains("incarnation")
}

fn coded(code: &str, message: &str) -> String {
    format!("otlet_error:{code}:{message}")
}

fn error_code(error: &str) -> &str {
    let lower = error.to_ascii_lowercase();
    if let Some((code, _)) = error
        .strip_prefix("otlet_error:")
        .and_then(|value| value.split_once(':'))
    {
        code
    } else if lower.contains("password authentication failed") {
        "credentials_rejected"
    } else if lower.contains("certificate") || lower.contains("ssl") {
        "tls_verification_failed"
    } else if lower.contains("identity is not authorized") {
        "runtime_not_allowlisted"
    } else if lower.contains("protocol version") && lower.contains("incompatible") {
        "protocol_incompatible"
    } else if lower.contains("permission denied") {
        "database_contract_denied"
    } else if lower.contains("could not start psql") {
        "psql_unavailable"
    } else if is_connection_error(error) {
        "database_unavailable"
    } else if is_claim_loss(error) {
        "claim_lost"
    } else if error.contains("GGUF") || error.contains("model") {
        "model_error"
    } else if error.contains("required") || error.contains("must be") {
        "configuration_error"
    } else if error.contains("psql") || error.contains("database") || error.contains("portable") {
        "database_rejected"
    } else {
        "worker_failed"
    }
}

fn truncate(value: &str, limit: usize) -> String {
    value.chars().take(limit).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::sync::{Barrier, atomic::AtomicU64};

    static TEST_DIRECTORY_ID: AtomicU64 = AtomicU64::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let id = TEST_DIRECTORY_ID.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "otlet-worker-test-{}-{}-{id}",
                std::process::id(),
                timestamp_ms()
            ));
            std::fs::create_dir(&path).expect("test directory should be created");
            Self(path)
        }

        fn path(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }

        #[cfg(unix)]
        fn script(&self, body: &str) -> PathBuf {
            let path = self.path("psql");
            std::fs::write(&path, format!("#!/bin/sh\n{body}\n"))
                .expect("fake psql should be written");
            let mut permissions = std::fs::metadata(&path)
                .expect("fake psql metadata should exist")
                .permissions();
            permissions.set_mode(0o700);
            std::fs::set_permissions(&path, permissions).expect("fake psql should be executable");
            path
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn test_database(psql: PathBuf, url: &str) -> Database {
        Database {
            url: url.to_owned(),
            psql: psql.to_string_lossy().into_owned(),
            child: Arc::new(Mutex::new(())),
        }
    }

    fn test_config(model_path: PathBuf) -> Config {
        Config {
            database_url: "postgresql://worker@database/app".to_owned(),
            psql: "psql".to_owned(),
            worker_id: "worker".to_owned(),
            protocol_version: 1,
            runtime_identity_hash: "a".repeat(64),
            incarnation_nonce: None,
            model_name: "model".to_owned(),
            model_path,
            model_sha256: "b".repeat(64),
            poll_interval: Duration::from_secs(1),
            renew_interval: Duration::from_secs(1),
            once: true,
            preflight_only: false,
            require_tls: false,
            runtime_dir: std::env::temp_dir(),
        }
    }

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

    #[test]
    fn connection_errors_are_classified_without_logging_details() {
        let error = "psql failed: connection to server failed: Connection refused";
        assert!(is_connection_error(error));
        assert_eq!(error_code(error), "database_unavailable");
        assert_eq!(
            error_code("psql failed: connection to server failed: timeout expired"),
            "database_unavailable"
        );
    }

    #[cfg(unix)]
    #[test]
    fn psql_uses_passwordless_url_and_fixed_connect_timeout() {
        let directory = TestDirectory::new();
        let psql = directory.script(
            r#"
[ "$PGCONNECT_TIMEOUT" = "5" ] || exit 92
case " $* " in
  *" --no-password "*) ;;
  *) exit 93 ;;
esac
cat >/dev/null
printf 'ok\n'
"#,
        );
        let url = "postgresql://worker@database/app";
        let database = test_database(psql, url);
        assert_eq!(database.query("SELECT 1;\n"), Ok(vec!["ok".to_owned()]));
        let command = database.command();
        assert!(
            command
                .get_args()
                .any(|argument| argument.to_string_lossy() == url)
        );
    }

    #[test]
    fn database_url_rejects_embedded_passwords() {
        assert!(passwordless_database_url("postgresql://worker@database/app".to_owned()).is_ok());
        for url in [
            "postgresql://worker:secret@database/app",
            "postgresql://worker@database/app?password=secret",
            "postgresql://worker@database/app?pass%77ord=secret",
            "postgresql://worker@database/app?sslpassword=secret",
            "postgresql://worker@database/app?sslpass%77ord=secret",
            "postgresql://worker@database/app?connect_timeout=3",
            "postgresql://worker@database/app?connect%5ftimeout=3",
        ] {
            assert!(passwordless_database_url(url.to_owned()).is_err());
        }
    }

    #[test]
    fn psql_stream_and_result_limits_fail_at_limit_plus_one() {
        assert_eq!(
            read_bounded(Cursor::new(b"abc"), 3, "stdout"),
            Ok(b"abc".to_vec())
        );
        let stdout_error = read_bounded(Cursor::new(b"abcd"), 3, "stdout")
            .expect_err("oversized stdout should fail");
        assert_eq!(error_code(&stdout_error), "database_stdout_too_large");
        let stderr_error = read_bounded(Cursor::new(b"abcd"), 3, "stderr")
            .expect_err("oversized stderr should fail");
        assert_eq!(error_code(&stderr_error), "database_stderr_too_large");
        assert_eq!(
            parse_rows(b"a\nbc\n".to_vec(), 3),
            Ok(vec!["a".to_owned(), "bc".to_owned()])
        );
        let result_error =
            parse_rows(b"a\nbc\n".to_vec(), 2).expect_err("oversized result should fail");
        assert_eq!(error_code(&result_error), "database_result_too_large");
    }

    #[cfg(unix)]
    #[test]
    fn stuck_psql_is_killed_and_reaped_at_the_deadline() {
        let directory = TestDirectory::new();
        let pid_path = directory.path("pid");
        let psql = directory.script(&format!(
            "printf '%s\\n' \"$$\" > '{}'\ncat >/dev/null\nwhile :; do :; done",
            pid_path.display()
        ));
        let database = test_database(psql, "postgresql://worker@database/app");
        let error = database
            .query_until("SELECT 1;\n", Instant::now() + Duration::from_millis(500))
            .expect_err("stuck psql should time out");
        assert_eq!(error_code(&error), "database_request_timeout");
        let pid = std::fs::read_to_string(pid_path)
            .expect("fake psql should record its pid")
            .trim()
            .to_owned();
        let running = Command::new("kill")
            .args(["-0", &pid])
            .stderr(Stdio::null())
            .status()
            .expect("kill probe should run")
            .success();
        assert!(!running, "timed-out psql should be reaped");
    }

    #[cfg(unix)]
    #[test]
    fn database_clones_share_one_child_slot() {
        let directory = TestDirectory::new();
        let lock_path = directory.path("child-lock");
        let overlap_path = directory.path("overlap");
        let psql = directory.script(&format!(
            "cat >/dev/null\nif mkdir '{}'; then\n  sleep 0.1\n  rmdir '{}'\n  printf 'ok\\n'\nelse\n  : > '{}'\n  exit 94\nfi",
            lock_path.display(),
            lock_path.display(),
            overlap_path.display()
        ));
        let database = test_database(psql, "postgresql://worker@database/app");
        let barrier = Arc::new(Barrier::new(3));
        let handles: Vec<_> = (0..2)
            .map(|_| {
                let database = database.clone();
                let barrier = Arc::clone(&barrier);
                thread::spawn(move || {
                    barrier.wait();
                    database.query_until("SELECT 1;\n", Instant::now() + Duration::from_secs(2))
                })
            })
            .collect();
        barrier.wait();
        for handle in handles {
            assert_eq!(
                handle.join().expect("database query thread should join"),
                Ok(vec!["ok".to_owned()])
            );
        }
        assert!(!overlap_path.exists(), "psql children should not overlap");
    }

    #[test]
    fn bounded_rpc_timeout_and_incarnation_errors_are_classified() {
        let timeout = database_request_timeout();
        assert!(is_connection_error(&timeout));
        assert_eq!(error_code(&timeout), "database_request_timeout");
        assert!(is_claim_loss(
            "psql failed: otlet portable worker incarnation is fenced"
        ));
        assert_eq!(
            error_code("psql failed: otlet portable worker incarnation is fenced"),
            "claim_lost"
        );
    }

    #[cfg(unix)]
    #[test]
    fn incarnation_rpc_sql_uses_null_before_start_and_nonce_after_start() {
        let directory = TestDirectory::new();
        let capture_path = directory.path("requests");
        let model_path = directory.path("model.gguf");
        std::fs::write(&model_path, b"model").expect("test model should be written");
        let nonce = "123e4567-e89b-12d3-a456-426614174000";
        let model_hash = "b".repeat(64);
        let psql = directory.script(&format!(
            r#"
request="$(cat)"
printf '%s\n--request--\n' "$request" >> '{}'
case "$request" in
  *portable_start_worker*) printf '{}|running|model|{}|5\n' ;;
  *portable_worker_heartbeat*) printf 'running|model|{}|5\n' ;;
  *) exit 95 ;;
esac
"#,
            capture_path.display(),
            nonce,
            model_hash,
            model_hash
        ));
        let database = test_database(psql, "postgresql://worker@database/app");
        let mut config = test_config(model_path);
        assert_eq!(
            database.heartbeat(&config, "starting", Some("verifying"), None),
            Ok("running".to_owned())
        );
        let (started_nonce, desired) = database.start(&config).expect("start should pass");
        assert_eq!(started_nonce, nonce);
        assert_eq!(desired, "running");
        config.incarnation_nonce = Some(started_nonce);
        assert_eq!(
            database.heartbeat(&config, "idle", Some("ready"), None),
            Ok("running".to_owned())
        );
        let requests = std::fs::read_to_string(capture_path)
            .expect("captured psql requests should be readable");
        let worker = sql_text(&config.worker_id);
        let runtime = sql_text(&config.runtime_identity_hash);
        assert!(requests.contains(&format!(
            "portable_worker_heartbeat({worker}, 1, {runtime}, NULL,"
        )));
        assert!(requests.contains(&format!("portable_start_worker({worker}, 1, {runtime})")));
        assert!(requests.contains(&format!(
            "portable_worker_heartbeat({worker}, 1, {runtime}, {},",
            sql_text(nonce)
        )));
        assert!(!requests.contains(nonce));
    }

    #[test]
    fn explicit_preflight_codes_survive_redaction() {
        assert_eq!(
            error_code(&coded(
                "model_hash_mismatch",
                "configured digest did not match"
            )),
            "model_hash_mismatch"
        );
        assert_eq!(
            error_code("psql: SSL error: certificate verify failed"),
            "tls_verification_failed"
        );
    }

    #[cfg(unix)]
    #[test]
    fn verified_artifact_rejects_symlinks_and_path_replacement() {
        use std::os::unix::fs::symlink;

        let directory = TestDirectory::new();
        let path = directory.path("model.gguf");
        let replacement = directory.path("replacement.gguf");
        let symlink_path = directory.path("symlink.gguf");
        let original = b"verified artifact";
        std::fs::write(&path, original).expect("model should be written");
        std::fs::write(&replacement, b"replacement bytes").expect("replacement should be written");
        symlink(&path, &symlink_path).expect("symlink should be created");

        let artifact = VerifiedArtifact::open(&path).expect("regular artifact should verify");
        let error =
            VerifiedArtifact::open(&symlink_path).expect_err("symlink artifact should be rejected");
        assert_eq!(error_code(&error), "model_artifact_symlink_rejected");

        std::fs::rename(replacement, &path).expect("artifact path should be replaced");
        let error = artifact
            .ensure_unchanged()
            .expect_err("path replacement should be rejected");
        assert_eq!(error_code(&error), "model_artifact_path_replaced");
        #[cfg(target_os = "linux")]
        assert_eq!(
            std::fs::read(artifact.load_path().expect("descriptor path should exist"))
                .expect("descriptor should remain readable"),
            original
        );
    }

    #[test]
    fn claim_signal_keeps_the_first_terminal_change() {
        let signal = ClaimSignal::new(Instant::now() + Duration::from_secs(1));
        signal.set(CLAIM_CANCELED);
        signal.set(CLAIM_LOST);
        assert_eq!(signal.state(), CLAIM_CANCELED);
    }

    #[test]
    fn claim_signal_expires_against_its_monotonic_deadline() {
        let signal = ClaimSignal::new(Instant::now() - Duration::from_millis(1));
        signal.set(CLAIM_LOST);
        assert_eq!(signal.state(), CLAIM_TIMED_OUT);
        assert_eq!(signal.ensure_active(), Err("attempt_timeout".to_owned()));
    }

    #[test]
    fn portable_claim_requires_versioned_revision_and_attempt_budget() {
        let mut claim = json!({
            "job_id": 1,
            "workload_revision_hash": format!("otlet:v1:sha256:{}", "a".repeat(64)),
            "claim_token": "token",
            "claim_status": "running",
            "selection_role": "direct",
            "task_name": "task",
            "prompt": "prompt",
            "prompt_hash": "prompt-hash",
            "runtime_options": {},
            "model": {},
            "evidence_limits": {"max_attempt_ms": 30000}
        });
        assert!(parse_claim(&claim.to_string(), Instant::now(), 4096).is_ok());

        claim["evidence_limits"] = json!({});
        let error = parse_claim(&claim.to_string(), Instant::now(), 4096)
            .err()
            .expect("missing attempt budget should be rejected");
        assert_eq!(error_code(&error), "database_contract_invalid");

        claim["evidence_limits"] = json!({"max_attempt_ms": 30000});
        claim["workload_revision_hash"] = json!("a".repeat(64));
        let error = parse_claim(&claim.to_string(), Instant::now(), 4096)
            .err()
            .expect("unversioned revision hash should be rejected");
        assert_eq!(error_code(&error), "database_contract_invalid");
    }

    #[test]
    fn portable_runtime_options_are_strict_and_keep_separate_threads() {
        let valid_options = || {
            json!({
                "reasoning": "off",
                "max_tokens": 16,
                "max_attempt_ms": "0",
                "inference_cache": false,
                "max_worker_rss_bytes": 1024,
                "generation_trace": false,
                "llama_threads": 3,
                "llama_batch_threads": 2
            })
        };
        let mut options = valid_options();
        let parsed = RuntimeOptions::parse(&options).expect("valid options must parse");
        assert_eq!(parsed.max_tokens, 16);
        assert_eq!(parsed.max_worker_rss_bytes, 1024);
        assert_eq!(parsed.llama_threads, 3);
        assert_eq!(parsed.llama_batch_threads, 2);

        let required = options.as_object_mut().expect("options are an object");
        required.remove("inference_cache");
        assert!(RuntimeOptions::parse(&options).is_err());
        options = valid_options();
        options
            .as_object_mut()
            .expect("options are an object")
            .remove("max_worker_rss_bytes");
        assert!(RuntimeOptions::parse(&options).is_err());
        options = valid_options();
        options
            .as_object_mut()
            .expect("options are an object")
            .remove("generation_trace");
        assert!(RuntimeOptions::parse(&options).is_ok());

        for (key, value) in [
            ("inference_cache", json!(true)),
            ("max_worker_rss_bytes", json!(0)),
            ("generation_trace", json!(true)),
            ("llama_threads", json!(0)),
            ("llama_batch_threads", json!(1025)),
        ] {
            options = valid_options();
            options[key] = value;
            assert!(RuntimeOptions::parse(&options).is_err());
        }
        options = valid_options();
        options["generation_trace_top_k"] = json!(5);
        assert!(RuntimeOptions::parse(&options).is_err());

        for key in ["llama_threads", "llama_batch_threads"] {
            options = valid_options();
            options
                .as_object_mut()
                .expect("options are an object")
                .remove(key);
            assert!(RuntimeOptions::parse(&options).is_err());
        }
    }

    #[test]
    fn portable_runtime_identity_has_the_fixed_contract() {
        let identity = runtime_identity();
        let contract = &identity["runtime_contract"];
        assert_eq!(contract["version"], "otlet_runtime_capabilities_v1");
        assert_eq!(
            contract["supported_runtime_options"],
            json!(SUPPORTED_RUNTIME_OPTIONS)
        );
        assert_eq!(contract["context_limits"]["context_window_tokens"], 4096);
        assert_eq!(contract["runtime_build"]["revision"], LLAMA_CPP_REVISION);
        for name in [
            "schema_behavior",
            "context_limits",
            "cancellation",
            "tracing",
            "artifact_formats",
            "runtime_build",
            "device_settings",
            "resource_admission",
        ] {
            assert!(contract[name].is_object(), "missing {name}");
        }
    }

    #[test]
    fn proc_status_vmrss_is_strictly_parsed() {
        assert_eq!(
            process_rss_bytes_from("Name:\totlet_worker\nVmRSS:\t1234 kB\n"),
            Some(1_263_616)
        );
        assert_eq!(process_rss_bytes_from("VmRSS:\t1234 bytes\n"), None);
    }
}
