// SPDX-License-Identifier: AGPL-3.0-only
//
// Listing and provider update behavior adapted from CodexPlusPlus storage.rs
// and codex_sqlite.rs at commit
// 3dafffcafb2566a1e8bce4b35671656d6adb3eda.

use crate::{CoreError, EvidenceMap, Result, SessionPage, SessionRow, WorkspacePage, WorkspaceRow};
use rusqlite::backup::Backup;
use rusqlite::types::{Value as SqlValue, ValueRef};
use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::ffi::OsString;
use std::fs;
use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const ACTIVE_DATABASE_NAME: &str = "state_5.sqlite";
const REQUIRED_REPAIR_COLUMNS: [&str; 4] = ["id", "model_provider", "has_user_event", "cwd"];
const REQUIRED_IMPORT_COLUMNS: [&str; 10] = [
    "id",
    "rollout_path",
    "created_at",
    "updated_at",
    "source",
    "model_provider",
    "cwd",
    "title",
    "sandbox_policy",
    "approval_mode",
];
const SUPPORTED_IMPORT_COLUMNS: [&str; 37] = [
    "id",
    "rollout_path",
    "created_at",
    "updated_at",
    "source",
    "model_provider",
    "cwd",
    "title",
    "sandbox_policy",
    "approval_mode",
    "tokens_used",
    "has_user_event",
    "archived",
    "archived_at",
    "git_sha",
    "git_branch",
    "git_origin_url",
    "cli_version",
    "first_user_message",
    "agent_nickname",
    "agent_role",
    "memory_mode",
    "model",
    "reasoning_effort",
    "agent_path",
    "created_at_ms",
    "updated_at_ms",
    "thread_source",
    "preview",
    "recency_at",
    "recency_at_ms",
    "history_mode",
    "name",
    "is_pinned",
    "thread_section_id",
    "section_position",
    "section_entered_at_ms",
];

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DatabaseInspection {
    pub total_threads: usize,
    pub provider_mismatches: usize,
    pub user_event_mismatches: usize,
    pub cwd_mismatches: usize,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DatabaseUpdates {
    pub provider_rows: usize,
    pub user_event_rows: usize,
    pub cwd_rows: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ThreadState {
    pub id: String,
    pub model_provider: String,
    pub has_user_event: i64,
    pub cwd: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ImportThreadRow {
    pub id: String,
    pub rollout_path: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub source: String,
    pub model_provider: String,
    pub cwd: String,
    pub title: String,
    pub sandbox_policy: String,
    pub approval_mode: String,
    pub tokens_used: i64,
    pub has_user_event: i64,
    pub archived: i64,
    pub archived_at: Option<i64>,
    pub git_sha: Option<String>,
    pub git_branch: Option<String>,
    pub git_origin_url: Option<String>,
    pub cli_version: String,
    pub first_user_message: String,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
    pub memory_mode: String,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub agent_path: Option<String>,
    pub created_at_ms: Option<i64>,
    pub updated_at_ms: Option<i64>,
    pub thread_source: Option<String>,
    pub preview: String,
    pub recency_at: i64,
    pub recency_at_ms: i64,
    pub history_mode: String,
    pub name: Option<String>,
    pub is_pinned: i64,
    pub thread_section_id: Option<String>,
    pub section_position: Option<i64>,
    pub section_entered_at_ms: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DatabaseRecoveryState {
    pub original_digest: String,
    pub repaired_digest: String,
    pub original_rows: Vec<ThreadState>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FieldTransition<T> {
    original: T,
    repaired: T,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct ThreadRollbackTransition {
    id: String,
    model_provider: Option<FieldTransition<String>>,
    has_user_event: Option<FieldTransition<i64>>,
    cwd: Option<FieldTransition<String>>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct DatabaseRollbackPlan {
    rows: Vec<ThreadRollbackTransition>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct AppliedDatabaseRollback {
    rows: Vec<ThreadRollbackTransition>,
}

impl AppliedDatabaseRollback {
    pub(crate) fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }
}

pub(crate) fn active_database_path(home: &Path) -> PathBuf {
    home.join(ACTIVE_DATABASE_NAME)
}

pub(crate) fn list_sessions(
    home: &Path,
    limit: usize,
    offset: usize,
    provider: Option<&str>,
    top_level_only: bool,
) -> Result<SessionPage> {
    let path = active_database_path(home);
    let connection = open_read_only(&path)?;
    ensure_threads_table(&connection, &path)?;
    let columns = table_columns(&connection)?;
    if !columns.contains("id") {
        return Err(CoreError::new(
            "unsupported_sqlite_schema",
            format!("threads.id is missing in {}", path.display()),
        ));
    }

    let title = expression(&columns, "title", "''");
    let cwd = expression(&columns, "cwd", "''");
    let provider_expression = expression(&columns, "model_provider", "''");
    let archived = expression(&columns, "archived", "0");
    let rollout_path = expression(&columns, "rollout_path", "''");
    let created = timestamp_expression(&columns, &["created_at_ms", "created_at"], "NULL");
    let updated = timestamp_expression(
        &columns,
        &["updated_at_ms", "updated_at", "created_at_ms", "created_at"],
        "NULL",
    );
    let thread_filter = thread_filter(&connection, &columns, top_level_only)?;
    let sql = format!(
        "SELECT id, {title}, {cwd}, {provider_expression}, {archived}, {created}, {updated}, {rollout_path}
         FROM threads
         WHERE {thread_filter}
         ORDER BY COALESCE({updated}, {created}, 0) DESC, id DESC
         LIMIT ?1 OFFSET ?2"
    );
    let mut statement = connection.prepare(&sql).map_err(sql_error)?;
    let limit_i64 = i64::try_from(limit).unwrap_or(i64::MAX);
    let offset_i64 = i64::try_from(offset).unwrap_or(i64::MAX);
    let rows = statement
        .query_map((limit_i64, offset_i64), |row| {
            Ok(SessionRow {
                id: row.get(0)?,
                title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                cwd: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                current_provider: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                archived: row.get::<_, Option<i64>>(4)?.unwrap_or_default() != 0,
                created_at: sql_value_to_json(row.get_ref(5)?),
                updated_at: sql_value_to_json(row.get_ref(6)?),
                rollout_path: row.get::<_, Option<String>>(7)?.unwrap_or_default(),
            })
        })
        .map_err(sql_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(sql_error)?;
    drop(statement);
    let total_sql = format!("SELECT COUNT(*) FROM threads WHERE {thread_filter}");
    let total_i64: i64 = connection
        .query_row(&total_sql, [], |row| row.get(0))
        .map_err(sql_error)?;
    let total = usize::try_from(total_i64).unwrap_or(usize::MAX);
    let visible_total = if let Some(provider) = provider {
        Some(count_query(
            &connection,
            &format!(
                "SELECT COUNT(*) FROM threads
                 WHERE {thread_filter}
                   AND COALESCE(model_provider, '') = ?1"
            ),
            [provider],
        )?)
    } else {
        None
    };
    Ok(SessionPage {
        database_path: path,
        total,
        visible_total,
        limit,
        offset,
        has_more: offset.saturating_add(rows.len()) < total,
        sessions: rows,
    })
}

pub(crate) fn list_workspaces(
    home: &Path,
    limit: usize,
    offset: usize,
    top_level_only: bool,
) -> Result<WorkspacePage> {
    let path = active_database_path(home);
    let connection = open_read_only(&path)?;
    ensure_threads_table(&connection, &path)?;
    let columns = table_columns(&connection)?;
    if !columns.contains("id") {
        return Err(CoreError::new(
            "unsupported_sqlite_schema",
            format!("threads.id is missing in {}", path.display()),
        ));
    }

    let cwd = expression(&columns, "cwd", "''");
    let archived = expression(&columns, "archived", "0");
    let created = timestamp_expression(&columns, &["created_at_ms", "created_at"], "NULL");
    let updated = timestamp_expression(
        &columns,
        &["updated_at_ms", "updated_at", "created_at_ms", "created_at"],
        "NULL",
    );
    let normalized_cwd = format!("TRIM(COALESCE({cwd}, ''))");
    let latest = format!("MAX(COALESCE({updated}, {created}))");
    let thread_filter = thread_filter(&connection, &columns, top_level_only)?;
    let sql = format!(
        "SELECT {normalized_cwd}, COUNT(*),
                SUM(CASE WHEN COALESCE({archived}, 0) <> 0 THEN 1 ELSE 0 END),
                {latest}
         FROM threads
         WHERE {thread_filter} AND {normalized_cwd} <> ''
         GROUP BY {normalized_cwd}
         ORDER BY {latest} DESC, {normalized_cwd} COLLATE NOCASE ASC
         LIMIT ?1 OFFSET ?2"
    );
    let limit_i64 = i64::try_from(limit).unwrap_or(i64::MAX);
    let offset_i64 = i64::try_from(offset).unwrap_or(i64::MAX);
    let mut statement = connection.prepare(&sql).map_err(sql_error)?;
    let rows = statement
        .query_map((limit_i64, offset_i64), |row| {
            let session_count = row.get::<_, i64>(1)?;
            let archived_count = row.get::<_, i64>(2)?;
            Ok(WorkspaceRow {
                cwd: row.get(0)?,
                session_count: usize::try_from(session_count).unwrap_or(usize::MAX),
                archived_count: usize::try_from(archived_count).unwrap_or(usize::MAX),
                latest_updated_at: sql_value_to_json(row.get_ref(3)?),
            })
        })
        .map_err(sql_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(sql_error)?;
    drop(statement);

    let total_sql = format!(
        "SELECT COUNT(DISTINCT {normalized_cwd})
         FROM threads
         WHERE {thread_filter} AND {normalized_cwd} <> ''"
    );
    let total_i64: i64 = connection
        .query_row(&total_sql, [], |row| row.get(0))
        .map_err(sql_error)?;
    let total = usize::try_from(total_i64).unwrap_or(usize::MAX);
    Ok(WorkspacePage {
        database_path: path,
        total,
        limit,
        offset,
        has_more: offset.saturating_add(rows.len()) < total,
        workspaces: rows,
    })
}

pub(crate) fn lookup_workspaces(
    home: &Path,
    workspaces: &[String],
    top_level_only: bool,
) -> Result<WorkspacePage> {
    let path = active_database_path(home);
    let connection = open_read_only(&path)?;
    ensure_threads_table(&connection, &path)?;
    let columns = table_columns(&connection)?;
    if !columns.contains("id") {
        return Err(CoreError::new(
            "unsupported_sqlite_schema",
            format!("threads.id is missing in {}", path.display()),
        ));
    }

    let cwd = expression(&columns, "cwd", "''");
    let archived = expression(&columns, "archived", "0");
    let created = timestamp_expression(&columns, &["created_at_ms", "created_at"], "NULL");
    let updated = timestamp_expression(
        &columns,
        &["updated_at_ms", "updated_at", "created_at_ms", "created_at"],
        "NULL",
    );
    let normalized_cwd = format!("TRIM(COALESCE({cwd}, ''))");
    let thread_filter = thread_filter(&connection, &columns, top_level_only)?;
    let sql = format!(
        "SELECT COUNT(*),
                SUM(CASE WHEN COALESCE({archived}, 0) <> 0 THEN 1 ELSE 0 END),
                MAX(COALESCE({updated}, {created}))
         FROM threads
         WHERE {thread_filter} AND {normalized_cwd} = ?1"
    );
    let mut statement = connection.prepare(&sql).map_err(sql_error)?;
    let mut rows = Vec::with_capacity(workspaces.len());
    for workspace in workspaces {
        let (session_count, archived_count, latest_updated_at) = statement
            .query_row([workspace], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, Option<i64>>(1)?.unwrap_or_default(),
                    sql_value_to_json(row.get_ref(2)?),
                ))
            })
            .map_err(sql_error)?;
        if session_count == 0 {
            continue;
        }
        rows.push(WorkspaceRow {
            cwd: workspace.clone(),
            session_count: usize::try_from(session_count).unwrap_or(usize::MAX),
            archived_count: usize::try_from(archived_count).unwrap_or(usize::MAX),
            latest_updated_at,
        });
    }
    drop(statement);

    Ok(WorkspacePage {
        database_path: path,
        total: rows.len(),
        limit: workspaces.len(),
        offset: 0,
        has_more: false,
        workspaces: rows,
    })
}

pub(crate) fn list_workspace_sessions(
    home: &Path,
    workspace: &str,
    limit: usize,
    offset: usize,
    provider: Option<&str>,
    top_level_only: bool,
) -> Result<SessionPage> {
    let path = active_database_path(home);
    let connection = open_read_only(&path)?;
    ensure_threads_table(&connection, &path)?;
    let columns = table_columns(&connection)?;
    if !columns.contains("id") {
        return Err(CoreError::new(
            "unsupported_sqlite_schema",
            format!("threads.id is missing in {}", path.display()),
        ));
    }

    let title = expression(&columns, "title", "''");
    let cwd = expression(&columns, "cwd", "''");
    let provider_expression = expression(&columns, "model_provider", "''");
    let archived = expression(&columns, "archived", "0");
    let rollout_path = expression(&columns, "rollout_path", "''");
    let created = timestamp_expression(&columns, &["created_at_ms", "created_at"], "NULL");
    let updated = timestamp_expression(
        &columns,
        &["updated_at_ms", "updated_at", "created_at_ms", "created_at"],
        "NULL",
    );
    let normalized_cwd = format!("TRIM(COALESCE({cwd}, ''))");
    let thread_filter = thread_filter(&connection, &columns, top_level_only)?;
    let sql = format!(
        "SELECT id, {title}, {cwd}, {provider_expression}, {archived}, {created}, {updated}, {rollout_path}
         FROM threads
         WHERE {thread_filter} AND {normalized_cwd} = ?1
         ORDER BY COALESCE({updated}, {created}, 0) DESC, id DESC
         LIMIT ?2 OFFSET ?3"
    );
    let limit_i64 = i64::try_from(limit).unwrap_or(i64::MAX);
    let offset_i64 = i64::try_from(offset).unwrap_or(i64::MAX);
    let mut statement = connection.prepare(&sql).map_err(sql_error)?;
    let rows = statement
        .query_map((workspace, limit_i64, offset_i64), |row| {
            Ok(SessionRow {
                id: row.get(0)?,
                title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                cwd: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                current_provider: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                archived: row.get::<_, Option<i64>>(4)?.unwrap_or_default() != 0,
                created_at: sql_value_to_json(row.get_ref(5)?),
                updated_at: sql_value_to_json(row.get_ref(6)?),
                rollout_path: row.get::<_, Option<String>>(7)?.unwrap_or_default(),
            })
        })
        .map_err(sql_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(sql_error)?;
    drop(statement);

    let total_sql = format!(
        "SELECT COUNT(*) FROM threads
         WHERE {thread_filter} AND {normalized_cwd} = ?1"
    );
    let total_i64: i64 = connection
        .query_row(&total_sql, [workspace], |row| row.get(0))
        .map_err(sql_error)?;
    let total = usize::try_from(total_i64).unwrap_or(usize::MAX);
    let visible_total = if let Some(provider) = provider {
        let visible_sql = format!(
            "SELECT COUNT(*) FROM threads
             WHERE {thread_filter} AND {normalized_cwd} = ?1
               AND COALESCE({provider_expression}, '') = ?2"
        );
        let visible_i64: i64 = connection
            .query_row(&visible_sql, (workspace, provider), |row| row.get(0))
            .map_err(sql_error)?;
        Some(usize::try_from(visible_i64).unwrap_or(usize::MAX))
    } else {
        None
    };
    Ok(SessionPage {
        database_path: path,
        total,
        visible_total,
        limit,
        offset,
        has_more: offset.saturating_add(rows.len()) < total,
        sessions: rows,
    })
}

pub(crate) fn search_sessions(
    home: &Path,
    query: &str,
    limit: usize,
    offset: usize,
    provider: Option<&str>,
    top_level_only: bool,
) -> Result<SessionPage> {
    let path = active_database_path(home);
    let connection = open_read_only(&path)?;
    ensure_threads_table(&connection, &path)?;
    let columns = table_columns(&connection)?;
    if !columns.contains("id") {
        return Err(CoreError::new(
            "unsupported_sqlite_schema",
            format!("threads.id is missing in {}", path.display()),
        ));
    }

    let title = expression(&columns, "title", "''");
    let cwd = expression(&columns, "cwd", "''");
    let provider_expression = expression(&columns, "model_provider", "''");
    let name = expression(&columns, "name", "''");
    let archived = expression(&columns, "archived", "0");
    let rollout_path = expression(&columns, "rollout_path", "''");
    let created = timestamp_expression(&columns, &["created_at_ms", "created_at"], "NULL");
    let updated = timestamp_expression(
        &columns,
        &["updated_at_ms", "updated_at", "created_at_ms", "created_at"],
        "NULL",
    );
    let predicate = format!(
        "(LOWER(COALESCE(id, '')) LIKE LOWER(?1) ESCAPE '\\'
          OR LOWER(COALESCE({title}, '')) LIKE LOWER(?1) ESCAPE '\\'
          OR LOWER(COALESCE({cwd}, '')) LIKE LOWER(?1) ESCAPE '\\'
          OR LOWER(COALESCE({provider_expression}, '')) LIKE LOWER(?1) ESCAPE '\\'
          OR LOWER(COALESCE({name}, '')) LIKE LOWER(?1) ESCAPE '\\')"
    );
    let thread_filter = thread_filter(&connection, &columns, top_level_only)?;
    let sql = format!(
        "SELECT id, {title}, {cwd}, {provider_expression}, {archived}, {created}, {updated}, {rollout_path}
         FROM threads
         WHERE {thread_filter} AND {predicate}
         ORDER BY COALESCE({updated}, {created}, 0) DESC, id DESC
         LIMIT ?2 OFFSET ?3"
    );
    let pattern = format!("%{}%", escape_like_literal(query));
    let limit_i64 = i64::try_from(limit).unwrap_or(i64::MAX);
    let offset_i64 = i64::try_from(offset).unwrap_or(i64::MAX);
    let mut statement = connection.prepare(&sql).map_err(sql_error)?;
    let rows = statement
        .query_map((&pattern, limit_i64, offset_i64), |row| {
            Ok(SessionRow {
                id: row.get(0)?,
                title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                cwd: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                current_provider: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                archived: row.get::<_, Option<i64>>(4)?.unwrap_or_default() != 0,
                created_at: sql_value_to_json(row.get_ref(5)?),
                updated_at: sql_value_to_json(row.get_ref(6)?),
                rollout_path: row.get::<_, Option<String>>(7)?.unwrap_or_default(),
            })
        })
        .map_err(sql_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(sql_error)?;
    drop(statement);

    let total_sql = format!(
        "SELECT COUNT(*) FROM threads
         WHERE {thread_filter} AND {predicate}"
    );
    let total_i64: i64 = connection
        .query_row(&total_sql, [&pattern], |row| row.get(0))
        .map_err(sql_error)?;
    let total = usize::try_from(total_i64).unwrap_or(usize::MAX);
    let visible_total = if let Some(provider) = provider {
        let visible_sql = format!(
            "SELECT COUNT(*) FROM threads
             WHERE {thread_filter} AND {predicate}
               AND {provider_expression} = ?2"
        );
        let visible_i64: i64 = connection
            .query_row(&visible_sql, (&pattern, provider), |row| row.get(0))
            .map_err(sql_error)?;
        Some(usize::try_from(visible_i64).unwrap_or(usize::MAX))
    } else {
        None
    };
    Ok(SessionPage {
        database_path: path,
        total,
        visible_total,
        limit,
        offset,
        has_more: offset.saturating_add(rows.len()) < total,
        sessions: rows,
    })
}

fn escape_like_literal(query: &str) -> String {
    let mut escaped = String::with_capacity(query.len());
    for character in query.chars() {
        if matches!(character, '\\' | '%' | '_') {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    escaped
}

pub(crate) fn inspect_database(
    home: &Path,
    target_provider: &str,
    evidence: &EvidenceMap,
) -> Result<DatabaseInspection> {
    let path = active_database_path(home);
    let connection = open_read_only(&path)?;
    ensure_integrity(&connection, &path)?;
    ensure_repair_schema(&connection, &path)?;

    let total_threads = count_query(&connection, "SELECT COUNT(*) FROM threads", [])?;
    let provider_mismatches = count_query(
        &connection,
        "SELECT COUNT(*) FROM threads WHERE COALESCE(model_provider, '') <> ?1",
        [target_provider],
    )?;
    let mut user_event_mismatches = 0usize;
    let mut cwd_mismatches = 0usize;
    for (thread_id, item) in evidence {
        if item.has_user_event {
            user_event_mismatches += count_query(
                &connection,
                "SELECT COUNT(*) FROM threads WHERE id = ?1 AND COALESCE(has_user_event, 0) <> 1",
                [thread_id.as_str()],
            )?;
        }
        if let Some(cwd) = item.cwd.as_deref() {
            cwd_mismatches += count_query_pair(
                &connection,
                "SELECT COUNT(*) FROM threads WHERE id = ?1 AND COALESCE(cwd, '') <> ?2",
                thread_id,
                cwd,
            )?;
        }
    }
    Ok(DatabaseInspection {
        total_threads,
        provider_mismatches,
        user_event_mismatches,
        cwd_mismatches,
    })
}

pub(crate) fn backup_database(home: &Path, backup_path: &Path) -> Result<()> {
    let source_path = active_database_path(home);
    if backup_path.exists() {
        return Err(CoreError::new(
            "backup_conflict",
            format!("SQLite backup already exists: {}", backup_path.display()),
        ));
    }
    if let Some(parent) = backup_path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CoreError::new(
                "backup_failed",
                format!(
                    "Cannot create backup directory {}: {error}",
                    parent.display()
                ),
            )
        })?;
        set_private_directory_permissions(parent)?;
    }
    create_private_empty_file(backup_path)?;
    let source = open_read_write(&source_path)?;
    ensure_integrity(&source, &source_path)?;
    ensure_repair_schema(&source, &source_path)?;
    let mut destination = Connection::open(backup_path).map_err(sql_error)?;
    {
        let backup = Backup::new(&source, &mut destination).map_err(sql_error)?;
        backup
            .run_to_completion(16, Duration::from_millis(10), None)
            .map_err(sql_error)?;
    }
    drop(destination);
    set_private_file_permissions(backup_path)?;
    let verification = open_read_only(backup_path)?;
    ensure_integrity(&verification, backup_path)
}

pub(crate) fn remove_temporary_backup_artifacts(backup_path: &Path) -> Result<()> {
    let mut first_failure = None;
    for path in temporary_backup_artifact_paths(backup_path) {
        match fs::remove_file(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) if first_failure.is_none() => first_failure = Some((path, error)),
            Err(_) => {}
        }
    }
    if let Some((path, error)) = first_failure {
        return Err(CoreError::new(
            "backup_cleanup_failed",
            format!(
                "Cannot remove plaintext SQLite backup artifact {}: {error}",
                path.display()
            ),
        ));
    }
    Ok(())
}

fn temporary_backup_artifact_paths(backup_path: &Path) -> [PathBuf; 3] {
    let with_suffix = |suffix: &str| {
        let mut value = OsString::from(backup_path.as_os_str());
        value.push(suffix);
        PathBuf::from(value)
    };
    [
        with_suffix("-wal"),
        with_suffix("-shm"),
        backup_path.to_path_buf(),
    ]
}

pub(crate) fn apply_database_repair(
    home: &Path,
    target_provider: &str,
    evidence: &EvidenceMap,
) -> Result<DatabaseUpdates> {
    let path = active_database_path(home);
    let mut connection = open_read_write(&path)?;
    ensure_integrity(&connection, &path)?;
    ensure_repair_schema(&connection, &path)?;
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(sql_error)?;
    let mut updates = DatabaseUpdates {
        provider_rows: transaction
            .execute(
                "UPDATE threads SET model_provider = ?1 WHERE COALESCE(model_provider, '') <> ?1",
                [target_provider],
            )
            .map_err(sql_error)?,
        ..DatabaseUpdates::default()
    };
    for (thread_id, item) in evidence {
        if item.has_user_event {
            updates.user_event_rows += transaction
                .execute(
                    "UPDATE threads SET has_user_event = 1
                     WHERE id = ?1 AND COALESCE(has_user_event, 0) <> 1",
                    [thread_id],
                )
                .map_err(sql_error)?;
        }
        if let Some(cwd) = item.cwd.as_deref() {
            updates.cwd_rows += transaction
                .execute(
                    "UPDATE threads SET cwd = ?1
                     WHERE id = ?2 AND COALESCE(cwd, '') <> ?1",
                    (cwd, thread_id),
                )
                .map_err(sql_error)?;
        }
    }
    transaction.commit().map_err(sql_error)?;
    ensure_integrity(&connection, &path)?;
    Ok(updates)
}

pub(crate) fn database_recovery_state(
    home: &Path,
    target_provider: &str,
    evidence: &EvidenceMap,
) -> Result<DatabaseRecoveryState> {
    let path = active_database_path(home);
    let connection = open_read_only(&path)?;
    ensure_integrity(&connection, &path)?;
    ensure_repair_schema(&connection, &path)?;
    let original_rows = read_thread_states(&connection)?;
    Ok(DatabaseRecoveryState {
        original_digest: digest_thread_states(&original_rows, None, &EvidenceMap::new()),
        repaired_digest: digest_thread_states(&original_rows, Some(target_provider), evidence),
        original_rows,
    })
}

pub(crate) fn verify_database_repair(
    home: &Path,
    target_provider: &str,
    evidence: &EvidenceMap,
) -> Result<()> {
    let inspection = inspect_database(home, target_provider, evidence)?;
    if inspection.provider_mismatches > 0
        || inspection.user_event_mismatches > 0
        || inspection.cwd_mismatches > 0
    {
        return Err(CoreError::new(
            "repair_verification_failed",
            "SQLite rows do not match repaired rollout evidence",
        ));
    }
    Ok(())
}

pub(crate) fn plan_database_rollback(
    home: &Path,
    original_rows: &[ThreadState],
    target_provider: &str,
    evidence: &EvidenceMap,
) -> Result<DatabaseRollbackPlan> {
    let path = active_database_path(home);
    let connection = open_read_only(&path)?;
    ensure_integrity(&connection, &path)?;
    ensure_repair_schema(&connection, &path)?;
    let plan = database_rollback_plan(original_rows, target_provider, evidence);
    validate_database_rollback(&connection, &plan)?;
    Ok(plan)
}

pub(crate) fn apply_database_rollback(
    home: &Path,
    plan: &DatabaseRollbackPlan,
) -> Result<AppliedDatabaseRollback> {
    let path = active_database_path(home);
    let mut connection = open_read_write(&path)?;
    ensure_integrity(&connection, &path)?;
    ensure_repair_schema(&connection, &path)?;
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(sql_error)?;
    let current = validate_database_rollback(&transaction, plan)?;
    let applied = rollback_transitions_to_apply(plan, &current)?;
    for row in &applied.rows {
        apply_thread_transition(&transaction, row, false)?;
    }
    verify_database_transition_values(&transaction, plan, false)?;
    ensure_integrity(&transaction, &path)?;
    transaction.commit().map_err(sql_error)?;
    Ok(AppliedDatabaseRollback { rows: applied.rows })
}

pub(crate) fn compensate_database_rollback(
    home: &Path,
    applied: &AppliedDatabaseRollback,
) -> Result<()> {
    if applied.is_empty() {
        return Ok(());
    }
    let path = active_database_path(home);
    let mut connection = open_read_write(&path)?;
    ensure_integrity(&connection, &path)?;
    ensure_repair_schema(&connection, &path)?;
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(sql_error)?;
    let plan = DatabaseRollbackPlan {
        rows: applied.rows.clone(),
    };
    validate_database_compensation(&transaction, &plan)?;
    for row in &plan.rows {
        apply_thread_transition(&transaction, row, true)?;
    }
    verify_database_transition_values(&transaction, &plan, true)?;
    ensure_integrity(&transaction, &path)?;
    transaction.commit().map_err(sql_error)
}

pub(crate) fn verify_database_rollback(home: &Path, plan: &DatabaseRollbackPlan) -> Result<()> {
    let path = active_database_path(home);
    let connection = open_read_only(&path)?;
    ensure_integrity(&connection, &path)?;
    ensure_repair_schema(&connection, &path)?;
    verify_database_transition_values(&connection, plan, false)
}

pub(crate) fn ensure_import_ready(home: &Path, rows: &[ImportThreadRow]) -> Result<()> {
    let path = active_database_path(home);
    let connection = open_read_only(&path)?;
    ensure_integrity(&connection, &path)?;
    let columns = ensure_import_schema(&connection, &path)?;
    ensure_no_import_conflicts(&connection, rows)?;
    for row in rows {
        if import_values(row, &columns).is_empty() {
            return Err(CoreError::new(
                "unsupported_sqlite_schema",
                "No supported thread columns are available for import",
            ));
        }
    }
    Ok(())
}

pub(crate) fn insert_import_rows(home: &Path, rows: &[ImportThreadRow]) -> Result<usize> {
    let path = active_database_path(home);
    let mut connection = open_read_write(&path)?;
    ensure_integrity(&connection, &path)?;
    let columns = ensure_import_schema(&connection, &path)?;
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(sql_error)?;
    ensure_no_import_conflicts(&transaction, rows)?;
    let mut inserted = 0usize;
    for row in rows {
        let values = import_values(row, &columns);
        let names = values.iter().map(|(name, _)| *name).collect::<Vec<_>>();
        let placeholders = (1..=values.len())
            .map(|index| format!("?{index}"))
            .collect::<Vec<_>>()
            .join(", ");
        let sql = format!(
            "INSERT INTO threads ({}) VALUES ({})",
            names.join(", "),
            placeholders
        );
        let parameters = values.iter().map(|(_, value)| value);
        inserted += transaction
            .execute(&sql, rusqlite::params_from_iter(parameters))
            .map_err(sql_error)?;
    }
    verify_import_rows_on(&transaction, rows, &columns, false)?;
    ensure_integrity(&transaction, &path)?;
    transaction.commit().map_err(sql_error)?;
    Ok(inserted)
}

pub(crate) fn verify_import_rows(home: &Path, rows: &[ImportThreadRow]) -> Result<()> {
    let path = active_database_path(home);
    let connection = open_read_only(&path)?;
    ensure_integrity(&connection, &path)?;
    let columns = ensure_import_schema(&connection, &path)?;
    verify_import_rows_on(&connection, rows, &columns, false)
}

pub(crate) fn delete_import_rows(home: &Path, rows: &[ImportThreadRow]) -> Result<usize> {
    let path = active_database_path(home);
    let mut connection = open_read_write(&path)?;
    ensure_integrity(&connection, &path)?;
    let columns = ensure_import_schema(&connection, &path)?;
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(sql_error)?;
    verify_import_rows_on(&transaction, rows, &columns, true)?;
    let mut deleted = 0usize;
    for row in rows {
        deleted += transaction
            .execute("DELETE FROM threads WHERE id = ?1", [row.id.as_str()])
            .map_err(sql_error)?;
    }
    verify_import_rows_absent(&transaction, rows)?;
    ensure_integrity(&transaction, &path)?;
    transaction.commit().map_err(sql_error)?;
    Ok(deleted)
}

fn ensure_import_schema(connection: &Connection, path: &Path) -> Result<HashSet<String>> {
    ensure_threads_table(connection, path)?;
    let user_version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(sql_error)?;
    if user_version != 0 {
        return Err(CoreError::new(
            "unsupported_sqlite_schema",
            format!(
                "Unsupported SQLite user_version {user_version} in {}",
                path.display()
            ),
        ));
    }
    let columns = table_columns(connection)?;
    let missing = REQUIRED_IMPORT_COLUMNS
        .iter()
        .filter(|column| !columns.contains(**column))
        .copied()
        .collect::<Vec<_>>();
    let unknown = columns
        .iter()
        .filter(|column| !SUPPORTED_IMPORT_COLUMNS.contains(&column.as_str()))
        .cloned()
        .collect::<Vec<_>>();
    if !missing.is_empty() || !unknown.is_empty() {
        let mut details = Vec::new();
        if !missing.is_empty() {
            details.push(format!("missing {}", missing.join(", ")));
        }
        if !unknown.is_empty() {
            details.push(format!("unknown {}", unknown.join(", ")));
        }
        return Err(CoreError::new(
            "unsupported_sqlite_schema",
            format!(
                "Unsupported threads schema in {}: {}",
                path.display(),
                details.join("; ")
            ),
        ));
    }
    Ok(columns)
}

fn ensure_no_import_conflicts(connection: &Connection, rows: &[ImportThreadRow]) -> Result<()> {
    let mut seen = HashSet::new();
    for row in rows {
        let normalized = row.id.to_ascii_lowercase();
        if !seen.insert(normalized) {
            return Err(CoreError::new(
                "duplicate_source_thread",
                "External source contains duplicate Thread IDs",
            ));
        }
        let existing = connection
            .query_row(
                "SELECT id FROM threads WHERE lower(id) = lower(?1) LIMIT 1",
                [row.id.as_str()],
                |value| value.get::<_, String>(0),
            )
            .optional()
            .map_err(sql_error)?;
        if existing.is_some() {
            return Err(CoreError::new(
                "existing_thread_conflict",
                "Current Codex history already contains an imported Thread ID",
            ));
        }
    }
    Ok(())
}

fn verify_import_rows_on(
    connection: &Connection,
    rows: &[ImportThreadRow],
    columns: &HashSet<String>,
    allow_absent: bool,
) -> Result<()> {
    for row in rows {
        let expected = import_values(row, columns);
        let names = expected.iter().map(|(name, _)| *name).collect::<Vec<_>>();
        let sql = format!("SELECT {} FROM threads WHERE id = ?1", names.join(", "));
        let current = connection
            .query_row(&sql, [row.id.as_str()], |result| {
                let mut values = Vec::with_capacity(names.len());
                for index in 0..names.len() {
                    values.push(result.get::<_, SqlValue>(index)?);
                }
                Ok(values)
            })
            .optional()
            .map_err(sql_error)?;
        match current {
            Some(current) => {
                let expected_values = expected
                    .into_iter()
                    .map(|(_, value)| value)
                    .collect::<Vec<_>>();
                if current != expected_values {
                    return Err(CoreError::new(
                        "concurrent_sqlite_change",
                        "Imported thread changed after session transaction",
                    ));
                }
            }
            None if allow_absent => {
                let conflict = connection
                    .query_row(
                        "SELECT 1 FROM threads WHERE lower(id) = lower(?1) LIMIT 1",
                        [row.id.as_str()],
                        |_| Ok(()),
                    )
                    .optional()
                    .map_err(sql_error)?;
                if conflict.is_some() {
                    return Err(CoreError::new(
                        "concurrent_sqlite_change",
                        "Thread ID was reused with different casing after import",
                    ));
                }
            }
            None => {
                return Err(CoreError::new(
                    "import_verification_failed",
                    "Imported thread is missing from SQLite",
                ));
            }
        }
    }
    Ok(())
}

fn verify_import_rows_absent(connection: &Connection, rows: &[ImportThreadRow]) -> Result<()> {
    for row in rows {
        let present = connection
            .query_row(
                "SELECT 1 FROM threads WHERE lower(id) = lower(?1) LIMIT 1",
                [row.id.as_str()],
                |_| Ok(()),
            )
            .optional()
            .map_err(sql_error)?;
        if present.is_some() {
            return Err(CoreError::new(
                "rollback_verification_failed",
                "Imported thread remained in SQLite after rollback",
            ));
        }
    }
    Ok(())
}

fn import_values(
    row: &ImportThreadRow,
    columns: &HashSet<String>,
) -> Vec<(&'static str, SqlValue)> {
    SUPPORTED_IMPORT_COLUMNS
        .iter()
        .filter(|column| columns.contains(**column))
        .map(|column| (*column, import_value(row, column)))
        .collect()
}

fn import_value(row: &ImportThreadRow, column: &str) -> SqlValue {
    let text = |value: &String| SqlValue::Text(value.clone());
    let optional_text = |value: &Option<String>| {
        value
            .as_ref()
            .map_or(SqlValue::Null, |value| SqlValue::Text(value.clone()))
    };
    let optional_integer = |value: Option<i64>| value.map_or(SqlValue::Null, SqlValue::Integer);
    match column {
        "id" => text(&row.id),
        "rollout_path" => text(&row.rollout_path),
        "created_at" => SqlValue::Integer(row.created_at),
        "updated_at" => SqlValue::Integer(row.updated_at),
        "source" => text(&row.source),
        "model_provider" => text(&row.model_provider),
        "cwd" => text(&row.cwd),
        "title" => text(&row.title),
        "sandbox_policy" => text(&row.sandbox_policy),
        "approval_mode" => text(&row.approval_mode),
        "tokens_used" => SqlValue::Integer(row.tokens_used),
        "has_user_event" => SqlValue::Integer(row.has_user_event),
        "archived" => SqlValue::Integer(row.archived),
        "archived_at" => optional_integer(row.archived_at),
        "git_sha" => optional_text(&row.git_sha),
        "git_branch" => optional_text(&row.git_branch),
        "git_origin_url" => optional_text(&row.git_origin_url),
        "cli_version" => text(&row.cli_version),
        "first_user_message" => text(&row.first_user_message),
        "agent_nickname" => optional_text(&row.agent_nickname),
        "agent_role" => optional_text(&row.agent_role),
        "memory_mode" => text(&row.memory_mode),
        "model" => optional_text(&row.model),
        "reasoning_effort" => optional_text(&row.reasoning_effort),
        "agent_path" => optional_text(&row.agent_path),
        "created_at_ms" => optional_integer(row.created_at_ms),
        "updated_at_ms" => optional_integer(row.updated_at_ms),
        "thread_source" => optional_text(&row.thread_source),
        "preview" => text(&row.preview),
        "recency_at" => SqlValue::Integer(row.recency_at),
        "recency_at_ms" => SqlValue::Integer(row.recency_at_ms),
        "history_mode" => text(&row.history_mode),
        "name" => optional_text(&row.name),
        "is_pinned" => SqlValue::Integer(row.is_pinned),
        "thread_section_id" => optional_text(&row.thread_section_id),
        "section_position" => optional_integer(row.section_position),
        "section_entered_at_ms" => optional_integer(row.section_entered_at_ms),
        _ => SqlValue::Null,
    }
}

fn database_rollback_plan(
    original_rows: &[ThreadState],
    target_provider: &str,
    evidence: &EvidenceMap,
) -> DatabaseRollbackPlan {
    let rows = original_rows
        .iter()
        .map(|original| {
            let item = evidence.get(&original.id);
            let repaired_user_event = if item.is_some_and(|value| value.has_user_event) {
                1
            } else {
                original.has_user_event
            };
            let repaired_cwd = item
                .and_then(|value| value.cwd.clone())
                .unwrap_or_else(|| original.cwd.clone());
            ThreadRollbackTransition {
                id: original.id.clone(),
                model_provider: changed_transition(
                    original.model_provider.clone(),
                    target_provider.to_string(),
                ),
                has_user_event: changed_transition(original.has_user_event, repaired_user_event),
                cwd: changed_transition(original.cwd.clone(), repaired_cwd),
            }
        })
        .collect();
    DatabaseRollbackPlan { rows }
}

fn changed_transition<T: PartialEq>(original: T, repaired: T) -> Option<FieldTransition<T>> {
    if original == repaired {
        None
    } else {
        Some(FieldTransition { original, repaired })
    }
}

fn validate_database_rollback(
    connection: &Connection,
    plan: &DatabaseRollbackPlan,
) -> Result<BTreeMap<String, ThreadState>> {
    let current = read_thread_states(connection)?
        .into_iter()
        .map(|row| (row.id.clone(), row))
        .collect::<BTreeMap<_, _>>();
    for row in &plan.rows {
        let value = current.get(&row.id).ok_or_else(|| {
            CoreError::new(
                "concurrent_sqlite_change",
                format!("Thread disappeared after session transaction: {}", row.id),
            )
        })?;
        validate_rollback_field(
            &value.model_provider,
            row.model_provider.as_ref(),
            &row.id,
            "model_provider",
        )?;
        validate_rollback_field(
            &value.has_user_event,
            row.has_user_event.as_ref(),
            &row.id,
            "has_user_event",
        )?;
        validate_rollback_field(&value.cwd, row.cwd.as_ref(), &row.id, "cwd")?;
    }
    Ok(current)
}

fn validate_database_compensation(
    connection: &Connection,
    plan: &DatabaseRollbackPlan,
) -> Result<()> {
    let current = read_thread_states(connection)?
        .into_iter()
        .map(|row| (row.id.clone(), row))
        .collect::<BTreeMap<_, _>>();
    for row in &plan.rows {
        let value = current.get(&row.id).ok_or_else(|| {
            CoreError::new(
                "rollback_compensation_failed",
                format!(
                    "Thread disappeared during rollback compensation: {}",
                    row.id
                ),
            )
        })?;
        validate_compensation_field(
            &value.model_provider,
            row.model_provider.as_ref(),
            &row.id,
            "model_provider",
        )?;
        validate_compensation_field(
            &value.has_user_event,
            row.has_user_event.as_ref(),
            &row.id,
            "has_user_event",
        )?;
        validate_compensation_field(&value.cwd, row.cwd.as_ref(), &row.id, "cwd")?;
    }
    Ok(())
}

fn validate_rollback_field<T: PartialEq>(
    current: &T,
    transition: Option<&FieldTransition<T>>,
    thread_id: &str,
    field: &str,
) -> Result<()> {
    let Some(transition) = transition else {
        return Ok(());
    };
    if current == &transition.original || current == &transition.repaired {
        return Ok(());
    }
    Err(CoreError::new(
        "concurrent_sqlite_change",
        format!("Thread {thread_id} field {field} changed after session transaction"),
    ))
}

fn validate_compensation_field<T: PartialEq>(
    current: &T,
    transition: Option<&FieldTransition<T>>,
    thread_id: &str,
    field: &str,
) -> Result<()> {
    let Some(transition) = transition else {
        return Ok(());
    };
    if current == &transition.original || current == &transition.repaired {
        return Ok(());
    }
    Err(CoreError::new(
        "rollback_compensation_failed",
        format!("Thread {thread_id} field {field} changed during rollback compensation"),
    ))
}

fn rollback_transitions_to_apply(
    plan: &DatabaseRollbackPlan,
    current: &BTreeMap<String, ThreadState>,
) -> Result<DatabaseRollbackPlan> {
    let mut rows = Vec::new();
    for row in &plan.rows {
        let value = current.get(&row.id).ok_or_else(|| {
            CoreError::new(
                "concurrent_sqlite_change",
                format!("Thread disappeared after session transaction: {}", row.id),
            )
        })?;
        let transition = ThreadRollbackTransition {
            id: row.id.clone(),
            model_provider: transition_if_repaired(
                &value.model_provider,
                row.model_provider.as_ref(),
            ),
            has_user_event: transition_if_repaired(
                &value.has_user_event,
                row.has_user_event.as_ref(),
            ),
            cwd: transition_if_repaired(&value.cwd, row.cwd.as_ref()),
        };
        if transition.model_provider.is_some()
            || transition.has_user_event.is_some()
            || transition.cwd.is_some()
        {
            rows.push(transition);
        }
    }
    Ok(DatabaseRollbackPlan { rows })
}

fn transition_if_repaired<T: Clone + PartialEq>(
    current: &T,
    transition: Option<&FieldTransition<T>>,
) -> Option<FieldTransition<T>> {
    transition
        .filter(|value| current == &value.repaired)
        .cloned()
}

fn apply_thread_transition(
    connection: &Connection,
    row: &ThreadRollbackTransition,
    forward: bool,
) -> Result<()> {
    if let Some(value) = row.model_provider.as_ref() {
        let desired = if forward {
            value.repaired.as_str()
        } else {
            value.original.as_str()
        };
        update_one_field(
            connection,
            "UPDATE threads SET model_provider = ?1 WHERE id = ?2",
            desired,
            &row.id,
        )?;
    }
    if let Some(value) = row.has_user_event.as_ref() {
        let desired = if forward {
            value.repaired
        } else {
            value.original
        };
        let updated = connection
            .execute(
                "UPDATE threads SET has_user_event = ?1 WHERE id = ?2",
                (desired, row.id.as_str()),
            )
            .map_err(sql_error)?;
        ensure_single_row_update(updated, &row.id)?;
    }
    if let Some(value) = row.cwd.as_ref() {
        let desired = if forward {
            value.repaired.as_str()
        } else {
            value.original.as_str()
        };
        update_one_field(
            connection,
            "UPDATE threads SET cwd = ?1 WHERE id = ?2",
            desired,
            &row.id,
        )?;
    }
    Ok(())
}

fn update_one_field(
    connection: &Connection,
    sql: &str,
    value: &str,
    thread_id: &str,
) -> Result<()> {
    let updated = connection
        .execute(sql, (value, thread_id))
        .map_err(sql_error)?;
    ensure_single_row_update(updated, thread_id)
}

fn ensure_single_row_update(updated: usize, thread_id: &str) -> Result<()> {
    if updated == 1 {
        Ok(())
    } else {
        Err(CoreError::new(
            "concurrent_sqlite_change",
            format!("Thread disappeared during rollback: {thread_id}"),
        ))
    }
}

fn verify_database_transition_values(
    connection: &Connection,
    plan: &DatabaseRollbackPlan,
    forward: bool,
) -> Result<()> {
    let current = read_thread_states(connection)?
        .into_iter()
        .map(|row| (row.id.clone(), row))
        .collect::<BTreeMap<_, _>>();
    for row in &plan.rows {
        let value = current.get(&row.id).ok_or_else(|| {
            CoreError::new(
                "rollback_verification_failed",
                format!(
                    "Thread disappeared during rollback verification: {}",
                    row.id
                ),
            )
        })?;
        verify_field_value(
            &value.model_provider,
            row.model_provider.as_ref(),
            forward,
            &row.id,
            "model_provider",
        )?;
        verify_field_value(
            &value.has_user_event,
            row.has_user_event.as_ref(),
            forward,
            &row.id,
            "has_user_event",
        )?;
        verify_field_value(&value.cwd, row.cwd.as_ref(), forward, &row.id, "cwd")?;
    }
    Ok(())
}

fn verify_field_value<T: PartialEq>(
    current: &T,
    transition: Option<&FieldTransition<T>>,
    forward: bool,
    thread_id: &str,
    field: &str,
) -> Result<()> {
    let Some(transition) = transition else {
        return Ok(());
    };
    let expected = if forward {
        &transition.repaired
    } else {
        &transition.original
    };
    if current == expected {
        Ok(())
    } else {
        Err(CoreError::new(
            "rollback_verification_failed",
            format!("Thread {thread_id} field {field} failed rollback verification"),
        ))
    }
}

fn open_read_only(path: &Path) -> Result<Connection> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CoreError::new(
            "database_unavailable",
            format!("Cannot inspect active database {}: {error}", path.display()),
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(CoreError::new(
            "unsafe_database_path",
            format!(
                "Active database must be a regular non-symlink file: {}",
                path.display()
            ),
        ));
    }
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let connection = Connection::open_with_flags(path, flags).map_err(sql_error)?;
    connection
        .pragma_update(None, "query_only", true)
        .map_err(sql_error)?;
    Ok(connection)
}

fn open_read_write(path: &Path) -> Result<Connection> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        CoreError::new(
            "database_unavailable",
            format!("Cannot inspect active database {}: {error}", path.display()),
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(CoreError::new(
            "unsafe_database_path",
            format!(
                "Active database must be a regular non-symlink file: {}",
                path.display()
            ),
        ));
    }
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    Connection::open_with_flags(path, flags).map_err(sql_error)
}

fn ensure_integrity(connection: &Connection, path: &Path) -> Result<()> {
    let result: String = connection
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .map_err(sql_error)?;
    if result != "ok" {
        return Err(CoreError::new(
            "sqlite_integrity_failed",
            format!(
                "SQLite integrity check failed for {}: {result}",
                path.display()
            ),
        ));
    }
    Ok(())
}

fn ensure_threads_table(connection: &Connection, path: &Path) -> Result<()> {
    let present = connection
        .query_row(
            "SELECT 1 FROM sqlite_master
             WHERE type = 'table' AND name = 'threads' LIMIT 1",
            [],
            |_| Ok(()),
        )
        .is_ok();
    if !present {
        return Err(CoreError::new(
            "unsupported_sqlite_schema",
            format!("threads table is missing in {}", path.display()),
        ));
    }
    Ok(())
}

fn ensure_repair_schema(connection: &Connection, path: &Path) -> Result<()> {
    ensure_threads_table(connection, path)?;
    let user_version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(sql_error)?;
    if user_version != 0 {
        return Err(CoreError::new(
            "unsupported_sqlite_schema",
            format!(
                "Unsupported SQLite user_version {user_version} in {}",
                path.display()
            ),
        ));
    }
    let columns = table_columns(connection)?;
    let missing = REQUIRED_REPAIR_COLUMNS
        .iter()
        .filter(|column| !columns.contains(**column))
        .copied()
        .collect::<Vec<_>>();
    if !missing.is_empty() {
        return Err(CoreError::new(
            "unsupported_sqlite_schema",
            format!(
                "Unsupported threads schema in {}: missing {}",
                path.display(),
                missing.join(", ")
            ),
        ));
    }
    Ok(())
}

fn table_columns(connection: &Connection) -> Result<HashSet<String>> {
    let mut statement = connection
        .prepare("PRAGMA table_info(\"threads\")")
        .map_err(sql_error)?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(sql_error)?
        .collect::<rusqlite::Result<HashSet<_>>>()
        .map_err(sql_error)?;
    Ok(columns)
}

fn thread_filter(
    connection: &Connection,
    columns: &HashSet<String>,
    top_level_only: bool,
) -> Result<String> {
    if !top_level_only {
        return Ok("1 = 1".to_string());
    }
    let mut predicates = Vec::with_capacity(2);
    if columns.contains("thread_source") {
        predicates.push("COALESCE(threads.thread_source, '') NOT IN ('subagent', 'guardian_review')");
    }
    if table_exists(connection, "thread_spawn_edges")? {
        predicates.push(
            "NOT EXISTS (SELECT 1 FROM thread_spawn_edges AS spawn \
             WHERE spawn.child_thread_id = threads.id)",
        );
    }
    if predicates.is_empty() {
        Ok("1 = 1".to_string())
    } else {
        Ok(predicates.join(" AND "))
    }
}

fn table_exists(connection: &Connection, name: &str) -> Result<bool> {
    connection
        .query_row(
            "SELECT 1 FROM sqlite_master
             WHERE type = 'table' AND name = ?1 LIMIT 1",
            [name],
            |_| Ok(()),
        )
        .optional()
        .map(|row| row.is_some())
        .map_err(sql_error)
}

fn expression<'a>(columns: &HashSet<String>, column: &'a str, fallback: &'a str) -> &'a str {
    if columns.contains(column) {
        column
    } else {
        fallback
    }
}

fn timestamp_expression<'a>(
    columns: &HashSet<String>,
    candidates: &[&'a str],
    fallback: &'a str,
) -> &'a str {
    candidates
        .iter()
        .find(|candidate| columns.contains(**candidate))
        .copied()
        .unwrap_or(fallback)
}

fn count_query<const N: usize>(
    connection: &Connection,
    sql: &str,
    parameters: [&str; N],
) -> Result<usize> {
    let value: i64 = connection
        .query_row(sql, rusqlite::params_from_iter(parameters), |row| {
            row.get(0)
        })
        .map_err(sql_error)?;
    Ok(usize::try_from(value).unwrap_or(usize::MAX))
}

fn count_query_pair(
    connection: &Connection,
    sql: &str,
    first: &str,
    second: &str,
) -> Result<usize> {
    let value: i64 = connection
        .query_row(sql, (first, second), |row| row.get(0))
        .map_err(sql_error)?;
    Ok(usize::try_from(value).unwrap_or(usize::MAX))
}

fn sql_value_to_json(value: ValueRef<'_>) -> Value {
    match value {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(value) => json!(value),
        ValueRef::Real(value) => json!(value),
        ValueRef::Text(value) => json!(String::from_utf8_lossy(value).to_string()),
        ValueRef::Blob(_) => Value::Null,
    }
}

fn read_thread_states(connection: &Connection) -> Result<Vec<ThreadState>> {
    let mut statement = connection
        .prepare(
            "SELECT id, COALESCE(model_provider, ''), COALESCE(has_user_event, 0),
                    COALESCE(cwd, '')
             FROM threads ORDER BY id",
        )
        .map_err(sql_error)?;
    let rows = statement
        .query_map([], |row| {
            Ok(ThreadState {
                id: row.get(0)?,
                model_provider: row.get(1)?,
                has_user_event: row.get(2)?,
                cwd: row.get(3)?,
            })
        })
        .map_err(sql_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(sql_error)?;
    Ok(rows)
}

fn digest_thread_states(
    rows: &[ThreadState],
    target_provider: Option<&str>,
    evidence: &EvidenceMap,
) -> String {
    let mut hasher = Sha256::new();
    for row in rows {
        let item = evidence.get(&row.id);
        let provider = target_provider.unwrap_or(&row.model_provider);
        let user_event = if item.is_some_and(|value| value.has_user_event) {
            1
        } else {
            row.has_user_event
        };
        let cwd = item
            .and_then(|value| value.cwd.as_deref())
            .unwrap_or(&row.cwd);
        digest_field(&mut hasher, row.id.as_bytes());
        digest_field(&mut hasher, provider.as_bytes());
        digest_field(&mut hasher, &user_event.to_le_bytes());
        digest_field(&mut hasher, cwd.as_bytes());
    }
    digest_hex(hasher.finalize())
}

fn digest_field(hasher: &mut Sha256, value: &[u8]) {
    hasher.update((value.len() as u64).to_le_bytes());
    hasher.update(value);
}

fn digest_hex(bytes: impl AsRef<[u8]>) -> String {
    let mut output = String::with_capacity(bytes.as_ref().len() * 2);
    for byte in bytes.as_ref() {
        use std::fmt::Write as _;
        let _ = write!(output, "{byte:02x}");
    }
    output
}

fn sql_error(error: rusqlite::Error) -> CoreError {
    CoreError::new("sqlite_error", error.to_string())
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

fn create_private_empty_file(path: &Path) -> Result<()> {
    OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(path)
        .map_err(|error| {
            CoreError::new(
                "backup_failed",
                format!("Cannot create SQLite backup {}: {error}", path.display()),
            )
        })?;
    set_private_file_permissions(path)
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

#[cfg(test)]
mod tests {
    use super::{remove_temporary_backup_artifacts, temporary_backup_artifact_paths};
    use std::fs;

    #[test]
    fn temporary_backup_cleanup_removes_main_wal_and_shm() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let backup = directory.path().join("backup.sqlite.tmp");
        let artifacts = temporary_backup_artifact_paths(&backup);
        for artifact in &artifacts {
            fs::write(artifact, b"sensitive").expect("write backup artifact");
        }

        remove_temporary_backup_artifacts(&backup).expect("cleanup backup artifacts");
        remove_temporary_backup_artifacts(&backup).expect("cleanup is idempotent");

        for artifact in artifacts {
            assert!(!artifact.exists());
        }
    }
}
