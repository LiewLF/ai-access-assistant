// SPDX-License-Identifier: AGPL-3.0-only
//
// Behavior adapted from CodexPlusPlus provider_sync.rs at
// 3dafffcafb2566a1e8bce4b35671656d6adb3eda. This implementation replaces
// whole-file in-memory rewrites and skipped locks with streaming plans,
// exact session_meta patches, atomic replacement, and fail-closed errors.

use crate::{CoreError, EvidenceMap, Result, ThreadEvidence};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, BufWriter, Read, Write};
use std::ops::Range;
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};
use uuid::Uuid;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const SESSION_DIRECTORIES: [&str; 2] = ["sessions", "archived_sessions"];
// Full history repair streams every rollout. Yield periodically so this
// user-initiated safety task cannot monopolize a CPU core on large histories.
// Keep this local to scanning: writes still stay atomic and transaction order
// is unchanged.
const SCAN_THROTTLE_BYTES: usize = 1_024 * 1_024;
const SCAN_THROTTLE_PAUSE: Duration = Duration::from_millis(6);

struct ScanThrottle {
    bytes_since_pause: usize,
}

impl ScanThrottle {
    fn new() -> Self {
        Self {
            bytes_since_pause: 0,
        }
    }

    fn consume(&mut self, bytes: usize) {
        self.bytes_since_pause += bytes;
        if self.bytes_since_pause >= SCAN_THROTTLE_BYTES {
            self.bytes_since_pause = 0;
            std::thread::sleep(SCAN_THROTTLE_PAUSE);
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LinePatch {
    pub line_number: usize,
    pub original: String,
    pub replacement: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RolloutFilePlan {
    pub relative_path: PathBuf,
    pub original_sha256: String,
    pub repaired_sha256: String,
    pub original_mode: u32,
    pub original_modified_seconds: u64,
    pub original_modified_nanos: u32,
    pub patches: Vec<LinePatch>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RolloutPlan {
    pub files: Vec<RolloutFilePlan>,
    pub evidence: EvidenceMap,
    pub session_meta_records: usize,
    pub encrypted_content_files: usize,
}

#[derive(Debug, Deserialize)]
struct RecordRaw<'a> {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default, borrow)]
    payload: Option<&'a RawValue>,
}

#[derive(Debug, Deserialize)]
struct SessionMetaRaw<'a> {
    id: String,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default, borrow)]
    model_provider: Option<&'a RawValue>,
}

#[derive(Debug, Deserialize)]
struct EventRaw {
    #[serde(rename = "type")]
    kind: Option<String>,
}

#[derive(Debug)]
struct MetaPatch {
    id: String,
    cwd: Option<String>,
    replacement: Option<String>,
}

pub(crate) fn build_plan(home: &Path, target_provider: &str) -> Result<RolloutPlan> {
    let paths = rollout_paths(home)?;
    let mut files = Vec::with_capacity(paths.len());
    let mut evidence = EvidenceMap::new();
    let mut session_meta_records = 0usize;
    let mut encrypted_content_files = 0usize;

    for path in paths {
        let scan = scan_rollout_file(home, &path, target_provider)?;
        session_meta_records += scan.session_meta_records;
        if scan.encrypted_content {
            encrypted_content_files += 1;
        }
        for (thread_id, thread_evidence) in scan.evidence {
            merge_evidence(&mut evidence, thread_id, thread_evidence)?;
        }
        files.push(scan.file);
    }

    Ok(RolloutPlan {
        files,
        evidence,
        session_meta_records,
        encrypted_content_files,
    })
}

struct FileScan {
    file: RolloutFilePlan,
    evidence: EvidenceMap,
    session_meta_records: usize,
    encrypted_content: bool,
}

fn scan_rollout_file(home: &Path, path: &Path, target_provider: &str) -> Result<FileScan> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CoreError::new(
            "rollout_unavailable",
            format!("Cannot inspect rollout {}: {error}", path.display()),
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(CoreError::new(
            "unsafe_rollout_path",
            format!(
                "Rollout must be a regular non-symlink file: {}",
                path.display()
            ),
        ));
    }

    let file = File::open(path).map_err(|error| {
        CoreError::new(
            "rollout_unavailable",
            format!("Cannot open rollout {}: {error}", path.display()),
        )
    })?;
    let mut reader = BufReader::new(file);
    let mut original_hasher = Sha256::new();
    let mut repaired_hasher = Sha256::new();
    let mut patches = Vec::new();
    let mut buffer = Vec::new();
    let mut line_number = 0usize;
    let mut session_meta_records = 0usize;
    let mut encrypted_content = false;
    let mut file_thread_ids = BTreeSet::new();
    let mut first_thread_id = None;
    let mut has_user_event = false;
    let mut evidence = EvidenceMap::new();
    let mut throttle = ScanThrottle::new();

    loop {
        buffer.clear();
        let read = reader.read_until(b'\n', &mut buffer).map_err(|error| {
            CoreError::new(
                "rollout_read_failed",
                format!("Cannot read rollout {}: {error}", path.display()),
            )
        })?;
        if read == 0 {
            break;
        }
        line_number += 1;
        throttle.consume(read);
        original_hasher.update(&buffer);
        if contains_bytes(&buffer, b"encrypted_content") {
            encrypted_content = true;
        }

        let line = std::str::from_utf8(&buffer).map_err(|_| {
            CoreError::new(
                "invalid_rollout_encoding",
                format!(
                    "Rollout is not UTF-8 at {} line {line_number}",
                    path.display()
                ),
            )
        })?;
        let (body, _) = split_line_ending(line);
        if body.trim().is_empty() {
            repaired_hasher.update(&buffer);
            continue;
        }
        let record: RecordRaw<'_> = serde_json::from_str(body).map_err(|error| {
            CoreError::new(
                "invalid_rollout_json",
                format!(
                    "Invalid JSON at {} line {line_number}: {error}",
                    path.display()
                ),
            )
        })?;

        let mut repaired_line = None;
        if record.kind == "session_meta" {
            let payload = record.payload.ok_or_else(|| {
                CoreError::new(
                    "invalid_session_meta",
                    format!(
                        "session_meta has no payload at {} line {line_number}",
                        path.display()
                    ),
                )
            })?;
            let meta = patch_session_meta(body, line, payload, target_provider, path, line_number)?;
            session_meta_records += 1;
            if first_thread_id.is_none() {
                first_thread_id = Some(meta.id.clone());
            }
            file_thread_ids.insert(meta.id.clone());
            merge_evidence(
                &mut evidence,
                meta.id,
                ThreadEvidence {
                    has_user_event: false,
                    cwd: meta.cwd,
                },
            )?;
            repaired_line = meta.replacement;
        } else if record.kind == "event_msg" {
            if let Some(payload) = record.payload {
                let event: EventRaw = serde_json::from_str(payload.get()).map_err(|error| {
                    CoreError::new(
                        "invalid_event_payload",
                        format!(
                            "Invalid event payload at {} line {line_number}: {error}",
                            path.display()
                        ),
                    )
                })?;
                has_user_event = matches!(
                    event.kind.as_deref(),
                    Some("user_message") | Some("user_input")
                ) || has_user_event;
            }
        }

        if let Some(replacement) = repaired_line {
            repaired_hasher.update(replacement.as_bytes());
            patches.push(LinePatch {
                line_number,
                original: line.to_string(),
                replacement,
            });
        } else {
            repaired_hasher.update(&buffer);
        }
    }

    if session_meta_records == 0 {
        return Err(CoreError::new(
            "missing_session_meta",
            format!("Rollout has no session_meta record: {}", path.display()),
        ));
    }
    if has_user_event {
        if let Some(thread_id) = first_thread_id {
            evidence.entry(thread_id).or_default().has_user_event = true;
        }
    }
    if file_thread_ids.is_empty() {
        return Err(CoreError::new(
            "missing_thread_id",
            format!("Rollout has no valid thread ID: {}", path.display()),
        ));
    }

    let modified = metadata.modified().unwrap_or(UNIX_EPOCH);
    let modified_duration = modified.duration_since(UNIX_EPOCH).unwrap_or_default();
    let relative_path = path.strip_prefix(home).map_err(|_| {
        CoreError::new(
            "unsafe_rollout_path",
            format!("Rollout escaped CODEX_HOME: {}", path.display()),
        )
    })?;

    Ok(FileScan {
        file: RolloutFilePlan {
            relative_path: relative_path.to_path_buf(),
            original_sha256: digest_hex(original_hasher.finalize()),
            repaired_sha256: digest_hex(repaired_hasher.finalize()),
            original_mode: file_mode(&metadata),
            original_modified_seconds: modified_duration.as_secs(),
            original_modified_nanos: modified_duration.subsec_nanos(),
            patches,
        },
        evidence,
        session_meta_records,
        encrypted_content,
    })
}

fn patch_session_meta(
    body: &str,
    full_line: &str,
    payload: &RawValue,
    target_provider: &str,
    path: &Path,
    line_number: usize,
) -> Result<MetaPatch> {
    let parsed: SessionMetaRaw<'_> = serde_json::from_str(payload.get()).map_err(|error| {
        CoreError::new(
            "invalid_session_meta",
            format!(
                "Invalid session_meta payload at {} line {line_number}: {error}",
                path.display()
            ),
        )
    })?;
    if parsed.id.trim().is_empty() {
        return Err(CoreError::new(
            "missing_thread_id",
            format!(
                "session_meta has empty thread ID at {} line {line_number}",
                path.display()
            ),
        ));
    }
    let payload_start = borrowed_offset(body, payload.get()).ok_or_else(|| {
        CoreError::new(
            "invalid_session_meta",
            format!(
                "Cannot locate session_meta payload at {} line {line_number}",
                path.display()
            ),
        )
    })?;
    let quoted_target = serde_json::to_string(target_provider).map_err(|error| {
        CoreError::new(
            "provider_encode_failed",
            format!("Cannot encode target provider: {error}"),
        )
    })?;
    let replacement_body = if let Some(raw_provider) = parsed.model_provider {
        let current_provider: String = serde_json::from_str(raw_provider.get()).map_err(|_| {
            CoreError::new(
                "invalid_session_meta",
                format!(
                    "model_provider is not a string at {} line {line_number}",
                    path.display()
                ),
            )
        })?;
        if current_provider == target_provider {
            None
        } else {
            let provider_offset =
                borrowed_offset(payload.get(), raw_provider.get()).ok_or_else(|| {
                    CoreError::new(
                        "invalid_session_meta",
                        format!(
                            "Cannot locate model_provider at {} line {line_number}",
                            path.display()
                        ),
                    )
                })?;
            let start = payload_start + provider_offset;
            let end = start + raw_provider.get().len();
            let mut next = body.to_string();
            next.replace_range(start..end, &quoted_target);
            Some(next)
        }
    } else {
        let payload_value: serde_json::Value =
            serde_json::from_str(payload.get()).map_err(|error| {
                CoreError::new(
                    "invalid_session_meta",
                    format!(
                        "Invalid payload object at {} line {line_number}: {error}",
                        path.display()
                    ),
                )
            })?;
        let object = payload_value.as_object().ok_or_else(|| {
            CoreError::new(
                "invalid_session_meta",
                format!(
                    "session_meta payload is not an object at {} line {line_number}",
                    path.display()
                ),
            )
        })?;
        let closing = payload
            .get()
            .rfind('}')
            .ok_or_else(|| CoreError::new("invalid_session_meta", "Missing payload object end"))?;
        let insertion = if object.is_empty() {
            format!("\"model_provider\":{quoted_target}")
        } else {
            format!(",\"model_provider\":{quoted_target}")
        };
        let mut next = body.to_string();
        next.insert_str(payload_start + closing, &insertion);
        Some(next)
    };

    let replacement = replacement_body.map(|mut next| {
        let (_, ending) = split_line_ending(full_line);
        next.push_str(ending);
        next
    });
    if let Some(next) = replacement.as_deref() {
        let (next_body, _) = split_line_ending(next);
        let value: serde_json::Value = serde_json::from_str(next_body).map_err(|error| {
            CoreError::new(
                "patch_verification_failed",
                format!(
                    "Patched session_meta became invalid at {} line {line_number}: {error}",
                    path.display()
                ),
            )
        })?;
        if value
            .pointer("/payload/model_provider")
            .and_then(serde_json::Value::as_str)
            != Some(target_provider)
        {
            return Err(CoreError::new(
                "patch_verification_failed",
                format!(
                    "Patched provider mismatch at {} line {line_number}",
                    path.display()
                ),
            ));
        }
    }

    Ok(MetaPatch {
        id: parsed.id,
        cwd: parsed.cwd.filter(|cwd| !cwd.trim().is_empty()),
        replacement,
    })
}

fn merge_evidence(
    evidence: &mut EvidenceMap,
    thread_id: String,
    next: ThreadEvidence,
) -> Result<()> {
    let current = evidence.entry(thread_id.clone()).or_default();
    current.has_user_event |= next.has_user_event;
    if let Some(cwd) = next.cwd {
        match current.cwd.as_deref() {
            Some(existing) if existing != cwd => {
                return Err(CoreError::new(
                    "conflicting_rollout_evidence",
                    format!("Thread {thread_id} has conflicting workspace paths"),
                ));
            }
            None => current.cwd = Some(cwd),
            _ => {}
        }
    }
    Ok(())
}

pub(crate) fn apply_file_plan(home: &Path, plan: &RolloutFilePlan, reverse: bool) -> Result<bool> {
    let path = safe_join(home, &plan.relative_path)?;
    let current_hash = hash_file(&path)?;
    let (expected, completed) = if reverse {
        (&plan.repaired_sha256, &plan.original_sha256)
    } else {
        (&plan.original_sha256, &plan.repaired_sha256)
    };
    if &current_hash == completed {
        return Ok(false);
    }
    if &current_hash != expected {
        return Err(CoreError::new(
            "concurrent_rollout_change",
            format!(
                "Rollout changed outside transaction: {}",
                plan.relative_path.display()
            ),
        ));
    }

    let mut patches = BTreeMap::new();
    for patch in &plan.patches {
        let pair = if reverse {
            (&patch.replacement, &patch.original)
        } else {
            (&patch.original, &patch.replacement)
        };
        if patches
            .insert(patch.line_number, (pair.0.as_str(), pair.1.as_str()))
            .is_some()
        {
            return Err(CoreError::new(
                "invalid_journal",
                format!(
                    "Duplicate line patch for {} line {}",
                    plan.relative_path.display(),
                    patch.line_number
                ),
            ));
        }
    }

    let parent = path.parent().ok_or_else(|| {
        CoreError::new(
            "unsafe_rollout_path",
            format!("Rollout has no parent: {}", path.display()),
        )
    })?;
    let temp_path = parent.join(format!(".aih-session-{}.tmp", Uuid::new_v4()));
    let source = File::open(&path).map_err(|error| {
        CoreError::new(
            "rollout_unavailable",
            format!("Cannot open rollout {}: {error}", path.display()),
        )
    })?;
    let temp = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temp_path)
        .map_err(|error| {
            CoreError::new(
                "atomic_write_failed",
                format!("Cannot create temporary rollout file: {error}"),
            )
        })?;
    set_private_file_permissions(&temp_path)?;
    let mut reader = BufReader::new(source);
    let mut writer = BufWriter::new(temp);
    let mut buffer = Vec::new();
    let mut line_number = 0usize;
    let mut applied = 0usize;

    let write_result = (|| -> Result<()> {
        loop {
            buffer.clear();
            let read = reader.read_until(b'\n', &mut buffer).map_err(|error| {
                CoreError::new(
                    "rollout_read_failed",
                    format!("Cannot reread rollout {}: {error}", path.display()),
                )
            })?;
            if read == 0 {
                break;
            }
            line_number += 1;
            if let Some((from, to)) = patches.get(&line_number) {
                if buffer.as_slice() != from.as_bytes() {
                    return Err(CoreError::new(
                        "concurrent_rollout_change",
                        format!(
                            "Rollout line changed outside transaction: {} line {line_number}",
                            plan.relative_path.display()
                        ),
                    ));
                }
                writer.write_all(to.as_bytes()).map_err(write_error)?;
                applied += 1;
            } else {
                writer.write_all(&buffer).map_err(write_error)?;
            }
        }
        if applied != patches.len() {
            return Err(CoreError::new(
                "patch_verification_failed",
                format!(
                    "Not every metadata patch was applied to {}",
                    plan.relative_path.display()
                ),
            ));
        }
        writer.flush().map_err(write_error)?;
        writer.get_ref().sync_all().map_err(write_error)?;
        Ok(())
    })();

    if let Err(error) = write_result {
        drop(writer);
        let _ = fs::remove_file(&temp_path);
        return Err(error);
    }
    drop(writer);
    fs::rename(&temp_path, &path).map_err(|error| {
        let _ = fs::remove_file(&temp_path);
        CoreError::new(
            "atomic_replace_failed",
            format!("Cannot replace rollout {}: {error}", path.display()),
        )
    })?;
    restore_metadata(&path, plan)?;
    sync_directory(parent)?;
    let final_hash = hash_file(&path)?;
    if &final_hash != completed {
        return Err(CoreError::new(
            "patch_verification_failed",
            format!("Rollout hash verification failed: {}", path.display()),
        ));
    }
    Ok(true)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ThreeWayDirection {
    Rollback,
    Compensation,
}

#[derive(Debug)]
struct ParsedProviderLine {
    id: String,
    provider: Option<String>,
    provider_range: Option<Range<usize>>,
}

pub(crate) fn preflight_rollback(home: &Path, plan: &RolloutPlan) -> Result<()> {
    for file in plan.files.iter().filter(|file| !file.patches.is_empty()) {
        scan_three_way_file(home, file, ThreeWayDirection::Rollback)?;
    }
    Ok(())
}

pub(crate) fn rollback_file_plan(home: &Path, plan: &RolloutFilePlan) -> Result<bool> {
    if scan_three_way_file(home, plan, ThreeWayDirection::Rollback)? == 0 {
        return Ok(false);
    }
    apply_three_way_file(home, plan, ThreeWayDirection::Rollback)
}

pub(crate) fn compensate_rollback_file(home: &Path, plan: &RolloutFilePlan) -> Result<bool> {
    if scan_three_way_file(home, plan, ThreeWayDirection::Compensation)? == 0 {
        return Ok(false);
    }
    apply_three_way_file(home, plan, ThreeWayDirection::Compensation)
}

pub(crate) fn verify_rolled_back(home: &Path, plan: &RolloutPlan) -> Result<()> {
    for file in plan.files.iter().filter(|file| !file.patches.is_empty()) {
        let pending = scan_three_way_file(home, file, ThreeWayDirection::Rollback)?;
        if pending > 0 {
            return Err(CoreError::new(
                "rollback_verification_failed",
                format!(
                    "Rollout provider rollback did not finish: {}",
                    file.relative_path.display()
                ),
            ));
        }
    }
    Ok(())
}

fn scan_three_way_file(
    home: &Path,
    plan: &RolloutFilePlan,
    direction: ThreeWayDirection,
) -> Result<usize> {
    let path = safe_join(home, &plan.relative_path)?;
    ensure_three_way_rollout(&path, direction)?;
    let source = File::open(&path).map_err(|error| {
        CoreError::new(
            "rollout_unavailable",
            format!("Cannot open rollout {}: {error}", path.display()),
        )
    })?;
    let patches = line_patch_map(plan)?;
    let mut reader = BufReader::new(source);
    let mut buffer = Vec::new();
    let mut line_number = 0usize;
    let mut visited = 0usize;
    let mut pending = 0usize;
    loop {
        buffer.clear();
        let read = reader.read_until(b'\n', &mut buffer).map_err(|error| {
            CoreError::new(
                "rollout_read_failed",
                format!("Cannot read rollout {}: {error}", path.display()),
            )
        })?;
        if read == 0 {
            break;
        }
        line_number += 1;
        let Some(patch) = patches.get(&line_number) else {
            continue;
        };
        visited += 1;
        let line = std::str::from_utf8(&buffer).map_err(|_| {
            CoreError::new(
                transition_error_code(direction),
                format!(
                    "Managed rollout line is not UTF-8: {} line {line_number}",
                    plan.relative_path.display()
                ),
            )
        })?;
        if transition_patch_line(line, patch, direction, &path, line_number)?.is_some() {
            pending += 1;
        }
    }
    if visited != patches.len() {
        return Err(CoreError::new(
            transition_error_code(direction),
            format!(
                "Managed session metadata disappeared after transaction: {}",
                plan.relative_path.display()
            ),
        ));
    }
    Ok(pending)
}

fn apply_three_way_file(
    home: &Path,
    plan: &RolloutFilePlan,
    direction: ThreeWayDirection,
) -> Result<bool> {
    let path = safe_join(home, &plan.relative_path)?;
    let metadata = ensure_three_way_rollout(&path, direction)?;
    let current_mode = file_mode(&metadata);
    let current_modified = metadata.modified().unwrap_or(UNIX_EPOCH);
    let current_modified = current_modified
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let patches = line_patch_map(plan)?;
    let parent = path.parent().ok_or_else(|| {
        CoreError::new(
            "unsafe_rollout_path",
            format!("Rollout has no parent: {}", path.display()),
        )
    })?;
    let temp_path = parent.join(format!(".aih-session-{}.tmp", Uuid::new_v4()));
    let source = File::open(&path).map_err(|error| {
        CoreError::new(
            "rollout_unavailable",
            format!("Cannot open rollout {}: {error}", path.display()),
        )
    })?;
    let temp = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temp_path)
        .map_err(|error| {
            CoreError::new(
                "atomic_write_failed",
                format!("Cannot create temporary rollout file: {error}"),
            )
        })?;
    set_private_file_permissions(&temp_path)?;
    let mut reader = BufReader::new(source);
    let mut writer = BufWriter::new(temp);
    let mut source_hasher = Sha256::new();
    let mut buffer = Vec::new();
    let mut line_number = 0usize;
    let mut visited = 0usize;
    let mut applied = 0usize;

    let write_result = (|| -> Result<String> {
        loop {
            buffer.clear();
            let read = reader.read_until(b'\n', &mut buffer).map_err(|error| {
                CoreError::new(
                    "rollout_read_failed",
                    format!("Cannot reread rollout {}: {error}", path.display()),
                )
            })?;
            if read == 0 {
                break;
            }
            source_hasher.update(&buffer);
            line_number += 1;
            if let Some(patch) = patches.get(&line_number) {
                visited += 1;
                let line = std::str::from_utf8(&buffer).map_err(|_| {
                    CoreError::new(
                        transition_error_code(direction),
                        format!(
                            "Managed rollout line is not UTF-8: {} line {line_number}",
                            plan.relative_path.display()
                        ),
                    )
                })?;
                if let Some(replacement) =
                    transition_patch_line(line, patch, direction, &path, line_number)?
                {
                    writer
                        .write_all(replacement.as_bytes())
                        .map_err(write_error)?;
                    applied += 1;
                } else {
                    writer.write_all(&buffer).map_err(write_error)?;
                }
            } else {
                writer.write_all(&buffer).map_err(write_error)?;
            }
        }
        if visited != patches.len() {
            return Err(CoreError::new(
                transition_error_code(direction),
                format!(
                    "Managed session metadata disappeared after transaction: {}",
                    plan.relative_path.display()
                ),
            ));
        }
        writer.flush().map_err(write_error)?;
        writer.get_ref().sync_all().map_err(write_error)?;
        Ok(digest_hex(source_hasher.finalize()))
    })();

    let source_digest = match write_result {
        Ok(value) => value,
        Err(error) => {
            drop(writer);
            let _ = fs::remove_file(&temp_path);
            return Err(error);
        }
    };
    drop(writer);
    if applied == 0 {
        let _ = fs::remove_file(&temp_path);
        return Ok(false);
    }
    if hash_file(&path)? != source_digest {
        let _ = fs::remove_file(&temp_path);
        return Err(CoreError::new(
            transition_error_code(direction),
            format!(
                "Rollout changed while rollback was being prepared: {}",
                plan.relative_path.display()
            ),
        ));
    }
    fs::rename(&temp_path, &path).map_err(|error| {
        let _ = fs::remove_file(&temp_path);
        CoreError::new(
            "atomic_replace_failed",
            format!("Cannot replace rollout {}: {error}", path.display()),
        )
    })?;
    restore_metadata_values(
        &path,
        current_mode,
        current_modified.as_secs(),
        current_modified.subsec_nanos(),
    )?;
    sync_directory(parent)?;
    Ok(true)
}

fn line_patch_map(plan: &RolloutFilePlan) -> Result<BTreeMap<usize, &LinePatch>> {
    let mut patches = BTreeMap::new();
    for patch in &plan.patches {
        if patches.insert(patch.line_number, patch).is_some() {
            return Err(CoreError::new(
                "invalid_journal",
                format!(
                    "Duplicate line patch for {} line {}",
                    plan.relative_path.display(),
                    patch.line_number
                ),
            ));
        }
    }
    Ok(patches)
}

fn transition_patch_line(
    current_line: &str,
    patch: &LinePatch,
    direction: ThreeWayDirection,
    path: &Path,
    line_number: usize,
) -> Result<Option<String>> {
    let original = parse_provider_line(&patch.original, path, line_number)?;
    let repaired = parse_provider_line(&patch.replacement, path, line_number)?;
    if original.id != repaired.id || original.provider == repaired.provider {
        return Err(CoreError::new(
            "invalid_journal",
            format!(
                "Invalid provider patch at {} line {line_number}",
                path.display()
            ),
        ));
    }
    let current = parse_provider_line(current_line, path, line_number).map_err(|_| {
        CoreError::new(
            transition_error_code(direction),
            format!(
                "Managed session metadata changed after transaction: {} line {line_number}",
                path.display()
            ),
        )
    })?;
    if current.id != original.id {
        return Err(CoreError::new(
            transition_error_code(direction),
            format!(
                "Managed session identity changed after transaction: {} line {line_number}",
                path.display()
            ),
        ));
    }
    let (expected, desired) = match direction {
        ThreeWayDirection::Rollback => (&repaired.provider, &original.provider),
        ThreeWayDirection::Compensation => (&original.provider, &repaired.provider),
    };
    if &current.provider == desired {
        return Ok(None);
    }
    if &current.provider != expected {
        return Err(CoreError::new(
            transition_error_code(direction),
            format!(
                "Managed rollout provider changed after transaction: {} line {line_number}",
                path.display()
            ),
        ));
    }
    let replacement = set_provider_field(
        current_line,
        &current,
        desired.as_deref(),
        patch,
        path,
        line_number,
    )?;
    let verified = parse_provider_line(&replacement, path, line_number)?;
    if verified.id != original.id || &verified.provider != desired {
        return Err(CoreError::new(
            "rollback_verification_failed",
            format!(
                "Managed rollout provider patch failed verification: {} line {line_number}",
                path.display()
            ),
        ));
    }
    Ok(Some(replacement))
}

fn parse_provider_line(line: &str, path: &Path, line_number: usize) -> Result<ParsedProviderLine> {
    let (body, _) = split_line_ending(line);
    let record: RecordRaw<'_> = serde_json::from_str(body).map_err(|error| {
        CoreError::new(
            "invalid_session_meta",
            format!(
                "Invalid managed session metadata at {} line {line_number}: {error}",
                path.display()
            ),
        )
    })?;
    if record.kind != "session_meta" {
        return Err(CoreError::new(
            "invalid_session_meta",
            format!(
                "Managed record is no longer session_meta at {} line {line_number}",
                path.display()
            ),
        ));
    }
    let payload = record.payload.ok_or_else(|| {
        CoreError::new(
            "invalid_session_meta",
            format!(
                "Managed session_meta has no payload at {} line {line_number}",
                path.display()
            ),
        )
    })?;
    let parsed: SessionMetaRaw<'_> = serde_json::from_str(payload.get()).map_err(|error| {
        CoreError::new(
            "invalid_session_meta",
            format!(
                "Invalid managed session_meta payload at {} line {line_number}: {error}",
                path.display()
            ),
        )
    })?;
    let payload_start = borrowed_offset(body, payload.get()).ok_or_else(|| {
        CoreError::new(
            "invalid_session_meta",
            format!(
                "Cannot locate managed session_meta payload at {} line {line_number}",
                path.display()
            ),
        )
    })?;
    let (provider, provider_range) = if let Some(raw) = parsed.model_provider {
        let value: String = serde_json::from_str(raw.get()).map_err(|_| {
            CoreError::new(
                "invalid_session_meta",
                format!(
                    "Managed model_provider is not a string at {} line {line_number}",
                    path.display()
                ),
            )
        })?;
        let offset = borrowed_offset(payload.get(), raw.get()).ok_or_else(|| {
            CoreError::new(
                "invalid_session_meta",
                format!(
                    "Cannot locate managed model_provider at {} line {line_number}",
                    path.display()
                ),
            )
        })?;
        let start = payload_start + offset;
        (Some(value), Some(start..start + raw.get().len()))
    } else {
        (None, None)
    };
    Ok(ParsedProviderLine {
        id: parsed.id,
        provider,
        provider_range,
    })
}

fn set_provider_field(
    current_line: &str,
    current: &ParsedProviderLine,
    desired: Option<&str>,
    patch: &LinePatch,
    path: &Path,
    line_number: usize,
) -> Result<String> {
    match (current.provider_range.as_ref(), desired) {
        (Some(range), Some(provider)) => {
            let encoded = serde_json::to_string(provider).map_err(|error| {
                CoreError::new(
                    "provider_encode_failed",
                    format!("Cannot encode rollback provider: {error}"),
                )
            })?;
            let mut next = current_line.to_string();
            next.replace_range(range.clone(), &encoded);
            Ok(next)
        }
        (None, Some(provider)) => insert_provider_field(current_line, provider, path, line_number),
        (Some(_), None) => remove_transaction_insertion(current_line, patch, path, line_number),
        (None, None) => Ok(current_line.to_string()),
    }
}

fn insert_provider_field(
    line: &str,
    provider: &str,
    path: &Path,
    line_number: usize,
) -> Result<String> {
    let (body, ending) = split_line_ending(line);
    let record: RecordRaw<'_> = serde_json::from_str(body)
        .map_err(|error| CoreError::new("invalid_session_meta", error.to_string()))?;
    let payload = record.payload.ok_or_else(|| {
        CoreError::new(
            "invalid_session_meta",
            "Managed session_meta has no payload",
        )
    })?;
    let payload_value: serde_json::Value = serde_json::from_str(payload.get())
        .map_err(|error| CoreError::new("invalid_session_meta", error.to_string()))?;
    let object = payload_value.as_object().ok_or_else(|| {
        CoreError::new(
            "invalid_session_meta",
            "Managed session_meta payload is not an object",
        )
    })?;
    let payload_start = borrowed_offset(body, payload.get()).ok_or_else(|| {
        CoreError::new(
            "invalid_session_meta",
            format!(
                "Cannot locate managed payload at {} line {line_number}",
                path.display()
            ),
        )
    })?;
    let closing = payload.get().rfind('}').ok_or_else(|| {
        CoreError::new(
            "invalid_session_meta",
            "Managed payload object has no closing brace",
        )
    })?;
    let encoded = serde_json::to_string(provider).map_err(|error| {
        CoreError::new(
            "provider_encode_failed",
            format!("Cannot encode rollback provider: {error}"),
        )
    })?;
    let insertion = if object.is_empty() {
        format!("\"model_provider\":{encoded}")
    } else {
        format!(",\"model_provider\":{encoded}")
    };
    let mut next = body.to_string();
    next.insert_str(payload_start + closing, &insertion);
    next.push_str(ending);
    Ok(next)
}

fn remove_transaction_insertion(
    current_line: &str,
    patch: &LinePatch,
    path: &Path,
    line_number: usize,
) -> Result<String> {
    let insertion = inserted_fragment(&patch.original, &patch.replacement).ok_or_else(|| {
        CoreError::new(
            "invalid_journal",
            format!(
                "Cannot derive inserted provider field at {} line {line_number}",
                path.display()
            ),
        )
    })?;
    let mut matches = current_line.match_indices(insertion.as_str());
    let first = matches.next().map(|(index, _)| index).ok_or_else(|| {
        CoreError::new(
            "concurrent_rollout_change",
            format!(
                "Inserted provider field changed after transaction: {} line {line_number}",
                path.display()
            ),
        )
    })?;
    if matches.next().is_some() {
        return Err(CoreError::new(
            "concurrent_rollout_change",
            format!(
                "Inserted provider field is ambiguous after transaction: {} line {line_number}",
                path.display()
            ),
        ));
    }
    let mut next = current_line.to_string();
    next.replace_range(first..first + insertion.len(), "");
    Ok(next)
}

fn inserted_fragment(original: &str, replacement: &str) -> Option<String> {
    if replacement.len() <= original.len() {
        return None;
    }
    let original_bytes = original.as_bytes();
    let replacement_bytes = replacement.as_bytes();
    let mut prefix = 0usize;
    while prefix < original_bytes.len() && original_bytes[prefix] == replacement_bytes[prefix] {
        prefix += 1;
    }
    while prefix > 0
        && (!original.is_char_boundary(prefix) || !replacement.is_char_boundary(prefix))
    {
        prefix -= 1;
    }
    let mut suffix = 0usize;
    while suffix < original_bytes.len().saturating_sub(prefix)
        && original_bytes[original_bytes.len() - 1 - suffix]
            == replacement_bytes[replacement_bytes.len() - 1 - suffix]
    {
        suffix += 1;
    }
    while suffix > 0
        && (!original.is_char_boundary(original.len() - suffix)
            || !replacement.is_char_boundary(replacement.len() - suffix))
    {
        suffix -= 1;
    }
    if prefix + suffix != original.len() {
        return None;
    }
    Some(replacement[prefix..replacement.len() - suffix].to_string())
}

fn transition_error_code(direction: ThreeWayDirection) -> &'static str {
    match direction {
        ThreeWayDirection::Rollback => "concurrent_rollout_change",
        ThreeWayDirection::Compensation => "rollback_compensation_failed",
    }
}

fn ensure_three_way_rollout(path: &Path, direction: ThreeWayDirection) -> Result<fs::Metadata> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CoreError::new(
            transition_error_code(direction),
            format!(
                "Managed rollout disappeared or became unavailable: {}: {error}",
                path.display()
            ),
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(CoreError::new(
            transition_error_code(direction),
            format!(
                "Managed rollout was replaced after transaction: {}",
                path.display()
            ),
        ));
    }
    Ok(metadata)
}

pub(crate) fn verify_repaired(home: &Path, plan: &RolloutPlan) -> Result<()> {
    for file in &plan.files {
        let path = safe_join(home, &file.relative_path)?;
        let expected = if file.patches.is_empty() {
            &file.original_sha256
        } else {
            &file.repaired_sha256
        };
        if hash_file(&path)? != *expected {
            return Err(CoreError::new(
                "repair_verification_failed",
                format!("Rollout verification failed: {}", path.display()),
            ));
        }
    }
    Ok(())
}

fn rollout_paths(home: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for directory in SESSION_DIRECTORIES {
        let root = home.join(directory);
        if !root.exists() {
            continue;
        }
        collect_rollouts(&root, &mut paths)?;
    }
    paths.sort();
    Ok(paths)
}

fn collect_rollouts(root: &Path, paths: &mut Vec<PathBuf>) -> Result<()> {
    let metadata = fs::symlink_metadata(root).map_err(|error| {
        CoreError::new(
            "rollout_directory_unavailable",
            format!("Cannot inspect {}: {error}", root.display()),
        )
    })?;
    if metadata.file_type().is_symlink() {
        return Err(CoreError::new(
            "unsafe_rollout_path",
            format!("Symbolic links are not allowed: {}", root.display()),
        ));
    }
    if !metadata.is_dir() {
        return Err(CoreError::new(
            "unsafe_rollout_path",
            format!("Expected rollout directory: {}", root.display()),
        ));
    }
    let mut entries = fs::read_dir(root)
        .map_err(|error| {
            CoreError::new(
                "rollout_directory_unavailable",
                format!("Cannot read {}: {error}", root.display()),
            )
        })?
        .collect::<std::io::Result<Vec<_>>>()
        .map_err(|error| CoreError::new("rollout_directory_unavailable", error.to_string()))?;
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            CoreError::new(
                "rollout_unavailable",
                format!("Cannot inspect {}: {error}", path.display()),
            )
        })?;
        if metadata.file_type().is_symlink() {
            return Err(CoreError::new(
                "unsafe_rollout_path",
                format!("Symbolic links are not allowed: {}", path.display()),
            ));
        }
        if metadata.is_dir() {
            collect_rollouts(&path, paths)?;
        } else if metadata.is_file()
            && path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("rollout-") && name.ends_with(".jsonl"))
        {
            paths.push(path);
        }
    }
    Ok(())
}

fn safe_join(home: &Path, relative: &Path) -> Result<PathBuf> {
    if relative.is_absolute()
        || relative.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(CoreError::new(
            "unsafe_rollout_path",
            format!("Unsafe journal path: {}", relative.display()),
        ));
    }
    let path = home.join(relative);
    let parent = path.parent().ok_or_else(|| {
        CoreError::new(
            "unsafe_rollout_path",
            format!("Unsafe journal path: {}", relative.display()),
        )
    })?;
    let canonical_parent = fs::canonicalize(parent).map_err(|error| {
        CoreError::new(
            "rollout_unavailable",
            format!("Cannot resolve {}: {error}", parent.display()),
        )
    })?;
    if !canonical_parent.starts_with(home) {
        return Err(CoreError::new(
            "unsafe_rollout_path",
            format!("Journal path escaped CODEX_HOME: {}", relative.display()),
        ));
    }
    Ok(path)
}

fn hash_file(path: &Path) -> Result<String> {
    let mut file = File::open(path).map_err(|error| {
        CoreError::new(
            "rollout_unavailable",
            format!("Cannot hash {}: {error}", path.display()),
        )
    })?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).map_err(|error| {
            CoreError::new(
                "rollout_read_failed",
                format!("Cannot hash {}: {error}", path.display()),
            )
        })?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(digest_hex(hasher.finalize()))
}

fn digest_hex(bytes: impl AsRef<[u8]>) -> String {
    let mut output = String::with_capacity(bytes.as_ref().len() * 2);
    for byte in bytes.as_ref() {
        use std::fmt::Write as _;
        let _ = write!(output, "{byte:02x}");
    }
    output
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

fn borrowed_offset(container: &str, borrowed: &str) -> Option<usize> {
    let container_start = container.as_ptr() as usize;
    let container_end = container_start.checked_add(container.len())?;
    let borrowed_start = borrowed.as_ptr() as usize;
    let borrowed_end = borrowed_start.checked_add(borrowed.len())?;
    if borrowed_start < container_start || borrowed_end > container_end {
        return None;
    }
    Some(borrowed_start - container_start)
}

fn split_line_ending(line: &str) -> (&str, &str) {
    if let Some(body) = line.strip_suffix("\r\n") {
        (body, "\r\n")
    } else if let Some(body) = line.strip_suffix('\n') {
        (body, "\n")
    } else {
        (line, "")
    }
}

fn write_error(error: std::io::Error) -> CoreError {
    CoreError::new("atomic_write_failed", error.to_string())
}

fn restore_metadata(path: &Path, plan: &RolloutFilePlan) -> Result<()> {
    restore_metadata_values(
        path,
        plan.original_mode,
        plan.original_modified_seconds,
        plan.original_modified_nanos,
    )
}

fn restore_metadata_values(
    path: &Path,
    mode: u32,
    modified_seconds: u64,
    modified_nanos: u32,
) -> Result<()> {
    #[cfg(unix)]
    {
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).map_err(|error| {
            CoreError::new(
                "permission_restore_failed",
                format!("Cannot restore permissions for {}: {error}", path.display()),
            )
        })?;
    }
    let modified = UNIX_EPOCH + Duration::new(modified_seconds, modified_nanos);
    let file = OpenOptions::new().write(true).open(path).map_err(|error| {
        CoreError::new(
            "metadata_restore_failed",
            format!(
                "Cannot open {} to restore metadata: {error}",
                path.display()
            ),
        )
    })?;
    let times = fs::FileTimes::new().set_modified(modified);
    file.set_times(times).map_err(|error| {
        CoreError::new(
            "metadata_restore_failed",
            format!("Cannot restore mtime for {}: {error}", path.display()),
        )
    })
}

#[cfg(unix)]
fn file_mode(metadata: &fs::Metadata) -> u32 {
    metadata.permissions().mode() & 0o7777
}

#[cfg(not(unix))]
fn file_mode(_metadata: &fs::Metadata) -> u32 {
    0
}

fn set_private_file_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|error| {
        CoreError::new(
            "permission_failed",
            format!("Cannot secure {}: {error}", path.display()),
        )
    })?;
    Ok(())
}

fn sync_directory(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        File::open(path)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| {
                CoreError::new(
                    "atomic_write_failed",
                    format!("Cannot sync directory {}: {error}", path.display()),
                )
            })?;
    }
    Ok(())
}
