fn elapsed_ms(start: Instant) -> i64 {
    i64::try_from(start.elapsed().as_millis()).unwrap_or(i64::MAX)
}

fn u64_to_i64_saturating(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn usize_to_i64_saturating(value: usize) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn u64_to_i32_saturating(value: u64) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

fn usize_to_i32_saturating(value: usize) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

fn usize_to_u32_saturating(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

const fn worker_memory_budget_policy(max_worker_rss_bytes: u64) -> &'static str {
    if max_worker_rss_bytes > 0 {
        "max_worker_rss_bytes_fail_closed_no_late_materialization"
    } else {
        "unbounded_worker_rss_reporting_only"
    }
}

fn enforce_worker_rss_budget(
    sample: &ProcessMemorySample,
    max_worker_rss_bytes: u64,
) -> Result<(), ModelError> {
    if max_worker_rss_bytes == 0 {
        return Ok(());
    }
    if sample.rss_bytes <= 0 {
        return Err(ModelError::clean_failure(
            format!(
                "linked worker RSS budget could not be enforced: rss sample unavailable policy={} max_worker_rss_bytes={}",
                sample.policy, max_worker_rss_bytes
            ),
            "worker_rss_budget_before_generation",
            "worker_rss_sample_unavailable",
        ));
    }
    if u64::try_from(sample.rss_bytes).unwrap_or(0) > max_worker_rss_bytes {
        return Err(ModelError::clean_failure(
            format!(
                "linked worker RSS budget exceeded: rss_bytes={} max_worker_rss_bytes={} policy={}",
                sample.rss_bytes,
                max_worker_rss_bytes,
                worker_memory_budget_policy(max_worker_rss_bytes)
            ),
            "worker_rss_budget_before_generation",
            "worker_rss_budget_exceeded",
        ));
    }
    Ok(())
}

#[derive(Clone, Default)]
struct ProcessMemorySample {
    rss_bytes: i64,
    virtual_bytes: i64,
    swap_bytes: i64,
    major_faults: i64,
    read_bytes: i64,
    system_memory_total_bytes: i64,
    system_memory_available_bytes: i64,
    system_swap_total_bytes: i64,
    system_swap_free_bytes: i64,
    memory_pressure_some_total_us: i64,
    memory_pressure_full_total_us: i64,
    memory_pressure_scope: &'static str,
    cgroup_memory_current_bytes: i64,
    cgroup_memory_max_bytes: i64,
    cgroup_swap_current_bytes: i64,
    cgroup_memory_high_events: i64,
    cgroup_memory_oom_events: i64,
    cgroup_memory_oom_kill_events: i64,
    policy: &'static str,
}

fn process_memory_sample() -> ProcessMemorySample {
    let status = fs::read_to_string("/proc/self/status").unwrap_or_default();
    let stat = fs::read_to_string("/proc/self/stat").unwrap_or_default();
    let io = fs::read_to_string("/proc/self/io").unwrap_or_default();
    let meminfo = fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let cgroup = fs::read_to_string("/proc/self/cgroup").unwrap_or_default();
    let cgroup_path = cgroup_v2_relative(&cgroup).map(|relative| {
        std::path::Path::new("/sys/fs/cgroup").join(relative.trim_start_matches('/'))
    });
    let cgroup_file = |name: &str| {
        cgroup_path
            .as_ref()
            .and_then(|path| fs::read_to_string(path.join(name)).ok())
    };
    let cgroup_pressure = cgroup_file("memory.pressure");
    let system_pressure = fs::read_to_string("/proc/pressure/memory").ok();
    let (pressure, memory_pressure_scope) = if let Some(pressure) = cgroup_pressure.as_deref() {
        (pressure, "cgroup_v2_memory_pressure")
    } else if let Some(pressure) = system_pressure.as_deref() {
        (pressure, "system_memory_pressure")
    } else {
        ("", "memory_pressure_unavailable")
    };
    let cgroup_events = cgroup_file("memory.events").unwrap_or_default();
    let rss_bytes = proc_kib(&status, "VmRSS:").unwrap_or(0);
    let virtual_bytes = proc_kib(&status, "VmSize:").unwrap_or(0);
    let policy = if rss_bytes > 0 && virtual_bytes > 0 {
        "linux_proc_self_and_optional_cgroup_v2_memory_pressure_v1"
    } else {
        "proc_self_status_unavailable_or_missing_vmrss_vmsize"
    };
    ProcessMemorySample {
        rss_bytes,
        virtual_bytes,
        swap_bytes: proc_kib(&status, "VmSwap:").unwrap_or(0),
        major_faults: proc_stat_major_faults(&stat).unwrap_or(0),
        read_bytes: keyed_i64(&io, "read_bytes:").unwrap_or(0),
        system_memory_total_bytes: proc_kib(&meminfo, "MemTotal:").unwrap_or(0),
        system_memory_available_bytes: proc_kib(&meminfo, "MemAvailable:").unwrap_or(0),
        system_swap_total_bytes: proc_kib(&meminfo, "SwapTotal:").unwrap_or(0),
        system_swap_free_bytes: proc_kib(&meminfo, "SwapFree:").unwrap_or(0),
        memory_pressure_some_total_us: psi_total_us(pressure, "some").unwrap_or(0),
        memory_pressure_full_total_us: psi_total_us(pressure, "full").unwrap_or(0),
        memory_pressure_scope,
        cgroup_memory_current_bytes: cgroup_file("memory.current")
            .as_deref()
            .and_then(parse_memory_value)
            .unwrap_or(0),
        cgroup_memory_max_bytes: cgroup_file("memory.max")
            .as_deref()
            .and_then(parse_memory_value)
            .unwrap_or(0),
        cgroup_swap_current_bytes: cgroup_file("memory.swap.current")
            .as_deref()
            .and_then(parse_memory_value)
            .unwrap_or(0),
        cgroup_memory_high_events: keyed_i64(&cgroup_events, "high").unwrap_or(0),
        cgroup_memory_oom_events: keyed_i64(&cgroup_events, "oom").unwrap_or(0),
        cgroup_memory_oom_kill_events: keyed_i64(&cgroup_events, "oom_kill").unwrap_or(0),
        policy,
    }
}

fn proc_kib(contents: &str, label: &str) -> Option<i64> {
    let line = contents.lines().find(|line| line.starts_with(label))?;
    let kib = line.split_whitespace().nth(1)?.parse::<u64>().ok()?;
    Some(u64_to_i64_saturating(kib.saturating_mul(1024)))
}

fn keyed_i64(contents: &str, key: &str) -> Option<i64> {
    let line = contents.lines().find(|line| line.starts_with(key))?;
    let value = line.split_whitespace().nth(1)?.parse::<u64>().ok()?;
    Some(u64_to_i64_saturating(value))
}

fn proc_stat_major_faults(stat: &str) -> Option<i64> {
    let (_, fields) = stat.rsplit_once(") ")?;
    let value = fields.split_whitespace().nth(9)?.parse::<u64>().ok()?;
    Some(u64_to_i64_saturating(value))
}

fn psi_total_us(contents: &str, kind: &str) -> Option<i64> {
    let line = contents
        .lines()
        .find(|line| line.split_whitespace().next() == Some(kind))?;
    let total = line
        .split_whitespace()
        .find_map(|field| field.strip_prefix("total="))?
        .parse::<u64>()
        .ok()?;
    Some(u64_to_i64_saturating(total))
}

fn cgroup_v2_relative(cgroup: &str) -> Option<&str> {
    cgroup.lines().find_map(|line| {
        let mut parts = line.splitn(3, ':');
        if parts.next()? == "0" && parts.next()?.is_empty() {
            parts.next()
        } else {
            None
        }
    })
}

fn parse_memory_value(value: &str) -> Option<i64> {
    let value = value.trim();
    if value == "max" {
        return Some(0);
    }
    Some(u64_to_i64_saturating(value.parse::<u64>().ok()?))
}

fn counter_delta(before: i64, after: i64) -> i64 {
    after.saturating_sub(before).max(0)
}

impl ProcessMemorySample {
    fn supports_preload_admission(&self) -> bool {
        self.rss_bytes > 0
            && self.system_memory_total_bytes > 0
            && self.system_memory_available_bytes > 0
    }

    fn as_json(&self) -> Value {
        json!({
            "process_rss_bytes": self.rss_bytes,
            "process_virtual_bytes": self.virtual_bytes,
            "process_swap_bytes": self.swap_bytes,
            "process_major_faults": self.major_faults,
            "process_read_bytes": self.read_bytes,
            "system_memory_total_bytes": self.system_memory_total_bytes,
            "system_memory_available_bytes": self.system_memory_available_bytes,
            "system_swap_total_bytes": self.system_swap_total_bytes,
            "system_swap_free_bytes": self.system_swap_free_bytes,
            "memory_pressure_some_total_us": self.memory_pressure_some_total_us,
            "memory_pressure_full_total_us": self.memory_pressure_full_total_us,
            "memory_pressure_scope": self.memory_pressure_scope,
            "cgroup_memory_current_bytes": self.cgroup_memory_current_bytes,
            "cgroup_memory_max_bytes": self.cgroup_memory_max_bytes,
            "cgroup_swap_current_bytes": self.cgroup_swap_current_bytes,
            "cgroup_memory_high_events": self.cgroup_memory_high_events,
            "cgroup_memory_oom_events": self.cgroup_memory_oom_events,
            "cgroup_memory_oom_kill_events": self.cgroup_memory_oom_kill_events,
            "sample_policy": self.policy
        })
    }
}

struct ModelLoadAdmission {
    decision: &'static str,
    reason: &'static str,
    policy: &'static str,
    artifact_bytes: i64,
    worker_budget_bytes: i64,
    worker_budget_headroom_bytes: i64,
    system_available_headroom_bytes: i64,
    cgroup_headroom_bytes: i64,
    allowed_additional_bytes: i64,
    projected_model_bytes: i64,
    projected_context_kv_bytes: i64,
    projected_batch_compute_bytes: i64,
    projected_total_bytes: i64,
    llama_projected_fit: bool,
}

impl ModelLoadAdmission {
    fn not_required(
        reason: &'static str,
        worker_budget_bytes: u64,
        sample: &ProcessMemorySample,
    ) -> Self {
        Self {
            decision: "not_required",
            reason,
            policy: "linked_llama_no_alloc_model_kv_batch_projection_v1",
            artifact_bytes: 0,
            worker_budget_bytes: u64_to_i64_saturating(worker_budget_bytes),
            worker_budget_headroom_bytes: u64_to_i64_saturating(worker_budget_bytes)
                .saturating_sub(sample.rss_bytes)
                .max(0),
            system_available_headroom_bytes: sample.system_memory_available_bytes,
            cgroup_headroom_bytes: cgroup_memory_headroom(sample),
            allowed_additional_bytes: 0,
            projected_model_bytes: 0,
            projected_context_kv_bytes: 0,
            projected_batch_compute_bytes: 0,
            projected_total_bytes: 0,
            llama_projected_fit: false,
        }
    }

    fn rejected(&self) -> bool {
        self.decision == "rejected"
    }

    fn as_json(&self) -> Value {
        json!({
            "decision": self.decision,
            "reason": self.reason,
            "policy": self.policy,
            "artifact_bytes": self.artifact_bytes,
            "worker_budget_bytes": self.worker_budget_bytes,
            "worker_budget_headroom_bytes": self.worker_budget_headroom_bytes,
            "system_available_headroom_bytes": self.system_available_headroom_bytes,
            "cgroup_headroom_bytes": self.cgroup_headroom_bytes,
            "allowed_additional_bytes": self.allowed_additional_bytes,
            "projected_model_bytes": self.projected_model_bytes,
            "projected_context_kv_bytes": self.projected_context_kv_bytes,
            "projected_batch_compute_bytes": self.projected_batch_compute_bytes,
            "projected_total_bytes": self.projected_total_bytes,
            "llama_projected_fit": self.llama_projected_fit
        })
    }
}

fn cgroup_memory_headroom(sample: &ProcessMemorySample) -> i64 {
    if sample.cgroup_memory_max_bytes > 0 {
        sample
            .cgroup_memory_max_bytes
            .saturating_sub(sample.cgroup_memory_current_bytes)
            .max(0)
    } else {
        0
    }
}

fn build_memory_trace(
    before: &ProcessMemorySample,
    after: &ProcessMemorySample,
    admission: &ModelLoadAdmission,
    max_worker_rss_bytes: u64,
) -> Value {
    json!({
        "model_device_policy": LINKED_MODEL_DEVICE_POLICY,
        "memory_accounting_policy": LINKED_MEMORY_ACCOUNTING_POLICY,
        "worker_memory_sample_policy": after.policy,
        "worker_memory_budget_bytes": u64_to_i64_saturating(max_worker_rss_bytes),
        "worker_memory_budget_policy": worker_memory_budget_policy(max_worker_rss_bytes),
        "before": before.as_json(),
        "after": after.as_json(),
        "delta": {
            "process_major_faults": counter_delta(before.major_faults, after.major_faults),
            "process_read_bytes": counter_delta(before.read_bytes, after.read_bytes),
            "memory_pressure_some_total_us": counter_delta(
                before.memory_pressure_some_total_us,
                after.memory_pressure_some_total_us
            ),
            "memory_pressure_full_total_us": counter_delta(
                before.memory_pressure_full_total_us,
                after.memory_pressure_full_total_us
            ),
            "cgroup_memory_high_events": counter_delta(
                before.cgroup_memory_high_events,
                after.cgroup_memory_high_events
            ),
            "cgroup_memory_oom_events": counter_delta(
                before.cgroup_memory_oom_events,
                after.cgroup_memory_oom_events
            ),
            "cgroup_memory_oom_kill_events": counter_delta(
                before.cgroup_memory_oom_kill_events,
                after.cgroup_memory_oom_kill_events
            )
        },
        "admission": admission.as_json()
    })
}

