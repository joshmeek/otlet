use serde_json::{Value, json};

pub(crate) struct RuntimeOptions {
    pub(crate) reasoning: String,
    pub(crate) max_tokens: u64,
    pub(crate) inference_cache: bool,
    pub(crate) max_worker_rss_bytes: u64,
    pub(crate) generation_trace: bool,
    pub(crate) generation_trace_max_tokens: u64,
    pub(crate) generation_trace_top_k: u64,
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
                | "inference_cache"
                | "max_worker_rss_bytes"
                | "generation_trace"
                | "generation_trace_max_tokens"
                | "generation_trace_top_k"
        ) {
            return Err(format!("unsupported runtime option: {key}"));
        }
    }

    if let Some(value) = object.get("reasoning") {
        let reasoning = value
            .as_str()
            .ok_or("runtime_options.reasoning must be a string")?;
        if !matches!(reasoning, "on" | "off" | "auto") {
            return Err("runtime_options.reasoning must be on, off, or auto".to_owned());
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
        "inference_cache",
        "max_worker_rss_bytes",
        "generation_trace",
        "generation_trace_max_tokens",
        "generation_trace_top_k",
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
