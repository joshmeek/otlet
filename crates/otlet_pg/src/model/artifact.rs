use sha2::{Digest, Sha256};
use std::io::{BufReader, Read};

#[derive(Clone, Copy, PartialEq, Eq)]
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

struct VerifiedArtifact {
    expected_sha256: String,
    stamp: ArtifactStamp,
}

fn verify_model_artifact(model: JobModelRef<'_>) -> Result<(), ModelError> {
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
    let metadata = fs::metadata(model.artifact_path).map_err(|error| {
        artifact_failure(
            format!("model artifact is unreadable: {error}"),
            "model_artifact_unreadable",
        )
    })?;
    let stamp = artifact_stamp(&metadata);
    if stamp.bytes != expected_bytes {
        return Err(artifact_failure(
            format!(
                "model artifact byte size mismatch: expected {expected_bytes}, found {}",
                stamp.bytes
            ),
            "model_artifact_size_mismatch",
        ));
    }

    static VERIFIED: OnceLock<Mutex<HashMap<String, VerifiedArtifact>>> = OnceLock::new();
    let cache = VERIFIED.get_or_init(|| Mutex::new(HashMap::with_capacity(4)));
    if cache.lock().ok().is_some_and(|cache| {
        cache.get(model.artifact_path).is_some_and(|verified| {
            verified.expected_sha256 == expected_sha256 && verified.stamp == stamp
        })
    }) {
        return Ok(());
    }

    let actual_sha256 = sha256_gguf(model.artifact_path)?;
    if actual_sha256 != expected_sha256 {
        return Err(artifact_failure(
            format!(
                "model artifact SHA-256 mismatch: expected {expected_sha256}, found {actual_sha256}"
            ),
            "model_artifact_digest_mismatch",
        ));
    }
    if let Ok(mut cache) = cache.lock() {
        if cache.len() >= 32 {
            cache.drain().next();
        }
        cache.insert(
            model.artifact_path.to_owned(),
            VerifiedArtifact {
                expected_sha256,
                stamp,
            },
        );
    }
    Ok(())
}

fn sha256_gguf(path: &str) -> Result<String, ModelError> {
    let file = fs::File::open(path).map_err(|error| {
        artifact_failure(
            format!("model artifact is unreadable: {error}"),
            "model_artifact_unreadable",
        )
    })?;
    let mut reader = BufReader::with_capacity(1024 * 1024, file);
    let mut buffer = vec![0_u8; 1024 * 1024];
    let mut hasher = Sha256::new();
    let mut first = true;
    loop {
        let read = reader.read(&mut buffer).map_err(|error| {
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
}
