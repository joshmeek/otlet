use sha2::{Digest, Sha256};
use std::io::{Read, Seek};

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
struct VerifiedArtifactCacheEntry {
    expected_sha256: String,
    stamp: ArtifactStamp,
}

#[derive(Debug)]
struct VerifiedArtifact {
    path: String,
    file: fs::File,
    sha256: String,
    stamp: ArtifactStamp,
    digest_cached: bool,
}

impl VerifiedArtifact {
    fn bytes(&self) -> u64 {
        self.stamp.bytes
    }

    fn sha256(&self) -> &str {
        &self.sha256
    }

    fn verify_digest(&mut self) -> Result<(), ModelError> {
        let actual_sha256 = sha256_gguf(&mut self.file)?;
        self.file.rewind().map_err(|error| {
            artifact_failure(
                format!("model artifact rewind failed: {error}"),
                "model_artifact_unreadable",
            )
        })?;
        if actual_sha256 != self.sha256 {
            return Err(artifact_failure(
                format!(
                    "model artifact SHA-256 mismatch: expected {}, found {actual_sha256}",
                    self.sha256
                ),
                "model_artifact_digest_mismatch",
            ));
        }
        self.digest_cached = false;
        self.ensure_unchanged()
    }

    #[cfg(target_os = "linux")]
    fn load_path(&self) -> Result<String, ModelError> {
        use std::os::fd::AsRawFd;

        Ok(format!("/proc/self/fd/{}", self.file.as_raw_fd()))
    }

    #[cfg(not(target_os = "linux"))]
    fn load_path(&self) -> Result<String, ModelError> {
        Err(artifact_failure(
            "verified model loading requires Linux /proc",
            "model_artifact_descriptor_unavailable",
        ))
    }

    fn ensure_unchanged(&self) -> Result<(), ModelError> {
        let path_stamp = regular_artifact_stamp(&self.path).map_err(|_| {
            artifact_failure(
                "model artifact path was replaced after verification",
                "model_artifact_path_replaced",
            )
        })?;
        if !self.stamp.same_file(path_stamp) {
            return Err(artifact_failure(
                "model artifact path was replaced after verification",
                "model_artifact_path_replaced",
            ));
        }
        let file_stamp = self.file.metadata().map(|metadata| artifact_stamp(&metadata)).map_err(
            |error| {
                artifact_failure(
                    format!("verified model artifact metadata failed: {error}"),
                    "model_artifact_changed_after_verification",
                )
            },
        )?;
        if file_stamp != self.stamp || path_stamp != self.stamp {
            return Err(artifact_failure(
                "model artifact changed after verification",
                "model_artifact_changed_after_verification",
            ));
        }
        Ok(())
    }
}

fn verify_model_artifact(model: JobModelRef<'_>) -> Result<VerifiedArtifact, ModelError> {
    let expected_sha256 = model.artifact_hash.trim();
    if expected_sha256.len() != 64
        || !expected_sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(artifact_failure(
            "model artifact SHA-256 is missing or invalid",
            "model_artifact_identity_invalid",
        ));
    }
    let expected_sha256 = expected_sha256.to_ascii_lowercase();
    if model.artifact_identity.get("sha256").and_then(Value::as_str)
        != Some(expected_sha256.as_str())
    {
        return Err(artifact_failure(
            "model artifact identity does not match its registered SHA-256",
            "model_artifact_identity_mismatch",
        ));
    }
    let expected_bytes = model
        .artifact_identity
        .get("bytes")
        .and_then(Value::as_u64)
        .filter(|bytes| *bytes >= 24)
        .ok_or_else(|| artifact_failure("model artifact byte size is invalid", "model_artifact_size_invalid"))?;
    let path_stamp = regular_artifact_stamp(model.artifact_path)?;
    let file = open_artifact(model.artifact_path).map_err(|error| {
        artifact_failure(
            format!("model artifact is unreadable: {error}"),
            "model_artifact_unreadable",
        )
    })?;
    let stamp = file.metadata().map(|metadata| artifact_stamp(&metadata)).map_err(|error| {
        artifact_failure(
            format!("model artifact metadata failed: {error}"),
            "model_artifact_unreadable",
        )
    })?;
    if stamp != path_stamp || regular_artifact_stamp(model.artifact_path)? != stamp {
        return Err(artifact_failure(
            "model artifact path changed while opening",
            "model_artifact_path_replaced",
        ));
    }
    if stamp.bytes != expected_bytes {
        return Err(artifact_failure(
            format!(
                "model artifact byte size mismatch: expected {expected_bytes}, found {}",
                stamp.bytes
            ),
            "model_artifact_size_mismatch",
        ));
    }

    static VERIFIED: OnceLock<Mutex<HashMap<String, VerifiedArtifactCacheEntry>>> = OnceLock::new();
    let cache = VERIFIED.get_or_init(|| Mutex::new(HashMap::with_capacity(4)));
    let cache_hit = cache.lock().ok().is_some_and(|cache| {
        cache.get(model.artifact_path).is_some_and(|verified| {
            verified.expected_sha256 == expected_sha256 && verified.stamp == stamp
        })
    });
    let mut verified = VerifiedArtifact {
        path: model.artifact_path.to_owned(),
        file,
        sha256: expected_sha256.clone(),
        stamp,
        digest_cached: cache_hit,
    };
    if cache_hit {
        verified.ensure_unchanged()?;
    } else {
        verified.verify_digest()?;
    }
    if let Ok(mut cache) = cache.lock() {
        if cache.len() >= 32 {
            cache.drain().next();
        }
        cache.insert(
            model.artifact_path.to_owned(),
            VerifiedArtifactCacheEntry {
                expected_sha256,
                stamp,
            },
        );
    }
    Ok(verified)
}

fn regular_artifact_stamp(path: &str) -> Result<ArtifactStamp, ModelError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        artifact_failure(
            format!("model artifact is unreadable: {error}"),
            "model_artifact_unreadable",
        )
    })?;
    if metadata.file_type().is_symlink() {
        return Err(artifact_failure(
            "model artifact path must not be a symlink",
            "model_artifact_symlink_rejected",
        ));
    }
    if !metadata.file_type().is_file() {
        return Err(artifact_failure(
            "model artifact path is not a regular file",
            "model_artifact_not_regular",
        ));
    }
    Ok(artifact_stamp(&metadata))
}

fn open_artifact(path: &str) -> std::io::Result<fs::File> {
    let mut options = fs::OpenOptions::new();
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

fn sha256_gguf(file: &mut fs::File) -> Result<String, ModelError> {
    let mut buffer = vec![0_u8; 1024 * 1024];
    let mut hasher = Sha256::new();
    let mut first = true;
    loop {
        let read = file.read(&mut buffer).map_err(|error| {
            artifact_failure(
                format!("model artifact read failed: {error}"),
                "model_artifact_unreadable",
            )
        })?;
        if read == 0 {
            break;
        }
        if first {
            if read < 4 || &buffer[..4] != b"GGUF" {
                return Err(artifact_failure(
                    "model artifact is not a GGUF file",
                    "model_artifact_malformed",
                ));
            }
            first = false;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn artifact_stamp(metadata: &fs::Metadata) -> ArtifactStamp {
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

fn artifact_failure(message: impl Into<String>, reason: &str) -> ModelError {
    ModelError::clean_failure(message, "model_artifact_sha256_verification", reason)
}

#[cfg(test)]
mod artifact_tests {
    use super::*;

    #[test]
    fn verifies_sha256_and_rejects_malformed_gguf() {
        let valid_path = std::env::temp_dir().join(format!(
            "otlet-artifact-{}-valid.gguf",
            std::process::id()
        ));
        fs::write(&valid_path, b"GGUF0123456789abcdefghij").unwrap();
        let identity = json!({
            "sha256": "e5bb1fee570b0488d28b735081054087bc81fcdc02795e6feeec0eaefc403994",
            "bytes": 24,
            "source": "test",
            "revision": "test",
            "quantization": "test",
            "license": "test"
        });
        let model = JobModelRef {
            name: "test",
            artifact_path: valid_path.to_str().unwrap(),
            artifact_hash: identity.get("sha256").and_then(Value::as_str).unwrap(),
            artifact_identity: &identity,
        };
        assert!(verify_model_artifact(model).is_ok());

        let malformed_path = std::env::temp_dir().join(format!(
            "otlet-artifact-{}-malformed.gguf",
            std::process::id()
        ));
        fs::write(&malformed_path, b"NOPE0123456789abcdefghij").unwrap();
        let malformed = JobModelRef {
            artifact_path: malformed_path.to_str().unwrap(),
            ..model
        };
        let error = verify_model_artifact(malformed).unwrap_err();
        assert_eq!(error.message, "model artifact is not a GGUF file");

        fs::remove_file(valid_path).unwrap();
        fs::remove_file(malformed_path).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlinks_and_replacement_after_verification() {
        use std::os::unix::fs::symlink;

        let directory = std::env::temp_dir().join(format!(
            "otlet-artifact-fence-{}-{}",
            std::process::id(),
            UNIX_EPOCH.elapsed().unwrap().as_nanos()
        ));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("model.gguf");
        let replacement = directory.join("replacement.gguf");
        let symlink_path = directory.join("symlink.gguf");
        let original = b"GGUF0123456789abcdefghij";
        fs::write(&path, original).unwrap();
        fs::write(&replacement, b"GGUF0123456789abcdefghik").unwrap();
        symlink(&path, &symlink_path).unwrap();
        let identity = json!({
            "sha256": "e5bb1fee570b0488d28b735081054087bc81fcdc02795e6feeec0eaefc403994",
            "bytes": 24,
            "source": "test",
            "revision": "test",
            "quantization": "test",
            "license": "test"
        });
        let model = JobModelRef {
            name: "test",
            artifact_path: path.to_str().unwrap(),
            artifact_hash: identity.get("sha256").and_then(Value::as_str).unwrap(),
            artifact_identity: &identity,
        };
        let verified = verify_model_artifact(model)
            .ok()
            .expect("regular artifact should verify");
        let symlink_model = JobModelRef {
            artifact_path: symlink_path.to_str().unwrap(),
            ..model
        };
        let error = verify_model_artifact(symlink_model).unwrap_err();
        assert_eq!(
            error.trace_summary.unwrap()["stop_reason"],
            "model_artifact_symlink_rejected"
        );

        fs::rename(replacement, &path).unwrap();
        let error = verified.ensure_unchanged().unwrap_err();
        assert_eq!(
            error.trace_summary.unwrap()["stop_reason"],
            "model_artifact_path_replaced"
        );
        #[cfg(target_os = "linux")]
        assert_eq!(fs::read(verified.load_path().unwrap()).unwrap(), original);

        fs::remove_dir_all(directory).unwrap();
    }
}
