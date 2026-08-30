// SPDX-License-Identifier: AGPL-3.0-only

use crate::crypto;
use crate::journal::{self, JournalManifest, JournalOperation, JournalState, TransactionLock};
use crate::sqlite::{self, ImportThreadRow};
use crate::{validate_codex_home, validate_provider, CoreError, Progress, Result, RollbackSummary};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const MAX_FILES: usize = 2_000;
const MAX_FILE_BYTES: u64 = 64 * 1_024 * 1_024;
const MAX_TOTAL_BYTES: u64 = 512 * 1_024 * 1_024;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ImportFailurePoint {
    AfterFirstRollout,
    AfterRollouts,
    AfterSqlite,
}

#[derive(Debug, Clone)]
pub struct ImportOptions {
    pub journal_root: PathBuf,
    pub failure_point: Option<ImportFailurePoint>,
    pub transaction_id: Option<String>,
}

impl ImportOptions {
    pub fn new(journal_root: impl Into<PathBuf>) -> Self {
        Self {
            journal_root: journal_root.into(),
            failure_point: None,
            transaction_id: None,
        }
    }

    pub fn with_transaction_id(mut self, transaction_id: impl Into<String>) -> Self {
        self.transaction_id = Some(transaction_id.into());
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ImportSummary {
    pub transaction_id: String,
    pub journal_path: PathBuf,
    pub imported_sessions: usize,
    pub imported_rollout_files: usize,
    pub conflict_policy: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ImportFilePlan {
    source_path: PathBuf,
    destination_relative_path: PathBuf,
    copy_stage_relative_path: PathBuf,
    rollback_stage_relative_path: PathBuf,
    sha256: String,
    size_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ImportPlan {
    source_root: PathBuf,
    files: Vec<ImportFilePlan>,
    rows: Vec<ImportThreadRow>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ImportPayload {
    plan: ImportPlan,
}

#[derive(Debug, Clone)]
struct ImportJournal {
    version: u32,
    transaction_id: String,
    codex_home: PathBuf,
    created_at_unix_seconds: u64,
    state: JournalState,
    plan: ImportPlan,
    directory: PathBuf,
}

impl ImportJournal {
    fn create(
        home: &Path,
        transaction_id: &str,
        journal_root: &Path,
        plan: ImportPlan,
        key: &[u8; 32],
    ) -> Result<Self> {
        let directory = journal::create_transaction_directory(journal_root, transaction_id)?;
        let value = Self {
            version: 1,
            transaction_id: transaction_id.to_string(),
            codex_home: home.to_path_buf(),
            created_at_unix_seconds: now_seconds(),
            state: JournalState::Preparing,
            plan,
            directory,
        };
        value.store(key)?;
        Ok(value)
    }

    fn load(path: &Path, key: &[u8; 32]) -> Result<Self> {
        let (manifest, directory) = journal::load_manifest(path)?;
        if manifest.operation != JournalOperation::Import {
            return Err(CoreError::new(
                "journal_operation_mismatch",
                "Recovery journal is not an import transaction",
            ));
        }
        let payload: ImportPayload = crypto::decrypt_json(key, &manifest.encrypted_payload)?;
        Ok(Self {
            version: manifest.version,
            transaction_id: manifest.transaction_id,
            codex_home: manifest.codex_home,
            created_at_unix_seconds: manifest.created_at_unix_seconds,
            state: manifest.state,
            plan: payload.plan,
            directory,
        })
    }

    fn store(&self, key: &[u8; 32]) -> Result<()> {
        let payload = ImportPayload {
            plan: self.plan.clone(),
        };
        let manifest = JournalManifest {
            version: self.version,
            operation: JournalOperation::Import,
            transaction_id: self.transaction_id.clone(),
            codex_home: self.codex_home.clone(),
            created_at_unix_seconds: self.created_at_unix_seconds,
            state: self.state,
            database_backup_complete: false,
            encrypted_payload: crypto::encrypt_json(key, &payload)?,
        };
        journal::store_manifest(&self.directory, &manifest)
    }
}

pub fn import_sessions(
    codex_home: &Path,
    source_root: &Path,
    journal_root: &Path,
    journal_key: &[u8; 32],
) -> Result<ImportSummary> {
    import_sessions_with_options(
        codex_home,
        source_root,
        ImportOptions::new(journal_root),
        journal_key,
        |_| {},
    )
}

pub fn import_sessions_with_options<F>(
    codex_home: &Path,
    source_root: &Path,
    options: ImportOptions,
    journal_key: &[u8; 32],
    mut progress: F,
) -> Result<ImportSummary>
where
    F: FnMut(Progress),
{
    let home = validate_codex_home(codex_home)?;
    let transaction_id = match options.transaction_id.as_deref() {
        Some(value) => Uuid::parse_str(value)
            .map_err(|_| {
                CoreError::new(
                    "invalid_transaction_id",
                    "Import transaction ID must be a UUID",
                )
            })?
            .to_string(),
        None => Uuid::new_v4().to_string(),
    };
    let mut transaction_lock = TransactionLock::acquire_for_repair(&home, &transaction_id)?;

    progress(Progress {
        phase: "inspect".to_string(),
        current: 0,
        total: 1,
    });
    let plan = build_import_plan(&home, source_root, &transaction_id)?;
    sqlite::ensure_import_ready(&home, &plan.rows)?;
    verify_destinations_absent(&home, &plan)?;
    progress(Progress {
        phase: "inspect".to_string(),
        current: 1,
        total: 1,
    });

    transaction_lock.update_stage("preparing_import_recovery")?;
    let mut recovery = ImportJournal::create(
        &home,
        &transaction_id,
        &options.journal_root,
        plan,
        journal_key,
    )?;

    let transaction_result = (|| -> Result<ImportSummary> {
        transaction_lock.update_stage("applying_import_rollouts")?;
        recovery.state = JournalState::ApplyingRollouts;
        recovery.store(journal_key)?;
        progress(Progress {
            phase: "rollouts".to_string(),
            current: 0,
            total: recovery.plan.files.len(),
        });
        for (index, file) in recovery.plan.files.iter().enumerate() {
            copy_import_file(&home, file)?;
            progress(Progress {
                phase: "rollouts".to_string(),
                current: index + 1,
                total: recovery.plan.files.len(),
            });
            if options.failure_point == Some(ImportFailurePoint::AfterFirstRollout) && index == 0 {
                return Err(CoreError::new(
                    "injected_failure",
                    "Injected failure after first imported rollout",
                ));
            }
        }
        if options.failure_point == Some(ImportFailurePoint::AfterRollouts) {
            return Err(CoreError::new(
                "injected_failure",
                "Injected failure after imported rollout writes",
            ));
        }

        transaction_lock.update_stage("applying_import_sqlite")?;
        recovery.state = JournalState::ApplyingSqlite;
        recovery.store(journal_key)?;
        let inserted = sqlite::insert_import_rows(&home, &recovery.plan.rows)?;
        if inserted != recovery.plan.rows.len() {
            return Err(CoreError::new(
                "import_verification_failed",
                "SQLite did not insert every imported thread",
            ));
        }
        progress(Progress {
            phase: "sqlite".to_string(),
            current: 1,
            total: 1,
        });
        if options.failure_point == Some(ImportFailurePoint::AfterSqlite) {
            return Err(CoreError::new(
                "injected_failure",
                "Injected failure after imported SQLite rows",
            ));
        }

        transaction_lock.update_stage("verifying_import")?;
        recovery.state = JournalState::Verifying;
        recovery.store(journal_key)?;
        verify_import_files(&home, &recovery.plan)?;
        sqlite::verify_import_rows(&home, &recovery.plan.rows)?;

        transaction_lock.update_stage("committed")?;
        recovery.state = JournalState::Committed;
        recovery.store(journal_key)?;
        progress(Progress {
            phase: "commit".to_string(),
            current: 1,
            total: 1,
        });
        Ok(ImportSummary {
            transaction_id: recovery.transaction_id.clone(),
            journal_path: recovery.directory.clone(),
            imported_sessions: recovery.plan.rows.len(),
            imported_rollout_files: recovery.plan.files.len(),
            conflict_policy: "reject_existing_thread_id".to_string(),
        })
    })();

    match transaction_result {
        Ok(summary) => Ok(summary),
        Err(primary) => {
            let _ = transaction_lock.update_stage("rollback_import");
            recovery.state = JournalState::RollbackRequired;
            let _ = recovery.store(journal_key);
            match rollback_loaded(&mut recovery, journal_key) {
                Ok(_) => Err(CoreError::new(
                    primary.code,
                    format!(
                        "{}; all imported sessions were rolled back",
                        primary.message
                    ),
                )),
                Err(rollback_error) => Err(CoreError::new(
                    "rollback_failed",
                    format!(
                        "{}; automatic import rollback failed: {}",
                        primary.message, rollback_error.message
                    ),
                )),
            }
        }
    }
}

pub(crate) fn rollback_import(
    journal_path: &Path,
    journal_key: &[u8; 32],
) -> Result<RollbackSummary> {
    let mut recovery = ImportJournal::load(journal_path, journal_key)?;
    let home = validate_codex_home(&recovery.codex_home)?;
    if home != recovery.codex_home {
        return Err(CoreError::new(
            "journal_home_mismatch",
            "Journal CODEX_HOME does not resolve to its recorded path",
        ));
    }
    let _lock = TransactionLock::acquire_for_rollback(&home, &recovery.transaction_id)?;
    rollback_loaded(&mut recovery, journal_key)
}

fn rollback_loaded(journal: &mut ImportJournal, key: &[u8; 32]) -> Result<RollbackSummary> {
    if journal.state == JournalState::RolledBack {
        return Ok(RollbackSummary {
            transaction_id: journal.transaction_id.clone(),
            journal_path: journal.directory.clone(),
            restored_rollout_files: 0,
            database_restored: true,
            already_rolled_back: true,
        });
    }
    journal.state = JournalState::RollbackRequired;
    journal.store(key)?;
    verify_rollback_files(&journal.codex_home, &journal.plan)?;
    remove_copy_stages(&journal.codex_home, &journal.plan)?;
    let quarantined = quarantine_destinations(&journal.codex_home, &journal.plan)?;
    let deleted = match sqlite::delete_import_rows(&journal.codex_home, &journal.plan.rows) {
        Ok(value) => value,
        Err(error) => {
            restore_quarantined(&journal.codex_home, &journal.plan, &quarantined)?;
            journal.state = JournalState::RollbackFailed;
            let _ = journal.store(key);
            return Err(error);
        }
    };
    if let Err(error) = remove_quarantined(&journal.codex_home, &journal.plan) {
        journal.state = JournalState::RollbackFailed;
        let _ = journal.store(key);
        return Err(error);
    }
    journal.state = JournalState::RolledBack;
    journal.store(key)?;
    Ok(RollbackSummary {
        transaction_id: journal.transaction_id.clone(),
        journal_path: journal.directory.clone(),
        restored_rollout_files: quarantined.len(),
        database_restored: deleted > 0,
        already_rolled_back: false,
    })
}

fn build_import_plan(home: &Path, source_root: &Path, transaction_id: &str) -> Result<ImportPlan> {
    let source = validate_source_root(home, source_root)?;
    let paths = collect_jsonl_files(&source)?;
    if paths.is_empty() {
        return Err(CoreError::new(
            "no_importable_sessions",
            "External source contains no JSONL rollout files",
        ));
    }
    let mut parsed = Vec::with_capacity(paths.len());
    let mut total_bytes = 0u64;
    let mut seen = HashSet::new();
    for path in paths {
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            CoreError::new(
                "source_unavailable",
                format!("Cannot inspect external rollout: {error}"),
            )
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(CoreError::new(
                "unsafe_source_path",
                "External rollout must be a regular non-symlink file",
            ));
        }
        if metadata.len() > MAX_FILE_BYTES {
            return Err(CoreError::new(
                "oversized_import_file",
                "External rollout exceeds the 64 MiB safety limit",
            ));
        }
        total_bytes = total_bytes.checked_add(metadata.len()).ok_or_else(|| {
            CoreError::new("source_too_large", "External rollout size overflowed")
        })?;
        if total_bytes > MAX_TOTAL_BYTES {
            return Err(CoreError::new(
                "source_too_large",
                "External session source exceeds the 512 MiB safety limit",
            ));
        }
        let item = parse_rollout(&path, &metadata)?;
        if !seen.insert(item.row.id.clone()) {
            return Err(CoreError::new(
                "duplicate_source_thread",
                "External source contains duplicate Thread IDs",
            ));
        }
        parsed.push(item);
    }

    let mut files = Vec::with_capacity(parsed.len());
    let mut rows = Vec::with_capacity(parsed.len());
    for mut item in parsed {
        let id = item.row.id.clone();
        let archived = item
            .source_path
            .strip_prefix(&source)
            .ok()
            .is_some_and(|relative| {
                relative
                    .components()
                    .any(|component| component.as_os_str() == "archived_sessions")
            });
        let destination_relative_path = PathBuf::from(if archived {
            "archived_sessions"
        } else {
            "sessions"
        })
        .join("imported")
        .join(format!("rollout-imported-{id}.jsonl"));
        let copy_stage_relative_path = PathBuf::from("tmp")
            .join("ai-access-import-stage")
            .join(transaction_id)
            .join(format!("{id}.jsonl"));
        let rollback_stage_relative_path = PathBuf::from("tmp")
            .join("ai-access-import-rollback")
            .join(transaction_id)
            .join(format!("{id}.jsonl"));
        let destination = safe_join(home, &destination_relative_path)?;
        item.row.rollout_path = destination.to_string_lossy().to_string();
        item.row.archived = i64::from(archived);
        item.row.archived_at = archived.then_some(item.row.updated_at);
        files.push(ImportFilePlan {
            source_path: item.source_path,
            destination_relative_path,
            copy_stage_relative_path,
            rollback_stage_relative_path,
            sha256: item.sha256,
            size_bytes: item.size_bytes,
        });
        rows.push(item.row);
    }
    Ok(ImportPlan {
        source_root: source,
        files,
        rows,
    })
}

struct ParsedImport {
    source_path: PathBuf,
    sha256: String,
    size_bytes: u64,
    row: ImportThreadRow,
}

#[derive(Default)]
struct MetadataFields {
    id: Option<String>,
    cwd: Option<String>,
    source: Option<String>,
    model_provider: Option<String>,
    title: Option<String>,
    cli_version: Option<String>,
    thread_source: Option<String>,
    git_sha: Option<String>,
    git_branch: Option<String>,
    git_origin_url: Option<String>,
    agent_nickname: Option<String>,
    agent_role: Option<String>,
    agent_path: Option<String>,
    model: Option<String>,
    reasoning_effort: Option<String>,
    sandbox_policy: Option<String>,
    approval_mode: Option<String>,
    first_user_message: Option<String>,
    timestamps_ms: Vec<i64>,
}

fn parse_rollout(path: &Path, metadata: &fs::Metadata) -> Result<ParsedImport> {
    let file = File::open(path).map_err(|error| {
        CoreError::new(
            "source_unavailable",
            format!("Cannot open external rollout: {error}"),
        )
    })?;
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut fields = MetadataFields::default();
    let mut ids = BTreeSet::new();
    let mut buffer = Vec::new();
    let mut line_number = 0usize;
    loop {
        buffer.clear();
        let read = reader.read_until(b'\n', &mut buffer).map_err(|error| {
            CoreError::new(
                "source_read_failed",
                format!("Cannot read external rollout: {error}"),
            )
        })?;
        if read == 0 {
            break;
        }
        line_number += 1;
        hasher.update(&buffer);
        let text = std::str::from_utf8(&buffer).map_err(|_| {
            CoreError::new(
                "invalid_rollout_encoding",
                format!("External rollout is not UTF-8 at line {line_number}"),
            )
        })?;
        let body = text.trim_end_matches(['\r', '\n']);
        if body.trim().is_empty() {
            continue;
        }
        let record: Value = serde_json::from_str(body).map_err(|error| {
            CoreError::new(
                "invalid_rollout_json",
                format!("Invalid external rollout JSON at line {line_number}: {error}"),
            )
        })?;
        if let Some(value) = timestamp_from_value(record.get("timestamp")) {
            fields.timestamps_ms.push(value);
        }
        let kind = record
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let payload = record.get("payload").unwrap_or(&Value::Null);
        match kind {
            "session_meta" => parse_session_meta(payload, &mut fields, &mut ids)?,
            "turn_context" => parse_turn_context(payload, &mut fields),
            "event_msg" | "response_item" if fields.first_user_message.is_none() => {
                fields.first_user_message = extract_user_message(kind, payload);
            }
            _ => {}
        }
    }
    if ids.len() != 1 {
        return Err(CoreError::new(
            "ambiguous_thread_id",
            "External rollout must contain exactly one Thread ID",
        ));
    }
    let id = ids.into_iter().next().expect("one checked Thread ID");
    let fallback_ms = metadata
        .modified()
        .unwrap_or(UNIX_EPOCH)
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64;
    let created_ms = fields
        .timestamps_ms
        .iter()
        .copied()
        .min()
        .unwrap_or(fallback_ms);
    let updated_ms = fields
        .timestamps_ms
        .iter()
        .copied()
        .max()
        .unwrap_or(created_ms);
    let first_user_message =
        truncate_text(fields.first_user_message.as_deref().unwrap_or(""), 4_096);
    let title_source = fields
        .title
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(&first_user_message);
    let title = truncate_text(title_source.lines().next().unwrap_or(""), 120);
    let preview = truncate_text(&first_user_message, 512);
    let provider = fields
        .model_provider
        .unwrap_or_else(|| "openai".to_string());
    validate_provider(&provider)?;
    let canonical_source = fs::canonicalize(path).map_err(|error| {
        CoreError::new(
            "source_unavailable",
            format!("Cannot resolve external rollout: {error}"),
        )
    })?;
    Ok(ParsedImport {
        source_path: canonical_source,
        sha256: digest_hex(hasher.finalize()),
        size_bytes: metadata.len(),
        row: ImportThreadRow {
            id,
            rollout_path: String::new(),
            created_at: created_ms.div_euclid(1_000),
            updated_at: updated_ms.div_euclid(1_000),
            source: fields.source.unwrap_or_else(|| "cli".to_string()),
            model_provider: provider,
            cwd: fields.cwd.unwrap_or_default(),
            title,
            sandbox_policy: fields
                .sandbox_policy
                .unwrap_or_else(|| "read-only".to_string()),
            approval_mode: fields
                .approval_mode
                .unwrap_or_else(|| "on-request".to_string()),
            tokens_used: 0,
            has_user_event: i64::from(!first_user_message.is_empty()),
            archived: 0,
            archived_at: None,
            git_sha: fields.git_sha,
            git_branch: fields.git_branch,
            git_origin_url: fields.git_origin_url,
            cli_version: fields.cli_version.unwrap_or_default(),
            first_user_message,
            agent_nickname: fields.agent_nickname,
            agent_role: fields.agent_role,
            memory_mode: "enabled".to_string(),
            model: fields.model,
            reasoning_effort: fields.reasoning_effort,
            agent_path: fields.agent_path,
            created_at_ms: Some(created_ms),
            updated_at_ms: Some(updated_ms),
            thread_source: fields.thread_source,
            preview,
            recency_at: updated_ms.div_euclid(1_000),
            recency_at_ms: updated_ms,
            history_mode: "legacy".to_string(),
            name: None,
            is_pinned: 0,
            thread_section_id: None,
            section_position: None,
            section_entered_at_ms: None,
        },
    })
}

fn parse_session_meta(
    payload: &Value,
    fields: &mut MetadataFields,
    ids: &mut BTreeSet<String>,
) -> Result<()> {
    let object = payload.as_object().ok_or_else(|| {
        CoreError::new(
            "invalid_session_meta",
            "session_meta payload is not an object",
        )
    })?;
    let raw_id = object
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::new("missing_thread_id", "session_meta has no Thread ID"))?;
    let id = Uuid::parse_str(raw_id)
        .map_err(|_| CoreError::new("invalid_thread_id", "Thread ID is not a UUID"))?
        .to_string();
    ids.insert(id.clone());
    fields.id = Some(id);
    update_text(&mut fields.cwd, object.get("cwd"));
    update_text(&mut fields.model_provider, object.get("model_provider"));
    update_text(
        &mut fields.title,
        object.get("title").or_else(|| object.get("name")),
    );
    update_text(&mut fields.cli_version, object.get("cli_version"));
    update_text(&mut fields.agent_nickname, object.get("agent_nickname"));
    update_text(&mut fields.agent_role, object.get("agent_role"));
    update_text(&mut fields.agent_path, object.get("agent_path"));
    if let Some(value) = object.get("source") {
        fields.source = value_to_db_string(value);
    }
    if let Some(value) = object.get("thread_source") {
        fields.thread_source = value_to_db_string(value);
    }
    if let Some(value) = timestamp_from_value(object.get("timestamp")) {
        fields.timestamps_ms.push(value);
    }
    if let Some(git) = object.get("git").and_then(Value::as_object) {
        update_text(
            &mut fields.git_sha,
            git.get("commit_hash").or_else(|| git.get("sha")),
        );
        update_text(&mut fields.git_branch, git.get("branch"));
        update_text(
            &mut fields.git_origin_url,
            git.get("repository_url").or_else(|| git.get("origin_url")),
        );
    }
    Ok(())
}

fn parse_turn_context(payload: &Value, fields: &mut MetadataFields) {
    let Some(object) = payload.as_object() else {
        return;
    };
    update_text(&mut fields.model, object.get("model"));
    update_text(
        &mut fields.reasoning_effort,
        object
            .get("effort")
            .or_else(|| object.get("reasoning_effort")),
    );
    if let Some(value) = object.get("sandbox_policy") {
        fields.sandbox_policy = value_to_db_string(value);
    }
    if let Some(value) = object
        .get("approval_policy")
        .or_else(|| object.get("approval_mode"))
    {
        fields.approval_mode = value_to_db_string(value);
    }
}

fn extract_user_message(kind: &str, payload: &Value) -> Option<String> {
    let object = payload.as_object()?;
    if kind == "event_msg" {
        let event_type = object.get("type").and_then(Value::as_str)?;
        if !matches!(event_type, "user_message" | "user_input") {
            return None;
        }
        return visible_text(
            object
                .get("message")
                .or_else(|| object.get("text"))
                .or_else(|| object.get("input"))?,
        );
    }
    if object.get("type").and_then(Value::as_str) != Some("message")
        || object.get("role").and_then(Value::as_str) != Some("user")
    {
        return None;
    }
    visible_text(object.get("content")?)
}

fn visible_text(value: &Value) -> Option<String> {
    match value {
        Value::String(value) => nonempty(value),
        Value::Array(values) => {
            let text = values
                .iter()
                .filter_map(visible_text)
                .collect::<Vec<_>>()
                .join("\n");
            nonempty(&text)
        }
        Value::Object(object) => object
            .get("text")
            .or_else(|| object.get("input_text"))
            .or_else(|| object.get("message"))
            .and_then(visible_text),
        _ => None,
    }
}

fn update_text(target: &mut Option<String>, value: Option<&Value>) {
    if let Some(value) = value.and_then(Value::as_str).and_then(nonempty) {
        *target = Some(value);
    }
}

fn nonempty(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn value_to_db_string(value: &Value) -> Option<String> {
    match value {
        Value::Null => None,
        Value::String(value) => nonempty(value),
        _ => serde_json::to_string(value)
            .ok()
            .and_then(|value| nonempty(&value)),
    }
}

fn truncate_text(value: &str, maximum_characters: usize) -> String {
    value.chars().take(maximum_characters).collect()
}

fn timestamp_from_value(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(value) => {
            let number = value.as_f64()?;
            if !number.is_finite() {
                return None;
            }
            let milliseconds = if number.abs() >= 1_000_000_000_000.0 {
                number
            } else {
                number * 1_000.0
            };
            Some(milliseconds.round() as i64)
        }
        Value::String(value) => value
            .parse::<f64>()
            .ok()
            .and_then(|number| {
                let value = if number.abs() >= 1_000_000_000_000.0 {
                    number
                } else {
                    number * 1_000.0
                };
                value.is_finite().then_some(value.round() as i64)
            })
            .or_else(|| parse_rfc3339_milliseconds(value)),
        _ => None,
    }
}

fn parse_rfc3339_milliseconds(value: &str) -> Option<i64> {
    let (date, time_zone) = value.split_once('T').or_else(|| value.split_once(' '))?;
    let mut date_parts = date.split('-');
    let year = date_parts.next()?.parse::<i64>().ok()?;
    let month = date_parts.next()?.parse::<i64>().ok()?;
    let day = date_parts.next()?.parse::<i64>().ok()?;
    if date_parts.next().is_some() || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let (time, offset_seconds) = if let Some(time) = time_zone.strip_suffix('Z') {
        (time, 0i64)
    } else {
        let offset_index = time_zone
            .char_indices()
            .rev()
            .find(|(index, character)| *index > 0 && matches!(character, '+' | '-'))
            .map(|(index, _)| index)?;
        let (time, offset) = time_zone.split_at(offset_index);
        let sign = if offset.starts_with('-') { -1 } else { 1 };
        let mut offset_parts = offset[1..].split(':');
        let hours = offset_parts.next()?.parse::<i64>().ok()?;
        let minutes = offset_parts.next()?.parse::<i64>().ok()?;
        if offset_parts.next().is_some() || hours > 23 || minutes > 59 {
            return None;
        }
        (time, sign * (hours * 3_600 + minutes * 60))
    };
    let mut time_parts = time.split(':');
    let hour = time_parts.next()?.parse::<i64>().ok()?;
    let minute = time_parts.next()?.parse::<i64>().ok()?;
    let second_fraction = time_parts.next()?;
    if time_parts.next().is_some() || hour > 23 || minute > 59 {
        return None;
    }
    let (second_text, fraction) = second_fraction
        .split_once('.')
        .map_or((second_fraction, ""), |value| value);
    let second = second_text.parse::<i64>().ok()?;
    if second > 60 {
        return None;
    }
    let mut fraction_digits = fraction
        .chars()
        .take(3)
        .map(|character| character.to_digit(10))
        .collect::<Option<Vec<_>>>()?;
    while fraction_digits.len() < 3 {
        fraction_digits.push(0);
    }
    let milliseconds = fraction_digits
        .into_iter()
        .fold(0i64, |value, digit| value * 10 + i64::from(digit));
    let days = days_from_civil(year, month, day)?;
    let seconds = days
        .checked_mul(86_400)?
        .checked_add(hour * 3_600 + minute * 60 + second)?
        .checked_sub(offset_seconds)?;
    seconds.checked_mul(1_000)?.checked_add(milliseconds)
}

fn days_from_civil(mut year: i64, month: i64, day: i64) -> Option<i64> {
    year -= i64::from(month <= 2);
    let era = if year >= 0 { year } else { year - 399 }.div_euclid(400);
    let year_of_era = year - era * 400;
    let shifted_month = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * shifted_month + 2).div_euclid(5) + day - 1;
    let day_of_era =
        year_of_era * 365 + year_of_era.div_euclid(4) - year_of_era.div_euclid(100) + day_of_year;
    Some(era * 146_097 + day_of_era - 719_468)
}

fn validate_source_root(home: &Path, source_root: &Path) -> Result<PathBuf> {
    if !source_root.is_absolute() {
        return Err(CoreError::new(
            "invalid_source_root",
            "External source root must be an explicit absolute path",
        ));
    }
    let metadata = fs::symlink_metadata(source_root).map_err(|error| {
        CoreError::new(
            "source_unavailable",
            format!("Cannot inspect external source root: {error}"),
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(CoreError::new(
            "unsafe_source_root",
            "External source root must be a real directory",
        ));
    }
    let source = fs::canonicalize(source_root).map_err(|error| {
        CoreError::new(
            "source_unavailable",
            format!("Cannot resolve external source root: {error}"),
        )
    })?;
    if source.starts_with(home) || home.starts_with(&source) {
        return Err(CoreError::new(
            "source_overlaps_codex_home",
            "External source must not overlap current CODEX_HOME",
        ));
    }
    Ok(source)
}

fn collect_jsonl_files(root: &Path) -> Result<Vec<PathBuf>> {
    let mut pending = vec![root.to_path_buf()];
    let mut files = Vec::new();
    while let Some(directory) = pending.pop() {
        let entries = fs::read_dir(&directory).map_err(|error| {
            CoreError::new(
                "source_unavailable",
                format!("Cannot read external source directory: {error}"),
            )
        })?;
        for entry in entries {
            let entry = entry.map_err(|error| {
                CoreError::new(
                    "source_unavailable",
                    format!("Cannot inspect external source entry: {error}"),
                )
            })?;
            let path = entry.path();
            let metadata = fs::symlink_metadata(&path).map_err(|error| {
                CoreError::new(
                    "source_unavailable",
                    format!("Cannot inspect external source entry: {error}"),
                )
            })?;
            if metadata.file_type().is_symlink() {
                return Err(CoreError::new(
                    "unsafe_source_path",
                    "External source must not contain symbolic links",
                ));
            }
            if metadata.is_dir() {
                pending.push(path);
            } else if metadata.is_file()
                && path
                    .extension()
                    .and_then(|value| value.to_str())
                    .is_some_and(|value| value.eq_ignore_ascii_case("jsonl"))
            {
                files.push(path);
                if files.len() > MAX_FILES {
                    return Err(CoreError::new(
                        "too_many_import_files",
                        "External source exceeds the 2000-file safety limit",
                    ));
                }
            }
        }
    }
    files.sort();
    Ok(files)
}

fn verify_destinations_absent(home: &Path, plan: &ImportPlan) -> Result<()> {
    for file in &plan.files {
        for relative in [
            &file.destination_relative_path,
            &file.copy_stage_relative_path,
            &file.rollback_stage_relative_path,
        ] {
            let path = safe_join(home, relative)?;
            match fs::symlink_metadata(&path) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Ok(_) => {
                    return Err(CoreError::new(
                        "import_destination_conflict",
                        "Import destination or staging path already exists",
                    ));
                }
                Err(error) => {
                    return Err(CoreError::new(
                        "destination_unavailable",
                        format!("Cannot inspect import destination: {error}"),
                    ));
                }
            }
        }
    }
    Ok(())
}

fn copy_import_file(home: &Path, plan: &ImportFilePlan) -> Result<()> {
    let destination = safe_join(home, &plan.destination_relative_path)?;
    let stage = safe_join(home, &plan.copy_stage_relative_path)?;
    ensure_private_parent(home, &plan.destination_relative_path)?;
    ensure_private_parent(home, &plan.copy_stage_relative_path)?;
    let source_metadata = fs::symlink_metadata(&plan.source_path).map_err(|error| {
        CoreError::new(
            "source_unavailable",
            format!("Cannot inspect external rollout during import: {error}"),
        )
    })?;
    if source_metadata.file_type().is_symlink()
        || !source_metadata.is_file()
        || source_metadata.len() != plan.size_bytes
    {
        return Err(CoreError::new(
            "concurrent_source_change",
            "External rollout changed after preflight",
        ));
    }
    let mut source = File::open(&plan.source_path).map_err(read_error)?;
    let mut target = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&stage)
        .map_err(write_error)?;
    set_private_file_permissions(&stage)?;
    let mut hasher = Sha256::new();
    let mut copied = 0u64;
    let mut buffer = [0u8; 64 * 1_024];
    let copy_result = (|| -> Result<()> {
        loop {
            let read = source.read(&mut buffer).map_err(read_error)?;
            if read == 0 {
                break;
            }
            copied = copied.checked_add(read as u64).ok_or_else(|| {
                CoreError::new("source_too_large", "External rollout size overflowed")
            })?;
            if copied > plan.size_bytes || copied > MAX_FILE_BYTES {
                return Err(CoreError::new(
                    "concurrent_source_change",
                    "External rollout grew after preflight",
                ));
            }
            hasher.update(&buffer[..read]);
            target.write_all(&buffer[..read]).map_err(write_error)?;
        }
        target.sync_all().map_err(write_error)?;
        Ok(())
    })();
    drop(target);
    copy_result?;
    if copied != plan.size_bytes || digest_hex(hasher.finalize()) != plan.sha256 {
        return Err(CoreError::new(
            "concurrent_source_change",
            "External rollout bytes changed after preflight",
        ));
    }
    fs::hard_link(&stage, &destination).map_err(|error| {
        CoreError::new(
            "atomic_import_failed",
            format!("Cannot publish imported rollout atomically: {error}"),
        )
    })?;
    sync_directory(destination.parent().expect("destination parent"))?;
    fs::remove_file(&stage).map_err(write_error)?;
    sync_directory(stage.parent().expect("stage parent"))?;
    Ok(())
}

fn verify_import_files(home: &Path, plan: &ImportPlan) -> Result<()> {
    for file in &plan.files {
        let destination = safe_join(home, &file.destination_relative_path)?;
        verify_exact_file(&destination, &file.sha256, "import_verification_failed")?;
        let stage = safe_join(home, &file.copy_stage_relative_path)?;
        if stage.exists() {
            return Err(CoreError::new(
                "import_verification_failed",
                "Import staging file remained after commit",
            ));
        }
    }
    Ok(())
}

fn verify_rollback_files(home: &Path, plan: &ImportPlan) -> Result<()> {
    for file in &plan.files {
        let destination = safe_join(home, &file.destination_relative_path)?;
        let copy_stage = safe_join(home, &file.copy_stage_relative_path)?;
        let rollback_stage = safe_join(home, &file.rollback_stage_relative_path)?;
        verify_optional_exact(&destination, &file.sha256)?;
        verify_optional_exact(&copy_stage, &file.sha256)?;
        verify_optional_exact(&rollback_stage, &file.sha256)?;
        if destination.exists() && rollback_stage.exists() {
            return Err(CoreError::new(
                "concurrent_rollout_change",
                "Imported rollout exists in both live and rollback locations",
            ));
        }
    }
    Ok(())
}

fn remove_copy_stages(home: &Path, plan: &ImportPlan) -> Result<()> {
    for file in &plan.files {
        let path = safe_join(home, &file.copy_stage_relative_path)?;
        remove_exact_if_present(&path, &file.sha256)?;
    }
    Ok(())
}

fn quarantine_destinations(home: &Path, plan: &ImportPlan) -> Result<Vec<usize>> {
    let mut quarantined = Vec::new();
    for (index, file) in plan.files.iter().enumerate() {
        let destination = safe_join(home, &file.destination_relative_path)?;
        let rollback_stage = safe_join(home, &file.rollback_stage_relative_path)?;
        ensure_private_parent(home, &file.rollback_stage_relative_path)?;
        if rollback_stage.exists() {
            quarantined.push(index);
            continue;
        }
        if !destination.exists() {
            continue;
        }
        if let Err(error) = fs::rename(&destination, &rollback_stage) {
            restore_quarantined(home, plan, &quarantined)?;
            return Err(CoreError::new(
                "rollback_write_failed",
                format!("Cannot quarantine imported rollout: {error}"),
            ));
        }
        sync_directory(destination.parent().expect("destination parent"))?;
        sync_directory(rollback_stage.parent().expect("rollback parent"))?;
        quarantined.push(index);
    }
    Ok(quarantined)
}

fn restore_quarantined(home: &Path, plan: &ImportPlan, indices: &[usize]) -> Result<()> {
    for index in indices.iter().rev() {
        let file = plan
            .files
            .get(*index)
            .ok_or_else(|| CoreError::new("invalid_journal", "Import rollback index is invalid"))?;
        let destination = safe_join(home, &file.destination_relative_path)?;
        let rollback_stage = safe_join(home, &file.rollback_stage_relative_path)?;
        if !rollback_stage.exists() {
            continue;
        }
        if destination.exists() {
            return Err(CoreError::new(
                "rollback_compensation_failed",
                "Cannot restore quarantined rollout over a live file",
            ));
        }
        fs::rename(&rollback_stage, &destination).map_err(|error| {
            CoreError::new(
                "rollback_compensation_failed",
                format!("Cannot restore quarantined rollout: {error}"),
            )
        })?;
    }
    Ok(())
}

fn remove_quarantined(home: &Path, plan: &ImportPlan) -> Result<()> {
    for file in &plan.files {
        let path = safe_join(home, &file.rollback_stage_relative_path)?;
        remove_exact_if_present(&path, &file.sha256)?;
    }
    Ok(())
}

fn remove_exact_if_present(path: &Path, expected_sha256: &str) -> Result<()> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(CoreError::new(
            "rollback_write_failed",
            format!("Cannot inspect rollback file: {error}"),
        )),
        Ok(_) => {
            verify_exact_file(path, expected_sha256, "concurrent_rollout_change")?;
            fs::remove_file(path).map_err(|error| {
                CoreError::new(
                    "rollback_write_failed",
                    format!("Cannot remove imported rollout: {error}"),
                )
            })
        }
    }
}

fn verify_optional_exact(path: &Path, expected_sha256: &str) -> Result<()> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(CoreError::new(
            "rollout_unavailable",
            format!("Cannot inspect imported rollout: {error}"),
        )),
        Ok(_) => verify_exact_file(path, expected_sha256, "concurrent_rollout_change"),
    }
}

fn verify_exact_file(path: &Path, expected_sha256: &str, code: &'static str) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CoreError::new(code, format!("Cannot inspect imported rollout: {error}"))
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(CoreError::new(
            "unsafe_rollout_path",
            "Imported rollout must be a regular non-symlink file",
        ));
    }
    if hash_file(path)? != expected_sha256 {
        return Err(CoreError::new(
            code,
            "Imported rollout changed after session transaction",
        ));
    }
    Ok(())
}

fn ensure_private_parent(home: &Path, relative_file: &Path) -> Result<()> {
    let parent = relative_file
        .parent()
        .ok_or_else(|| CoreError::new("unsafe_rollout_path", "Import path has no parent"))?;
    let mut current = home.to_path_buf();
    for component in parent.components() {
        let Component::Normal(component) = component else {
            return Err(CoreError::new(
                "unsafe_rollout_path",
                "Import path contains an unsafe component",
            ));
        };
        current.push(component);
        match fs::symlink_metadata(&current) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() || !metadata.is_dir() {
                    return Err(CoreError::new(
                        "unsafe_rollout_path",
                        "Import parent must be a real directory",
                    ));
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&current).map_err(|error| {
                    CoreError::new(
                        "destination_unavailable",
                        format!("Cannot create import directory: {error}"),
                    )
                })?;
                set_private_directory_permissions(&current)?;
            }
            Err(error) => {
                return Err(CoreError::new(
                    "destination_unavailable",
                    format!("Cannot inspect import directory: {error}"),
                ));
            }
        }
    }
    Ok(())
}

fn safe_join(home: &Path, relative: &Path) -> Result<PathBuf> {
    if relative.is_absolute()
        || relative
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(CoreError::new(
            "unsafe_rollout_path",
            "Import path must be a safe relative path",
        ));
    }
    Ok(home.join(relative))
}

fn hash_file(path: &Path) -> Result<String> {
    let mut file = File::open(path).map_err(read_error)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1_024];
    loop {
        let read = file.read(&mut buffer).map_err(read_error)?;
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

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn read_error(error: std::io::Error) -> CoreError {
    CoreError::new("source_read_failed", error.to_string())
}

fn write_error(error: std::io::Error) -> CoreError {
    CoreError::new("atomic_import_failed", error.to_string())
}

fn set_private_file_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|error| {
        CoreError::new(
            "permission_failed",
            format!("Cannot secure imported rollout: {error}"),
        )
    })?;
    Ok(())
}

fn set_private_directory_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|error| {
        CoreError::new(
            "permission_failed",
            format!("Cannot secure import directory: {error}"),
        )
    })?;
    Ok(())
}

fn sync_directory(path: &Path) -> Result<()> {
    #[cfg(unix)]
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| {
            CoreError::new(
                "atomic_import_failed",
                format!("Cannot sync import directory: {error}"),
            )
        })?;
    Ok(())
}
