// SPDX-License-Identifier: AGPL-3.0-only

use crate::crypto::{self, EncryptedPayload};
use crate::rollout::{self, RolloutPlan};
use crate::sqlite;
use crate::{ClearedPrewriteLock, CoreError, PendingJournal, Result, RollbackSummary};
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const JOURNAL_FILE: &str = "journal.json";
const DATABASE_BACKUP_FILE: &str = "state_5.sqlite.backup.aesgcm";
const DATABASE_PLAINTEXT_BACKUP_FILE: &str = ".state_5.sqlite.backup.plaintext.tmp";
const LOCK_RELATIVE_PATH: &str = "tmp/ai-access-session-core.lock";
pub(crate) const MAX_JOURNAL_BYTES: u64 = 64 * 1024 * 1024;
const JOURNAL_ESTIMATE_RESERVE_BYTES: u64 = 4 * 1024;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum JournalState {
    Preparing,
    ApplyingRollouts,
    ApplyingSqlite,
    Verifying,
    Committed,
    RollbackRequired,
    RolledBack,
    RollbackFailed,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum JournalOperation {
    Repair,
    Import,
}

fn default_journal_operation() -> JournalOperation {
    JournalOperation::Repair
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecoveryPayload {
    target_provider: String,
    database_original_digest: Option<String>,
    database_repaired_digest: Option<String>,
    database_original_rows: Vec<sqlite::ThreadState>,
    rollout_plan: RolloutPlan,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JournalManifest {
    pub version: u32,
    #[serde(default = "default_journal_operation")]
    pub operation: JournalOperation,
    pub transaction_id: String,
    pub codex_home: PathBuf,
    pub created_at_unix_seconds: u64,
    pub state: JournalState,
    pub database_backup_complete: bool,
    pub encrypted_payload: EncryptedPayload,
}

#[derive(Debug, Clone)]
pub(crate) struct RecoveryJournal {
    pub version: u32,
    pub transaction_id: String,
    pub codex_home: PathBuf,
    pub target_provider: String,
    pub created_at_unix_seconds: u64,
    pub state: JournalState,
    pub database_backup_complete: bool,
    pub database_original_digest: Option<String>,
    pub database_repaired_digest: Option<String>,
    pub database_original_rows: Vec<sqlite::ThreadState>,
    pub rollout_plan: RolloutPlan,
    pub directory: PathBuf,
}

impl RecoveryJournal {
    pub(crate) fn create(
        home: &Path,
        transaction_id: &str,
        target_provider: &str,
        journal_root: &Path,
        rollout_plan: &RolloutPlan,
        key: &[u8; 32],
    ) -> Result<Self> {
        let directory = create_transaction_directory(journal_root, transaction_id)?;
        let journal = Self {
            version: 1,
            transaction_id: transaction_id.to_string(),
            codex_home: home.to_path_buf(),
            target_provider: target_provider.to_string(),
            created_at_unix_seconds: now_seconds(),
            state: JournalState::Preparing,
            database_backup_complete: false,
            database_original_digest: None,
            database_repaired_digest: None,
            database_original_rows: Vec::new(),
            rollout_plan: rollout_plan.clone(),
            directory,
        };
        journal.store(key)?;
        Ok(journal)
    }

    pub(crate) fn load(path: &Path, key: &[u8; 32]) -> Result<Self> {
        let (manifest, directory) = load_manifest(path)?;
        if manifest.operation != JournalOperation::Repair {
            return Err(CoreError::new(
                "journal_operation_mismatch",
                "Recovery journal is not a repair transaction",
            ));
        }
        let payload: RecoveryPayload = crypto::decrypt_json(key, &manifest.encrypted_payload)?;
        let journal = Self {
            version: manifest.version,
            transaction_id: manifest.transaction_id,
            codex_home: manifest.codex_home,
            target_provider: payload.target_provider,
            created_at_unix_seconds: manifest.created_at_unix_seconds,
            state: manifest.state,
            database_backup_complete: manifest.database_backup_complete,
            database_original_digest: payload.database_original_digest,
            database_repaired_digest: payload.database_repaired_digest,
            database_original_rows: payload.database_original_rows,
            rollout_plan: payload.rollout_plan,
            directory,
        };
        if journal
            .database_backup_path()
            .parent()
            .is_none_or(|parent| parent != journal.directory)
        {
            return Err(CoreError::new(
                "unsafe_journal_path",
                "SQLite backup escaped recovery journal",
            ));
        }
        Ok(journal)
    }

    pub(crate) fn database_backup_path(&self) -> PathBuf {
        self.directory.join(DATABASE_BACKUP_FILE)
    }

    pub(crate) fn database_plaintext_backup_path(&self) -> PathBuf {
        self.directory.join(DATABASE_PLAINTEXT_BACKUP_FILE)
    }

    pub(crate) fn store(&self, key: &[u8; 32]) -> Result<()> {
        let path = self.directory.join(JOURNAL_FILE);
        let temp = self
            .directory
            .join(format!(".journal-{}.tmp", Uuid::new_v4()));
        let payload = RecoveryPayload {
            target_provider: self.target_provider.clone(),
            database_original_digest: self.database_original_digest.clone(),
            database_repaired_digest: self.database_repaired_digest.clone(),
            database_original_rows: self.database_original_rows.clone(),
            rollout_plan: self.rollout_plan.clone(),
        };
        let manifest = JournalManifest {
            version: self.version,
            operation: JournalOperation::Repair,
            transaction_id: self.transaction_id.clone(),
            codex_home: self.codex_home.clone(),
            created_at_unix_seconds: self.created_at_unix_seconds,
            state: self.state,
            database_backup_complete: self.database_backup_complete,
            encrypted_payload: crypto::encrypt_json(key, &payload)?,
        };
        store_manifest_at(&path, &temp, &manifest, &self.directory)
    }
}

pub(crate) fn create_transaction_directory(
    journal_root: &Path,
    transaction_id: &str,
) -> Result<PathBuf> {
    if !journal_root.is_absolute() {
        return Err(CoreError::new(
            "invalid_journal_root",
            "Journal root must be an explicit absolute path",
        ));
    }
    let journal_root_existed = journal_root.exists();
    fs::create_dir_all(journal_root).map_err(|error| {
        CoreError::new(
            "journal_create_failed",
            format!(
                "Cannot create journal root {}: {error}",
                journal_root.display()
            ),
        )
    })?;
    let root_metadata = fs::symlink_metadata(journal_root).map_err(|error| {
        CoreError::new(
            "journal_create_failed",
            format!("Cannot inspect journal root: {error}"),
        )
    })?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        return Err(CoreError::new(
            "unsafe_journal_root",
            "Journal root must be a real directory, not a symbolic link",
        ));
    }
    if !journal_root_existed {
        set_private_directory_permissions(journal_root)?;
    }
    let canonical_root = fs::canonicalize(journal_root).map_err(|error| {
        CoreError::new(
            "journal_create_failed",
            format!("Cannot resolve journal root: {error}"),
        )
    })?;
    let directory = canonical_root.join(transaction_id);
    fs::create_dir(&directory).map_err(|error| {
        CoreError::new(
            "journal_create_failed",
            format!("Cannot create transaction journal: {error}"),
        )
    })?;
    set_private_directory_permissions(&directory)?;
    Ok(directory)
}

pub(crate) fn load_manifest(path: &Path) -> Result<(JournalManifest, PathBuf)> {
    let manifest_path = if path.is_dir() {
        path.join(JOURNAL_FILE)
    } else {
        path.to_path_buf()
    };
    let metadata = fs::symlink_metadata(&manifest_path).map_err(|error| {
        CoreError::new(
            "journal_unavailable",
            format!(
                "Cannot inspect journal {}: {error}",
                manifest_path.display()
            ),
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(CoreError::new(
            "unsafe_journal_path",
            "Journal must be a regular non-symlink file",
        ));
    }
    let text = read_bounded_manifest(&manifest_path)?;
    let manifest: JournalManifest = serde_json::from_str(&text).map_err(|error| {
        CoreError::new(
            "invalid_journal",
            format!("Cannot parse recovery journal: {error}"),
        )
    })?;
    if manifest.version != 1 {
        return Err(CoreError::new(
            "unsupported_journal_version",
            format!("Unsupported recovery journal version: {}", manifest.version),
        ));
    }
    let directory = manifest_path
        .parent()
        .ok_or_else(|| CoreError::new("invalid_journal", "Recovery journal has no directory"))?;
    let directory = fs::canonicalize(directory).map_err(|error| {
        CoreError::new(
            "journal_unavailable",
            format!("Cannot resolve recovery journal: {error}"),
        )
    })?;
    Ok((manifest, directory))
}

pub(crate) fn store_manifest(directory: &Path, manifest: &JournalManifest) -> Result<()> {
    let path = directory.join(JOURNAL_FILE);
    let temp = directory.join(format!(".journal-{}.tmp", Uuid::new_v4()));
    store_manifest_at(&path, &temp, manifest, directory)
}

fn store_manifest_at(
    path: &Path,
    temp: &Path,
    manifest: &JournalManifest,
    directory: &Path,
) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(manifest).map_err(|error| {
        CoreError::new(
            "journal_write_failed",
            format!("Cannot serialize recovery journal: {error}"),
        )
    })?;
    if bytes.len() as u64 > MAX_JOURNAL_BYTES {
        return Err(CoreError::new(
            "journal_too_large",
            "Recovery journal exceeds the 64 MiB safety limit",
        ));
    }
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(temp)
        .map_err(|error| {
            CoreError::new(
                "journal_write_failed",
                format!("Cannot create journal temporary file: {error}"),
            )
        })?;
    set_private_file_permissions(temp)?;
    if let Err(error) = file.write_all(&bytes).and_then(|_| file.sync_all()) {
        let _ = fs::remove_file(temp);
        return Err(CoreError::new(
            "journal_write_failed",
            format!("Cannot persist recovery journal: {error}"),
        ));
    }
    drop(file);
    fs::rename(temp, path).map_err(|error| {
        let _ = fs::remove_file(temp);
        CoreError::new(
            "journal_write_failed",
            format!("Cannot commit recovery journal: {error}"),
        )
    })?;
    set_private_file_permissions(path)?;
    sync_directory(directory)
}

pub(crate) fn estimated_manifest_bytes(
    home: &Path,
    target_provider: &str,
    rollout_plan: &RolloutPlan,
    database_recovery: &sqlite::DatabaseRecoveryState,
) -> Result<u64> {
    let payload = RecoveryPayload {
        target_provider: target_provider.to_string(),
        database_original_digest: Some(database_recovery.original_digest.clone()),
        database_repaired_digest: Some(database_recovery.repaired_digest.clone()),
        database_original_rows: database_recovery.original_rows.clone(),
        rollout_plan: rollout_plan.clone(),
    };
    let manifest = JournalManifest {
        version: 1,
        operation: JournalOperation::Repair,
        transaction_id: Uuid::nil().to_string(),
        codex_home: home.to_path_buf(),
        created_at_unix_seconds: now_seconds(),
        state: JournalState::RollbackRequired,
        database_backup_complete: true,
        encrypted_payload: crypto::encrypt_json(&[0u8; 32], &payload)?,
    };
    let bytes = serde_json::to_vec_pretty(&manifest).map_err(|error| {
        CoreError::new(
            "journal_write_failed",
            format!("Cannot estimate recovery journal: {error}"),
        )
    })?;
    (bytes.len() as u64)
        .checked_add(JOURNAL_ESTIMATE_RESERVE_BYTES)
        .ok_or_else(|| CoreError::new("journal_too_large", "Recovery journal estimate overflowed"))
}

pub(crate) fn interrupted_journal(
    home: &Path,
    recovery_root: &Path,
) -> Result<Option<PendingJournal>> {
    let Some((_lock_path, owner)) = interrupted_lock_owner(home)? else {
        return Ok(None);
    };
    let prewrite = is_prewrite_stage(&owner.stage);
    if !recovery_root.is_absolute() {
        return Err(CoreError::new(
            "invalid_journal_root",
            "Recovery root must be an explicit absolute path",
        ));
    }
    let root_metadata = match fs::symlink_metadata(recovery_root) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && prewrite => {
            return Ok(Some(PendingJournal {
                transaction_id: owner.transaction_id,
                journal_path: None,
                prewrite: true,
            }));
        }
        Err(error) => {
            return Err(CoreError::new(
                "interrupted_journal_unavailable",
                format!("Cannot inspect recovery root: {error}"),
            ));
        }
    };
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        return Err(CoreError::new(
            "unsafe_journal_root",
            "Recovery root must be a real directory",
        ));
    }
    let canonical_root = fs::canonicalize(recovery_root).map_err(|error| {
        CoreError::new(
            "interrupted_journal_unavailable",
            format!("Cannot resolve recovery root: {error}"),
        )
    })?;
    let journal_directory = canonical_root.join(&owner.transaction_id);
    let directory_metadata = match fs::symlink_metadata(&journal_directory) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && prewrite => {
            return Ok(Some(PendingJournal {
                transaction_id: owner.transaction_id,
                journal_path: None,
                prewrite: true,
            }));
        }
        Err(error) => {
            return Err(CoreError::new(
                "interrupted_journal_unavailable",
                format!("Cannot inspect interrupted recovery journal: {error}"),
            ));
        }
    };
    if directory_metadata.file_type().is_symlink() || !directory_metadata.is_dir() {
        return Err(CoreError::new(
            "unsafe_journal_path",
            "Interrupted recovery journal must be a real directory",
        ));
    }
    let canonical_directory = fs::canonicalize(&journal_directory).map_err(|error| {
        CoreError::new(
            "interrupted_journal_unavailable",
            format!("Cannot resolve interrupted recovery journal: {error}"),
        )
    })?;
    if canonical_directory.parent() != Some(canonical_root.as_path())
        || canonical_directory
            .file_name()
            .and_then(|value| value.to_str())
            != Some(owner.transaction_id.as_str())
    {
        return Err(CoreError::new(
            "unsafe_journal_path",
            "Interrupted recovery journal escaped the recovery root",
        ));
    }
    let manifest_path = canonical_directory.join(JOURNAL_FILE);
    let manifest_metadata = fs::symlink_metadata(&manifest_path).map_err(|error| {
        CoreError::new(
            "interrupted_journal_unavailable",
            format!("Cannot inspect interrupted recovery manifest: {error}"),
        )
    })?;
    if manifest_metadata.file_type().is_symlink() || !manifest_metadata.is_file() {
        return Err(CoreError::new(
            "unsafe_journal_path",
            "Interrupted recovery manifest must be a regular non-symlink file",
        ));
    }
    let manifest_text = read_bounded_manifest(&manifest_path)?;
    let manifest: JournalManifest = serde_json::from_str(&manifest_text).map_err(|error| {
        CoreError::new(
            "invalid_journal",
            format!("Cannot parse interrupted recovery manifest: {error}"),
        )
    })?;
    if manifest.version != 1
        || manifest.transaction_id != owner.transaction_id
        || manifest.codex_home != home
    {
        return Err(CoreError::new(
            "interrupted_journal_mismatch",
            "Interrupted recovery manifest does not match its lock and CODEX_HOME",
        ));
    }
    Ok(Some(PendingJournal {
        transaction_id: owner.transaction_id,
        journal_path: Some(canonical_directory),
        prewrite: false,
    }))
}

pub(crate) fn clear_stale_prewrite_lock(
    home: &Path,
    recovery_root: &Path,
    transaction_id: &str,
) -> Result<ClearedPrewriteLock> {
    Uuid::parse_str(transaction_id).map_err(|_| {
        CoreError::new(
            "invalid_transaction_id",
            "Prewrite lock transaction ID must be a UUID",
        )
    })?;
    let Some((lock_path, owner)) = interrupted_lock_owner(home)? else {
        return Err(CoreError::new(
            "transaction_lock_unavailable",
            "Interrupted prewrite lock no longer exists",
        ));
    };
    if owner.transaction_id != transaction_id {
        return Err(CoreError::new(
            "transaction_lock_mismatch",
            "Interrupted prewrite lock belongs to another transaction",
        ));
    }
    if !is_prewrite_stage(&owner.stage) {
        return Err(CoreError::new(
            "prewrite_clear_forbidden",
            "Transaction reached a write stage and requires journal rollback",
        ));
    }
    ensure_no_prewrite_journal(recovery_root, transaction_id)?;
    let archive = lock_path.with_file_name(format!(
        "ai-access-session-core.lock.prewrite-{}",
        Uuid::new_v4()
    ));
    fs::rename(&lock_path, &archive).map_err(|error| {
        CoreError::new(
            "prewrite_clear_failed",
            format!("Cannot archive interrupted prewrite lock: {error}"),
        )
    })?;
    set_private_file_permissions(&archive)?;
    if let Some(parent) = archive.parent() {
        sync_directory(parent)?;
    }
    Ok(ClearedPrewriteLock {
        transaction_id: transaction_id.to_string(),
        cleared: true,
    })
}

fn interrupted_lock_owner(home: &Path) -> Result<Option<(PathBuf, LockOwner)>> {
    let lock_path = home.join(LOCK_RELATIVE_PATH);
    match fs::symlink_metadata(&lock_path) {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(CoreError::new(
                "invalid_transaction_lock",
                format!("Cannot inspect interrupted transaction lock: {error}"),
            ));
        }
    }
    let lock_parent = lock_path.parent().ok_or_else(|| {
        CoreError::new(
            "invalid_transaction_lock",
            "Interrupted transaction lock has no parent directory",
        )
    })?;
    let lock_parent_metadata = fs::symlink_metadata(lock_parent).map_err(|error| {
        CoreError::new(
            "invalid_transaction_lock",
            format!("Cannot inspect interrupted transaction lock directory: {error}"),
        )
    })?;
    if lock_parent_metadata.file_type().is_symlink() || !lock_parent_metadata.is_dir() {
        return Err(CoreError::new(
            "invalid_transaction_lock",
            "Interrupted transaction lock directory must be a real directory",
        ));
    }
    let owner = read_lock_owner(&lock_path)?;
    Uuid::parse_str(&owner.transaction_id).map_err(|_| {
        CoreError::new(
            "invalid_transaction_lock",
            "Interrupted transaction lock has an invalid transaction ID",
        )
    })?;
    if process_is_alive(owner.pid) {
        return Err(CoreError::new(
            "transaction_locked",
            format!(
                "Session transaction {} is still active",
                owner.transaction_id
            ),
        ));
    }
    Ok(Some((lock_path, owner)))
}

fn is_prewrite_stage(stage: &str) -> bool {
    matches!(stage, "inspect" | "preparing_recovery")
}

fn ensure_no_prewrite_journal(recovery_root: &Path, transaction_id: &str) -> Result<()> {
    if !recovery_root.is_absolute()
        || recovery_root
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(CoreError::new(
            "invalid_journal_root",
            "Recovery root must be an explicit normalized absolute path",
        ));
    }
    match fs::symlink_metadata(recovery_root) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return Err(CoreError::new(
                    "unsafe_journal_root",
                    "Recovery root must be a real directory",
                ));
            }
            let canonical_root = fs::canonicalize(recovery_root).map_err(|error| {
                CoreError::new(
                    "prewrite_clear_failed",
                    format!("Cannot resolve recovery root: {error}"),
                )
            })?;
            match fs::symlink_metadata(canonical_root.join(transaction_id)) {
                Ok(_) => {
                    return Err(CoreError::new(
                        "prewrite_journal_exists",
                        "A recovery journal exists; prewrite lock cannot be cleared",
                    ));
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(CoreError::new(
                        "prewrite_clear_failed",
                        format!("Cannot inspect recovery journal path: {error}"),
                    ));
                }
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(CoreError::new(
                "prewrite_clear_failed",
                format!("Cannot inspect recovery root: {error}"),
            ));
        }
    }
    Ok(())
}

pub(crate) fn rollback_loaded(
    journal: &mut RecoveryJournal,
    key: &[u8; 32],
) -> Result<RollbackSummary> {
    if journal.state == JournalState::RolledBack {
        return Ok(RollbackSummary {
            transaction_id: journal.transaction_id.clone(),
            journal_path: journal.directory.clone(),
            restored_rollout_files: 0,
            database_restored: journal.database_backup_complete,
            already_rolled_back: true,
        });
    }

    let rollback_result =
        (|| -> Result<(usize, Option<sqlite::AppliedDatabaseRollback>, Vec<usize>)> {
            let database_plan = if journal.database_backup_complete {
                Some(sqlite::plan_database_rollback(
                    &journal.codex_home,
                    &journal.database_original_rows,
                    &journal.target_provider,
                    &journal.rollout_plan.evidence,
                )?)
            } else {
                None
            };
            rollout::preflight_rollback(&journal.codex_home, &journal.rollout_plan)?;

            let mut restored_rollouts = 0usize;
            let mut restored_indices = Vec::new();
            for (index, file) in journal.rollout_plan.files.iter().enumerate() {
                if file.patches.is_empty() {
                    continue;
                }
                match rollout::rollback_file_plan(&journal.codex_home, file) {
                    Ok(changed) => {
                        if changed {
                            restored_rollouts += 1;
                            restored_indices.push(index);
                        }
                    }
                    Err(error) => {
                        let mut attempted_indices = restored_indices.clone();
                        attempted_indices.push(index);
                        compensate_rollouts(journal, &attempted_indices)?;
                        return Err(error);
                    }
                }
            }
            if let Err(error) =
                rollout::verify_rolled_back(&journal.codex_home, &journal.rollout_plan)
            {
                compensate_rollouts(journal, &restored_indices)?;
                return Err(error);
            }

            let database_applied = if let Some(plan) = database_plan.as_ref() {
                let applied = match sqlite::apply_database_rollback(&journal.codex_home, plan) {
                    Ok(value) => value,
                    Err(error) => {
                        compensate_rollouts(journal, &restored_indices)?;
                        return Err(error);
                    }
                };
                if let Err(error) = sqlite::verify_database_rollback(&journal.codex_home, plan) {
                    let compensation = compensate_all(journal, Some(&applied), &restored_indices);
                    compensation?;
                    return Err(error);
                }
                Some(applied)
            } else {
                None
            };
            Ok((restored_rollouts, database_applied, restored_indices))
        })();

    match rollback_result {
        Ok((restored_rollouts, database_applied, restored_indices)) => {
            journal.state = JournalState::RolledBack;
            if let Err(store_error) = journal.store(key) {
                if let Err(compensation_error) =
                    compensate_all(journal, database_applied.as_ref(), &restored_indices)
                {
                    journal.state = JournalState::RollbackFailed;
                    let _ = journal.store(key);
                    return Err(compensation_error);
                }
                journal.state = JournalState::RollbackFailed;
                let _ = journal.store(key);
                return Err(store_error);
            }
            Ok(RollbackSummary {
                transaction_id: journal.transaction_id.clone(),
                journal_path: journal.directory.clone(),
                restored_rollout_files: restored_rollouts,
                database_restored: database_applied
                    .as_ref()
                    .is_some_and(|value| !value.is_empty()),
                already_rolled_back: false,
            })
        }
        Err(error) => {
            journal.state = JournalState::RollbackFailed;
            let _ = journal.store(key);
            Err(error)
        }
    }
}

fn compensate_all(
    journal: &RecoveryJournal,
    database_applied: Option<&sqlite::AppliedDatabaseRollback>,
    restored_indices: &[usize],
) -> Result<()> {
    let mut failures = Vec::new();
    if let Some(applied) = database_applied {
        if let Err(error) = sqlite::compensate_database_rollback(&journal.codex_home, applied) {
            failures.push(error.message);
        }
    }
    if let Err(error) = compensate_rollouts(journal, restored_indices) {
        failures.push(error.message);
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(CoreError::new(
            "rollback_compensation_failed",
            format!("Cannot restore pre-rollback state: {}", failures.join("; ")),
        ))
    }
}

fn compensate_rollouts(journal: &RecoveryJournal, restored_indices: &[usize]) -> Result<()> {
    let mut failures = Vec::new();
    for index in restored_indices.iter().rev() {
        let Some(file) = journal.rollout_plan.files.get(*index) else {
            failures.push("Rollback compensation journal index is invalid".to_string());
            continue;
        };
        if let Err(error) = rollout::compensate_rollback_file(&journal.codex_home, file) {
            failures.push(format!(
                "{}: {}",
                file.relative_path.display(),
                error.message
            ));
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(CoreError::new(
            "rollback_compensation_failed",
            format!(
                "Cannot restore pre-rollback rollout state: {}",
                failures.join("; ")
            ),
        ))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LockOwner {
    version: u32,
    transaction_id: String,
    pid: u32,
    started_at_unix_seconds: u64,
    stage: String,
}

pub(crate) struct TransactionLock {
    path: PathBuf,
    owner: LockOwner,
}

impl TransactionLock {
    pub(crate) fn acquire_for_repair(home: &Path, transaction_id: &str) -> Result<Self> {
        let path = prepare_lock_path(home)?;
        if path.exists() {
            let existing = read_lock_owner(&path)?;
            if process_is_alive(existing.pid) {
                return Err(CoreError::new(
                    "transaction_locked",
                    format!(
                        "Session transaction {} is still active",
                        existing.transaction_id
                    ),
                ));
            }
            return Err(CoreError::new(
                "recovery_required",
                format!(
                    "Interrupted session transaction {} requires rollback before repair",
                    existing.transaction_id
                ),
            ));
        }
        Self::create(path, transaction_id, "inspect")
    }

    pub(crate) fn acquire_for_rollback(home: &Path, transaction_id: &str) -> Result<Self> {
        let path = prepare_lock_path(home)?;
        if path.exists() {
            let existing = read_lock_owner(&path)?;
            if process_is_alive(existing.pid) {
                return Err(CoreError::new(
                    "transaction_locked",
                    format!(
                        "Session transaction {} is still active",
                        existing.transaction_id
                    ),
                ));
            }
            if existing.transaction_id != transaction_id {
                return Err(CoreError::new(
                    "stale_lock_mismatch",
                    format!(
                        "Interrupted transaction {} does not match rollback journal {}",
                        existing.transaction_id, transaction_id
                    ),
                ));
            }
            let archive = path.with_file_name(format!(
                "ai-access-session-core.lock.stale-{}",
                Uuid::new_v4()
            ));
            fs::rename(&path, &archive).map_err(|error| {
                CoreError::new(
                    "lock_takeover_failed",
                    format!("Cannot archive interrupted transaction lock: {error}"),
                )
            })?;
            set_private_file_permissions(&archive)?;
        }
        Self::create(path, transaction_id, "rollback")
    }

    pub(crate) fn update_stage(&mut self, stage: &str) -> Result<()> {
        self.owner.stage = stage.to_string();
        write_lock_owner(&self.path, &self.owner)
    }

    fn create(path: PathBuf, transaction_id: &str, stage: &str) -> Result<Self> {
        let owner = LockOwner {
            version: 1,
            transaction_id: transaction_id.to_string(),
            pid: std::process::id(),
            started_at_unix_seconds: now_seconds(),
            stage: stage.to_string(),
        };
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&path)
            .map_err(|error| {
                CoreError::new(
                    "transaction_locked",
                    format!(
                        "Another session transaction is active at {}: {error}",
                        path.display()
                    ),
                )
            })?;
        set_private_file_permissions(&path)?;
        let bytes = serde_json::to_vec(&owner).map_err(|error| {
            CoreError::new(
                "lock_failed",
                format!("Cannot serialize transaction lock: {error}"),
            )
        })?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|error| {
                let _ = fs::remove_file(&path);
                CoreError::new(
                    "lock_failed",
                    format!("Cannot persist transaction lock: {error}"),
                )
            })?;
        Ok(Self { path, owner })
    }
}

impl Drop for TransactionLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn prepare_lock_path(home: &Path) -> Result<PathBuf> {
    let path = home.join(LOCK_RELATIVE_PATH);
    let parent = path
        .parent()
        .ok_or_else(|| CoreError::new("lock_failed", "Transaction lock has no parent directory"))?;
    fs::create_dir_all(parent).map_err(|error| {
        CoreError::new(
            "lock_failed",
            format!("Cannot create transaction lock directory: {error}"),
        )
    })?;
    let parent_metadata = fs::symlink_metadata(parent).map_err(|error| {
        CoreError::new(
            "lock_failed",
            format!("Cannot inspect transaction lock directory: {error}"),
        )
    })?;
    if parent_metadata.file_type().is_symlink() || !parent_metadata.is_dir() {
        return Err(CoreError::new(
            "unsafe_lock_path",
            "Transaction lock directory must not be a symbolic link",
        ));
    }
    Ok(path)
}

fn read_lock_owner(path: &Path) -> Result<LockOwner> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CoreError::new(
            "invalid_transaction_lock",
            format!("Cannot inspect transaction lock: {error}"),
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(CoreError::new(
            "invalid_transaction_lock",
            "Transaction lock must be a regular non-symlink file",
        ));
    }
    let text = fs::read_to_string(path).map_err(|error| {
        CoreError::new(
            "invalid_transaction_lock",
            format!("Cannot read transaction lock: {error}"),
        )
    })?;
    let owner: LockOwner = serde_json::from_str(&text).map_err(|error| {
        CoreError::new(
            "invalid_transaction_lock",
            format!("Cannot parse transaction lock: {error}"),
        )
    })?;
    if owner.version != 1 || owner.transaction_id.is_empty() || owner.pid == 0 {
        return Err(CoreError::new(
            "invalid_transaction_lock",
            "Transaction lock has unsupported or incomplete ownership data",
        ));
    }
    Ok(owner)
}

fn write_lock_owner(path: &Path, owner: &LockOwner) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| CoreError::new("lock_failed", "Transaction lock has no parent directory"))?;
    let temporary = parent.join(format!(".session-lock-{}.tmp", Uuid::new_v4()));
    let bytes = serde_json::to_vec(owner).map_err(|error| {
        CoreError::new(
            "lock_failed",
            format!("Cannot serialize transaction lock: {error}"),
        )
    })?;
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temporary)
        .map_err(|error| {
            CoreError::new(
                "lock_failed",
                format!("Cannot create transaction lock update: {error}"),
            )
        })?;
    set_private_file_permissions(&temporary)?;
    if let Err(error) = file.write_all(&bytes).and_then(|_| file.sync_all()) {
        let _ = fs::remove_file(&temporary);
        return Err(CoreError::new(
            "lock_failed",
            format!("Cannot persist transaction lock stage: {error}"),
        ));
    }
    drop(file);
    fs::rename(&temporary, path).map_err(|error| {
        let _ = fs::remove_file(&temporary);
        CoreError::new(
            "lock_failed",
            format!("Cannot commit transaction lock stage: {error}"),
        )
    })?;
    set_private_file_permissions(path)
}

#[cfg(unix)]
fn process_is_alive(pid: u32) -> bool {
    let Ok(pid) = i32::try_from(pid) else {
        return false;
    };
    // SAFETY: kill(pid, 0) performs existence/permission probing only and sends no signal.
    let result = unsafe { libc::kill(pid, 0) };
    if result == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn process_is_alive(_pid: u32) -> bool {
    true
}

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn read_bounded_manifest(path: &Path) -> Result<String> {
    let metadata = fs::metadata(path).map_err(|error| {
        CoreError::new(
            "journal_unavailable",
            format!("Cannot inspect journal {}: {error}", path.display()),
        )
    })?;
    if metadata.len() > MAX_JOURNAL_BYTES {
        return Err(CoreError::new(
            "journal_too_large",
            "Recovery journal exceeds the 64 MiB safety limit",
        ));
    }
    let file = File::open(path).map_err(|error| {
        CoreError::new(
            "journal_unavailable",
            format!("Cannot read journal {}: {error}", path.display()),
        )
    })?;
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_JOURNAL_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| {
            CoreError::new(
                "journal_unavailable",
                format!("Cannot read journal {}: {error}", path.display()),
            )
        })?;
    if bytes.len() as u64 > MAX_JOURNAL_BYTES {
        return Err(CoreError::new(
            "journal_too_large",
            "Recovery journal exceeds the 64 MiB safety limit",
        ));
    }
    String::from_utf8(bytes)
        .map_err(|_| CoreError::new("invalid_journal", "Recovery journal is not valid UTF-8"))
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

fn set_private_directory_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|error| {
        CoreError::new(
            "permission_failed",
            format!("Cannot secure {}: {error}", path.display()),
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
                "journal_write_failed",
                format!("Cannot sync journal directory: {error}"),
            )
        })?;
    Ok(())
}
