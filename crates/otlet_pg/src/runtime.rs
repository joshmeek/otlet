use serde_json::{Value, json};

pub(crate) struct RuntimeOptions {
    pub(crate) reasoning: String,
    pub(crate) max_tokens: u64,
    pub(crate) inference_cache: bool,
    pub(crate) max_worker_rss_bytes: u64,
    pub(crate) generation_trace: bool,
    pub(crate) generation_trace_max_tokens: u64,
    pub(crate) generation_trace_top_k: u64,
    pub(crate) llama_threads: u64,
    pub(crate) llama_batch_threads: u64,
}

impl Default for RuntimeOptions {
    fn default() -> Self {
        Self {
            reasoning: "off".to_owned(),
            max_tokens: 512,
            inference_cache: true,
            max_worker_rss_bytes: 0,
            generation_trace: false,
            generation_trace_max_tokens: 64,
            generation_trace_top_k: 5,
            llama_threads: 0,
            llama_batch_threads: 0,
        }
    }
}

pub(crate) fn parse_runtime_options(value: &Value) -> Result<RuntimeOptions, String> {
    let object = value
        .as_object()
        .ok_or("runtime_options must be an object")?;
    let mut options = RuntimeOptions::default();

    for key in object.keys() {
        if !matches!(
            key.as_str(),
            "reasoning"
                | "max_tokens"
                | "max_attempt_ms"
                | "inference_cache"
                | "max_worker_rss_bytes"
                | "generation_trace"
                | "generation_trace_max_tokens"
                | "generation_trace_top_k"
                | "llama_threads"
                | "llama_batch_threads"
        ) {
            return Err(format!("unsupported runtime option: {key}"));
        }
    }

    if let Some(value) = object.get("reasoning") {
        let reasoning = value
            .as_str()
            .ok_or("runtime_options.reasoning must be a string")?;
        if !matches!(reasoning, "on" | "off") {
            return Err("runtime_options.reasoning must be on or off".to_owned());
        }
        options.reasoning = reasoning.to_owned();
    }

    if let Some(value) = object.get("max_tokens") {
        let max_tokens = value
            .as_u64()
            .ok_or("runtime_options.max_tokens must be an integer")?;
        if !(1..=4096).contains(&max_tokens) {
            return Err("runtime_options.max_tokens must be between 1 and 4096".to_owned());
        }
        options.max_tokens = max_tokens;
    }

    if let Some(value) = object.get("max_attempt_ms") {
        let valid_string = value
            .as_str()
            .is_some_and(|raw| !raw.is_empty() && raw.chars().all(|ch| ch.is_ascii_digit()));
        if value.as_u64().is_none() && !valid_string {
            return Err("runtime_options.max_attempt_ms must be a non-negative integer".to_owned());
        }
    }

    if let Some(value) = object.get("inference_cache") {
        options.inference_cache = value
            .as_bool()
            .ok_or("runtime_options.inference_cache must be a boolean")?;
    }

    if let Some(value) = object.get("max_worker_rss_bytes") {
        let max_worker_rss_bytes = value
            .as_u64()
            .ok_or("runtime_options.max_worker_rss_bytes must be an integer")?;
        if max_worker_rss_bytes > 70_368_744_177_664 {
            return Err(
                "runtime_options.max_worker_rss_bytes must be between 0 and 70368744177664"
                    .to_owned(),
            );
        }
        #[cfg(not(target_os = "linux"))]
        if max_worker_rss_bytes > 0 {
            return Err(
                "runtime_options.max_worker_rss_bytes is supported only on linux; use 0".to_owned(),
            );
        }
        options.max_worker_rss_bytes = max_worker_rss_bytes;
    }

    if let Some(value) = object.get("generation_trace") {
        options.generation_trace = value
            .as_bool()
            .ok_or("runtime_options.generation_trace must be a boolean")?;
    }

    if let Some(value) = object.get("generation_trace_max_tokens") {
        let max_tokens = value
            .as_u64()
            .ok_or("runtime_options.generation_trace_max_tokens must be an integer")?;
        if max_tokens > 256 {
            return Err(
                "runtime_options.generation_trace_max_tokens must be between 0 and 256".to_owned(),
            );
        }
        options.generation_trace_max_tokens = max_tokens;
    }

    if let Some(value) = object.get("generation_trace_top_k") {
        let top_k = value
            .as_u64()
            .ok_or("runtime_options.generation_trace_top_k must be an integer")?;
        if top_k > 16 {
            return Err(
                "runtime_options.generation_trace_top_k must be between 0 and 16".to_owned(),
            );
        }
        options.generation_trace_top_k = top_k;
    }

    if let Some(value) = object.get("llama_threads") {
        let threads = value
            .as_u64()
            .ok_or("runtime_options.llama_threads must be an integer")?;
        if threads > 1024 {
            return Err("runtime_options.llama_threads must be between 0 and 1024".to_owned());
        }
        options.llama_threads = threads;
    }

    if let Some(value) = object.get("llama_batch_threads") {
        let threads = value
            .as_u64()
            .ok_or("runtime_options.llama_batch_threads must be an integer")?;
        if threads > 1024 {
            return Err(
                "runtime_options.llama_batch_threads must be between 0 and 1024".to_owned(),
            );
        }
        options.llama_batch_threads = threads;
    }

    Ok(options)
}

pub(crate) fn runtime_option_status(value: &Value) -> Value {
    let Some(object) = value.as_object() else {
        return json!({
            "policy": "runtime_options_must_be_json_object",
            "honored": [],
            "defaulted": [],
            "rejected": ["runtime_options"]
        });
    };
    let controls = [
        "reasoning",
        "max_tokens",
        "max_attempt_ms",
        "inference_cache",
        "max_worker_rss_bytes",
        "generation_trace",
        "generation_trace_max_tokens",
        "generation_trace_top_k",
        "llama_threads",
        "llama_batch_threads",
    ];
    let defaulted = controls
        .iter()
        .filter(|key| !object.contains_key(**key))
        .copied()
        .collect::<Vec<_>>();
    let honored = controls
        .iter()
        .filter(|key| object.contains_key(**key))
        .copied()
        .collect::<Vec<_>>();
    json!({
        "policy": "linked_runtime_rejects_unsupported_non_default_options_no_silent_ignore",
        "honored": honored,
        "defaulted": defaulted,
        "unsupported": ["temperature", "connect_timeout_ms", "request_timeout_ms"],
        "ignored": []
    })
}
