// SPDX-License-Identifier: AGPL-3.0-only
//
// Provider visibility behavior adapted from CodexPlusPlus v1.2.41:
// https://github.com/BigPizzaV3/CodexPlusPlus
// commit 3dafffcafb2566a1e8bce4b35671656d6adb3eda
// See ../THIRD_PARTY_NOTICES.md.

mod crypto;
mod journal;
mod rollout;
mod session_import;
mod sqlite;

pub use session_import::{
    import_sessions, import_sessions_with_options, ImportFailurePoint, ImportOptions, ImportSummary,
};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use thiserror::Error;
use uuid::Uuid;

pub const PROTOCOL_VERSION: u32 = 1;
pub const DEFAULT_PAGE_SIZE: usize = 50;
pub const MAX_PAGE_SIZE: usize = 50;
pub const MAX_WORKSPACE_PATH_SIZE: usize = 4096;
pub const MAX_WORKSPACE_LOOKUP_SIZE: usize = 20;

#[derive(Debug, Error)]
#[error("{message}")]
pub struct CoreError {
    pub code: &'static str,
    pub message: String,
}

impl CoreError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

pub type Result<T> = std::result::Result<T, CoreError>;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionRow {
    pub id: String,
    pub title: String,
    pub cwd: String,
    pub current_provider: String,
    pub archived: bool,
    pub created_at: Value,
    pub updated_at: Value,
    pub rollout_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionPage {
    pub database_path: PathBuf,
    pub total: usize,
    pub visible_total: Option<usize>,
    pub limit: usize,
    pub offset: usize,
    pub has_more: bool,
    pub sessions: Vec<SessionRow>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceRow {
    pub cwd: String,
    pub session_count: usize,
    pub archived_count: usize,
    pub latest_updated_at: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WorkspacePage {
    pub database_path: PathBuf,
    pub total: usize,
    pub limit: usize,
    pub offset: usize,
    pub has_more: bool,
    pub workspaces: Vec<WorkspaceRow>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PendingJournal {
    pub transaction_id: String,
    pub journal_path: Option<PathBuf>,
    pub prewrite: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ClearedPrewriteLock {
    pub transaction_id: String,
    pub cleared: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct InspectSummary {
    pub codex_home: PathBuf,
    pub database_path: PathBuf,
    pub target_provider: String,
    pub rollout_files: usize,
    pub session_meta_records: usize,
    pub rollout_files_needing_repair: usize,
    pub encrypted_content_files: usize,
    pub sqlite_threads: usize,
    pub sqlite_provider_mismatches: usize,
    pub sqlite_user_event_mismatches: usize,
    pub sqlite_cwd_mismatches: usize,
    pub needs_repair: bool,
    pub estimated_journal_bytes: u64,
    pub journal_limit_bytes: u64,
    pub rollout_patch_count: usize,
    pub capacity_safe: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RepairSummary {
    pub transaction_id: Option<String>,
    pub journal_path: Option<PathBuf>,
    pub target_provider: String,
    pub changed_rollout_files: usize,
    pub changed_session_meta_records: usize,
    pub sqlite_provider_rows_updated: usize,
    pub sqlite_user_event_rows_updated: usize,
    pub sqlite_cwd_rows_updated: usize,
    pub no_changes: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RollbackSummary {
    pub transaction_id: String,
    pub journal_path: PathBuf,
    pub restored_rollout_files: usize,
    pub database_restored: bool,
    pub already_rolled_back: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FailurePoint {
    AfterFirstRollout,
    AfterRollouts,
    AfterSqlite,
}

#[derive(Debug, Clone)]
pub struct RepairOptions {
    pub journal_root: PathBuf,
    pub failure_point: Option<FailurePoint>,
    pub transaction_id: Option<String>,
}

impl RepairOptions {
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
pub struct Progress {
    pub phase: String,
    pub current: usize,
    pub total: usize,
}

pub fn list_sessions(codex_home: &Path, limit: usize, offset: usize) -> Result<SessionPage> {
    list_sessions_for_provider(codex_home, limit, offset, None)
}

pub fn list_sessions_for_provider(
    codex_home: &Path,
    limit: usize,
    offset: usize,
    provider: Option<&str>,
) -> Result<SessionPage> {
    list_sessions_scoped(codex_home, limit, offset, provider, false)
}

pub fn list_conversations_for_provider(
    codex_home: &Path,
    limit: usize,
    offset: usize,
    provider: Option<&str>,
) -> Result<SessionPage> {
    list_sessions_scoped(codex_home, limit, offset, provider, true)
}

fn list_sessions_scoped(
    codex_home: &Path,
    limit: usize,
    offset: usize,
    provider: Option<&str>,
    top_level_only: bool,
) -> Result<SessionPage> {
    let home = validate_codex_home(codex_home)?;
    if let Some(provider) = provider {
        validate_provider(provider)?;
    }
    let bounded_limit = if limit == 0 {
        DEFAULT_PAGE_SIZE
    } else {
        limit.min(MAX_PAGE_SIZE)
    };
    sqlite::list_sessions(&home, bounded_limit, offset, provider, top_level_only)
}

pub fn search_sessions_for_provider(
    codex_home: &Path,
    query: &str,
    limit: usize,
    offset: usize,
    provider: Option<&str>,
) -> Result<SessionPage> {
    search_sessions_scoped(codex_home, query, limit, offset, provider, false)
}

pub fn search_conversations_for_provider(
    codex_home: &Path,
    query: &str,
    limit: usize,
    offset: usize,
    provider: Option<&str>,
) -> Result<SessionPage> {
    search_sessions_scoped(codex_home, query, limit, offset, provider, true)
}

fn search_sessions_scoped(
    codex_home: &Path,
    query: &str,
    limit: usize,
    offset: usize,
    provider: Option<&str>,
    top_level_only: bool,
) -> Result<SessionPage> {
    let home = validate_codex_home(codex_home)?;
    if let Some(provider) = provider {
        validate_provider(provider)?;
    }
    let query = query.trim();
    if query.is_empty() || query.chars().count() > 200 || query.chars().any(char::is_control) {
        return Err(CoreError::new(
            "invalid_search_query",
            "Search query must contain 1 to 200 non-control characters",
        ));
    }
    let bounded_limit = if limit == 0 {
        DEFAULT_PAGE_SIZE
    } else {
        limit.min(MAX_PAGE_SIZE)
    };
    sqlite::search_sessions(
        &home,
        query,
        bounded_limit,
        offset,
        provider,
        top_level_only,
    )
}

pub fn list_workspaces(codex_home: &Path, limit: usize, offset: usize) -> Result<WorkspacePage> {
    list_workspaces_scoped(codex_home, limit, offset, false)
}

pub fn list_conversation_workspaces(
    codex_home: &Path,
    limit: usize,
    offset: usize,
) -> Result<WorkspacePage> {
    list_workspaces_scoped(codex_home, limit, offset, true)
}

fn list_workspaces_scoped(
    codex_home: &Path,
    limit: usize,
    offset: usize,
    top_level_only: bool,
) -> Result<WorkspacePage> {
    let home = validate_codex_home(codex_home)?;
    let bounded_limit = if limit == 0 {
        DEFAULT_PAGE_SIZE
    } else {
        limit.min(MAX_PAGE_SIZE)
    };
    sqlite::list_workspaces(&home, bounded_limit, offset, top_level_only)
}

pub fn lookup_workspaces(codex_home: &Path, workspaces: &[String]) -> Result<WorkspacePage> {
    lookup_workspaces_scoped(codex_home, workspaces, false)
}

pub fn lookup_conversation_workspaces(
    codex_home: &Path,
    workspaces: &[String],
) -> Result<WorkspacePage> {
    lookup_workspaces_scoped(codex_home, workspaces, true)
}

fn lookup_workspaces_scoped(
    codex_home: &Path,
    workspaces: &[String],
    top_level_only: bool,
) -> Result<WorkspacePage> {
    let home = validate_codex_home(codex_home)?;
    if workspaces.is_empty() || workspaces.len() > MAX_WORKSPACE_LOOKUP_SIZE {
        return Err(CoreError::new(
            "invalid_workspace_paths",
            "Workspace lookup requires 1 to 20 paths",
        ));
    }
    let mut normalized = Vec::with_capacity(workspaces.len());
    for workspace in workspaces {
        let workspace = validate_workspace_path(workspace)?;
        if !normalized.contains(&workspace) {
            normalized.push(workspace);
        }
    }
    sqlite::lookup_workspaces(&home, &normalized, top_level_only)
}

pub fn list_workspace_sessions_for_provider(
    codex_home: &Path,
    cwd: &str,
    limit: usize,
    offset: usize,
    provider: Option<&str>,
) -> Result<SessionPage> {
    list_workspace_sessions_scoped(codex_home, cwd, limit, offset, provider, false)
}

pub fn list_workspace_conversations_for_provider(
    codex_home: &Path,
    cwd: &str,
    limit: usize,
    offset: usize,
    provider: Option<&str>,
) -> Result<SessionPage> {
    list_workspace_sessions_scoped(codex_home, cwd, limit, offset, provider, true)
}

fn list_workspace_sessions_scoped(
    codex_home: &Path,
    cwd: &str,
    limit: usize,
    offset: usize,
    provider: Option<&str>,
    top_level_only: bool,
) -> Result<SessionPage> {
    let home = validate_codex_home(codex_home)?;
    if let Some(provider) = provider {
        validate_provider(provider)?;
    }
    let cwd = validate_workspace_path(cwd)?;
    let bounded_limit = if limit == 0 {
        DEFAULT_PAGE_SIZE
    } else {
        limit.min(MAX_PAGE_SIZE)
    };
    sqlite::list_workspace_sessions(&home, &cwd, bounded_limit, offset, provider, top_level_only)
}

fn validate_workspace_path(value: &str) -> Result<String> {
    let workspace = value.trim();
    if workspace.is_empty()
        || workspace.chars().count() > MAX_WORKSPACE_PATH_SIZE
        || workspace.chars().any(char::is_control)
    {
        return Err(CoreError::new(
            "invalid_workspace_path",
            "Workspace path must contain 1 to 4096 non-control characters",
        ));
    }
    Ok(workspace.to_string())
}

pub fn inspect(codex_home: &Path, target_provider: &str) -> Result<InspectSummary> {
    let home = validate_codex_home(codex_home)?;
    validate_provider(target_provider)?;
    let plan = rollout::build_plan(&home, target_provider)?;
    let db = sqlite::inspect_database(&home, target_provider, &plan.evidence)?;
    let database_recovery =
        sqlite::database_recovery_state(&home, target_provider, &plan.evidence)?;
    let estimated_journal_bytes =
        journal::estimated_manifest_bytes(&home, target_provider, &plan, &database_recovery)?;
    let rollout_patch_count = plan.files.iter().map(|file| file.patches.len()).sum();
    Ok(InspectSummary {
        codex_home: home.clone(),
        database_path: sqlite::active_database_path(&home),
        target_provider: target_provider.to_string(),
        rollout_files: plan.files.len(),
        session_meta_records: plan.session_meta_records,
        rollout_files_needing_repair: plan
            .files
            .iter()
            .filter(|file| !file.patches.is_empty())
            .count(),
        encrypted_content_files: plan.encrypted_content_files,
        sqlite_threads: db.total_threads,
        sqlite_provider_mismatches: db.provider_mismatches,
        sqlite_user_event_mismatches: db.user_event_mismatches,
        sqlite_cwd_mismatches: db.cwd_mismatches,
        needs_repair: plan.files.iter().any(|file| !file.patches.is_empty())
            || db.provider_mismatches > 0
            || db.user_event_mismatches > 0
            || db.cwd_mismatches > 0,
        estimated_journal_bytes,
        journal_limit_bytes: journal::MAX_JOURNAL_BYTES,
        rollout_patch_count,
        capacity_safe: estimated_journal_bytes <= journal::MAX_JOURNAL_BYTES,
    })
}

pub fn interrupted_journal(
    codex_home: &Path,
    recovery_root: &Path,
) -> Result<Option<PendingJournal>> {
    let home = validate_codex_home(codex_home)?;
    journal::interrupted_journal(&home, recovery_root)
}

pub fn clear_stale_prewrite_lock(
    codex_home: &Path,
    recovery_root: &Path,
    transaction_id: &str,
) -> Result<ClearedPrewriteLock> {
    let home = validate_codex_home(codex_home)?;
    journal::clear_stale_prewrite_lock(&home, recovery_root, transaction_id)
}

pub fn repair(
    codex_home: &Path,
    target_provider: &str,
    journal_root: &Path,
    journal_key: &[u8; 32],
) -> Result<RepairSummary> {
    repair_with_options(
        codex_home,
        target_provider,
        RepairOptions::new(journal_root),
        journal_key,
        |_| {},
    )
}

pub fn repair_with_options<F>(
    codex_home: &Path,
    target_provider: &str,
    options: RepairOptions,
    journal_key: &[u8; 32],
    mut progress: F,
) -> Result<RepairSummary>
where
    F: FnMut(Progress),
{
    let home = validate_codex_home(codex_home)?;
    validate_provider(target_provider)?;
    let transaction_id = match options.transaction_id.as_deref() {
        Some(value) => Uuid::parse_str(value)
            .map_err(|_| {
                CoreError::new(
                    "invalid_transaction_id",
                    "Repair transaction ID must be a UUID",
                )
            })?
            .to_string(),
        None => Uuid::new_v4().to_string(),
    };
    let mut transaction_lock =
        journal::TransactionLock::acquire_for_repair(&home, &transaction_id)?;

    progress(Progress {
        phase: "inspect".to_string(),
        current: 0,
        total: 1,
    });
    let plan = rollout::build_plan(&home, target_provider)?;
    let db_inspection = sqlite::inspect_database(&home, target_provider, &plan.evidence)?;
    progress(Progress {
        phase: "inspect".to_string(),
        current: 1,
        total: 1,
    });

    let no_rollout_changes = plan.files.iter().all(|file| file.patches.is_empty());
    let no_db_changes = db_inspection.provider_mismatches == 0
        && db_inspection.user_event_mismatches == 0
        && db_inspection.cwd_mismatches == 0;
    if no_rollout_changes && no_db_changes {
        return Ok(RepairSummary {
            transaction_id: None,
            journal_path: None,
            target_provider: target_provider.to_string(),
            changed_rollout_files: 0,
            changed_session_meta_records: 0,
            sqlite_provider_rows_updated: 0,
            sqlite_user_event_rows_updated: 0,
            sqlite_cwd_rows_updated: 0,
            no_changes: true,
        });
    }

    let changed_files = plan
        .files
        .iter()
        .filter(|file| !file.patches.is_empty())
        .count();
    progress(Progress {
        phase: "rollouts".to_string(),
        current: 0,
        total: changed_files,
    });
    transaction_lock.update_stage("preparing_recovery")?;
    let mut recovery = journal::RecoveryJournal::create(
        &home,
        &transaction_id,
        target_provider,
        &options.journal_root,
        &plan,
        journal_key,
    )?;
    let plaintext_backup = recovery.database_plaintext_backup_path();
    if let Err(error) = sqlite::backup_database(&home, &plaintext_backup) {
        let _ = sqlite::remove_temporary_backup_artifacts(&plaintext_backup);
        return Err(error);
    }
    if let Err(error) = crypto::encrypt_backup_file(
        journal_key,
        &plaintext_backup,
        &recovery.database_backup_path(),
    ) {
        let _ = sqlite::remove_temporary_backup_artifacts(&plaintext_backup);
        return Err(error);
    }
    let database_recovery =
        sqlite::database_recovery_state(&home, target_provider, &plan.evidence)?;
    recovery.database_backup_complete = true;
    recovery.database_original_digest = Some(database_recovery.original_digest);
    recovery.database_repaired_digest = Some(database_recovery.repaired_digest);
    recovery.database_original_rows = database_recovery.original_rows;
    recovery.store(journal_key)?;

    let transaction_result = (|| -> Result<RepairSummary> {
        transaction_lock.update_stage("applying_rollouts")?;
        recovery.state = journal::JournalState::ApplyingRollouts;
        recovery.store(journal_key)?;

        let mut applied = 0usize;
        for file in plan.files.iter().filter(|file| !file.patches.is_empty()) {
            rollout::apply_file_plan(&home, file, false)?;
            applied += 1;
            progress(Progress {
                phase: "rollouts".to_string(),
                current: applied,
                total: changed_files,
            });
            if options.failure_point == Some(FailurePoint::AfterFirstRollout) && applied == 1 {
                return Err(CoreError::new(
                    "injected_failure",
                    "Injected failure after first rollout",
                ));
            }
        }
        if options.failure_point == Some(FailurePoint::AfterRollouts) {
            return Err(CoreError::new(
                "injected_failure",
                "Injected failure after rollout writes",
            ));
        }

        transaction_lock.update_stage("applying_sqlite")?;
        recovery.state = journal::JournalState::ApplyingSqlite;
        recovery.store(journal_key)?;
        let sqlite_updates = sqlite::apply_database_repair(&home, target_provider, &plan.evidence)?;
        progress(Progress {
            phase: "sqlite".to_string(),
            current: 1,
            total: 1,
        });
        if options.failure_point == Some(FailurePoint::AfterSqlite) {
            return Err(CoreError::new(
                "injected_failure",
                "Injected failure after SQLite update",
            ));
        }

        transaction_lock.update_stage("verifying")?;
        recovery.state = journal::JournalState::Verifying;
        recovery.store(journal_key)?;
        rollout::verify_repaired(&home, &plan)?;
        sqlite::verify_database_repair(&home, target_provider, &plan.evidence)?;

        transaction_lock.update_stage("committed")?;
        recovery.state = journal::JournalState::Committed;
        recovery.store(journal_key)?;
        progress(Progress {
            phase: "commit".to_string(),
            current: 1,
            total: 1,
        });
        Ok(RepairSummary {
            transaction_id: Some(recovery.transaction_id.clone()),
            journal_path: Some(recovery.directory.clone()),
            target_provider: target_provider.to_string(),
            changed_rollout_files: changed_files,
            changed_session_meta_records: plan.files.iter().map(|file| file.patches.len()).sum(),
            sqlite_provider_rows_updated: sqlite_updates.provider_rows,
            sqlite_user_event_rows_updated: sqlite_updates.user_event_rows,
            sqlite_cwd_rows_updated: sqlite_updates.cwd_rows,
            no_changes: false,
        })
    })();

    match transaction_result {
        Ok(summary) => Ok(summary),
        Err(primary) => {
            let _ = transaction_lock.update_stage("rollback");
            recovery.state = journal::JournalState::RollbackRequired;
            let _ = recovery.store(journal_key);
            match journal::rollback_loaded(&mut recovery, journal_key) {
                Ok(_) => Err(CoreError::new(
                    primary.code,
                    format!("{}; all session changes were rolled back", primary.message),
                )),
                Err(rollback_error) => Err(CoreError::new(
                    "rollback_failed",
                    format!(
                        "{}; automatic rollback failed: {}",
                        primary.message, rollback_error.message
                    ),
                )),
            }
        }
    }
}

pub fn rollback(journal_path: &Path, journal_key: &[u8; 32]) -> Result<RollbackSummary> {
    let (manifest, _) = journal::load_manifest(journal_path)?;
    if manifest.operation == journal::JournalOperation::Import {
        return session_import::rollback_import(journal_path, journal_key);
    }
    let mut recovery = journal::RecoveryJournal::load(journal_path, journal_key)?;
    let home = validate_codex_home(&recovery.codex_home)?;
    if home != recovery.codex_home {
        return Err(CoreError::new(
            "journal_home_mismatch",
            "Journal CODEX_HOME does not resolve to its recorded path",
        ));
    }
    let _lock = journal::TransactionLock::acquire_for_rollback(&home, &recovery.transaction_id)?;
    journal::rollback_loaded(&mut recovery, journal_key)
}

pub(crate) fn validate_codex_home(path: &Path) -> Result<PathBuf> {
    if !path.is_absolute() {
        return Err(CoreError::new(
            "invalid_codex_home",
            "CODEX_HOME must be an explicit absolute path",
        ));
    }
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CoreError::new(
            "codex_home_unavailable",
            format!("Cannot inspect CODEX_HOME {}: {error}", path.display()),
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(CoreError::new(
            "invalid_codex_home",
            "CODEX_HOME must be a real directory, not a symbolic link",
        ));
    }
    fs::canonicalize(path).map_err(|error| {
        CoreError::new(
            "codex_home_unavailable",
            format!("Cannot resolve CODEX_HOME {}: {error}", path.display()),
        )
    })
}

pub(crate) fn validate_provider(provider: &str) -> Result<()> {
    if provider.is_empty()
        || !provider.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '_' | '-' | '.')
        })
    {
        return Err(CoreError::new(
            "invalid_provider",
            format!("Invalid provider identifier: {provider:?}"),
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ThreadEvidence {
    pub has_user_event: bool,
    pub cwd: Option<String>,
}

pub(crate) type EvidenceMap = BTreeMap<String, ThreadEvidence>;
