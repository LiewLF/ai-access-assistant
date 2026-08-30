// SPDX-License-Identifier: AGPL-3.0-only

use ai_access_session_core::{
    clear_stale_prewrite_lock, import_sessions_with_options, inspect, interrupted_journal,
    list_conversation_workspaces, list_conversations_for_provider, list_sessions,
    list_sessions_for_provider, list_workspace_conversations_for_provider,
    list_workspace_sessions_for_provider, list_workspaces, lookup_conversation_workspaces,
    lookup_workspaces, repair, repair_with_options, rollback, search_conversations_for_provider,
    search_sessions_for_provider, FailurePoint, ImportFailurePoint, ImportOptions, RepairOptions,
};
use rusqlite::Connection;
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};
use tempfile::TempDir;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const JOURNAL_KEY: [u8; 32] = [0x5a; 32];

#[cfg(unix)]
fn peak_resident_bytes() -> u64 {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    let result = unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) };
    assert_eq!(result, 0, "getrusage failed");
    let raw = unsafe { usage.assume_init() }.ru_maxrss as u64;
    #[cfg(target_os = "macos")]
    {
        raw
    }
    #[cfg(not(target_os = "macos"))]
    {
        raw.saturating_mul(1024)
    }
}

#[cfg(not(unix))]
fn peak_resident_bytes() -> u64 {
    panic!("peak resident memory measurement is not implemented for this platform")
}

fn fixture() -> (TempDir, PathBuf, PathBuf) {
    let temporary = tempfile::tempdir().expect("temporary directory");
    let home = temporary.path().join("codex-home");
    let journal = temporary.path().join("recovery");
    fs::create_dir(&home).expect("create CODEX_HOME");
    (temporary, home, journal)
}

fn create_database(path: &Path, rows: usize) {
    let mut connection = Connection::open(path).expect("open fixture database");
    connection
        .execute_batch(
            "CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                title TEXT,
                cwd TEXT,
                model_provider TEXT,
                archived INTEGER,
                created_at_ms INTEGER,
                updated_at_ms INTEGER,
                rollout_path TEXT,
                has_user_event INTEGER
            );",
        )
        .expect("create threads schema");
    let transaction = connection.transaction().expect("fixture transaction");
    for index in 0..rows {
        transaction
            .execute(
                "INSERT INTO threads
                 (id, title, cwd, model_provider, archived, created_at_ms,
                  updated_at_ms, rollout_path, has_user_event)
                 VALUES (?1, ?2, ?3, 'openai', ?4, ?5, ?6, ?7, 0)",
                (
                    format!("thread-{index:03}"),
                    format!("Title {index:03}"),
                    format!("/workspace/{index:03}"),
                    i64::from(index % 2 == 0),
                    index as i64,
                    (index * 10) as i64,
                    format!("/rollout/{index:03}.jsonl"),
                ),
            )
            .expect("insert fixture thread");
    }
    transaction.commit().expect("commit fixture");
}

fn create_import_database(path: &Path) {
    let connection = Connection::open(path).expect("open import fixture database");
    connection
        .execute_batch(
            "CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                source TEXT NOT NULL,
                model_provider TEXT NOT NULL,
                cwd TEXT NOT NULL,
                title TEXT NOT NULL,
                sandbox_policy TEXT NOT NULL,
                approval_mode TEXT NOT NULL,
                tokens_used INTEGER NOT NULL DEFAULT 0,
                has_user_event INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                archived_at INTEGER,
                git_sha TEXT,
                git_branch TEXT,
                git_origin_url TEXT,
                cli_version TEXT NOT NULL DEFAULT '',
                first_user_message TEXT NOT NULL DEFAULT '',
                agent_nickname TEXT,
                agent_role TEXT,
                memory_mode TEXT NOT NULL DEFAULT 'enabled',
                model TEXT,
                reasoning_effort TEXT,
                agent_path TEXT,
                created_at_ms INTEGER,
                updated_at_ms INTEGER,
                thread_source TEXT,
                preview TEXT NOT NULL DEFAULT '',
                recency_at INTEGER NOT NULL DEFAULT 0,
                recency_at_ms INTEGER NOT NULL DEFAULT 0,
                history_mode TEXT NOT NULL DEFAULT 'legacy',
                name TEXT,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                thread_section_id TEXT,
                section_position INTEGER,
                section_entered_at_ms INTEGER
            );",
        )
        .expect("create import threads schema");
}

fn write_external_rollout(root: &Path, name: &str, id: &str, message: &str) -> (PathBuf, Vec<u8>) {
    let path = root.join(name);
    fs::create_dir_all(path.parent().expect("external rollout parent"))
        .expect("create external source");
    let text = format!(
        "{{\"timestamp\":\"2026-08-16T10:00:00.125Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\",\"timestamp\":\"2026-08-16T10:00:00.125Z\",\"cwd\":\"/external/workspace\",\"model_provider\":\"custom\",\"source\":\"cli\",\"cli_version\":\"0.99.0\",\"git\":{{\"commit_hash\":\"abc123\",\"branch\":\"main\"}}}}}}\n{{\"timestamp\":\"2026-08-16T10:00:01.500Z\",\"type\":\"turn_context\",\"payload\":{{\"model\":\"gpt-test\",\"effort\":\"high\",\"sandbox_policy\":\"read-only\",\"approval_policy\":\"on-request\"}}}}\n{{\"timestamp\":\"2026-08-16T10:00:02.750Z\",\"type\":\"event_msg\",\"payload\":{{\"type\":\"user_message\",\"message\":\"{message}\"}}}}\n"
    );
    let bytes = text.into_bytes();
    fs::write(&path, &bytes).expect("write external rollout");
    (path, bytes)
}

fn thread_count(database: &Path) -> i64 {
    Connection::open(database)
        .expect("open fixture database")
        .query_row("SELECT COUNT(*) FROM threads", [], |row| row.get(0))
        .expect("count fixture threads")
}

fn insert_thread(database: &Path, id: &str, provider: &str, cwd: &str, has_user_event: i64) {
    let connection = Connection::open(database).expect("open fixture database");
    connection
        .execute(
            "INSERT INTO threads
             (id, title, cwd, model_provider, archived, created_at_ms,
              updated_at_ms, rollout_path, has_user_event)
             VALUES (?1, ?2, ?3, ?4, 0, 1, 2, '', ?5)",
            (id, format!("Title {id}"), cwd, provider, has_user_event),
        )
        .expect("insert fixture thread");
}

fn write_rollout(
    home: &Path,
    relative: &str,
    thread_id: &str,
    provider: &str,
    cwd: &str,
    user_event: bool,
) -> (PathBuf, Vec<u8>) {
    let path = home.join(relative);
    fs::create_dir_all(path.parent().expect("rollout parent")).expect("create rollout parent");
    let mut text = format!(
        "{{\"type\":\"session_meta\", \"payload\" : {{ \"id\":\"{thread_id}\", \"model_provider\" : \"{provider}\", \"cwd\":\"{cwd}\", \"untouched\": [1, 2, 3] }}, \"other\":true}}\r\n"
    );
    if user_event {
        text.push_str("{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\"}}\r\n");
    } else {
        text.push_str("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\r\n");
    }
    let bytes = text.into_bytes();
    fs::write(&path, &bytes).expect("write rollout");
    (path, bytes)
}

fn write_large_rollout(home: &Path, index: usize, target_bytes: usize) {
    let path = home.join(format!(
        "sessions/2026/07/rollout-performance-{index:03}.jsonl"
    ));
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut writer = std::io::BufWriter::new(fs::File::create(path).unwrap());
    let meta = format!(
        "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"thread-{index:03}\",\"model_provider\":\"openai\",\"cwd\":\"/performance/{index:03}\"}}}}\n"
    );
    let prefix = b"{\"type\":\"response_item\",\"payload\":{\"blob\":\"";
    let suffix = b"\"}}\n";
    let fixed = meta.len() + prefix.len() + suffix.len();
    assert!(target_bytes > fixed);
    writer.write_all(meta.as_bytes()).unwrap();
    writer.write_all(prefix).unwrap();
    let mut remaining = target_bytes - fixed;
    let fill = [b'x'; 64 * 1024];
    while remaining > 0 {
        let count = remaining.min(fill.len());
        writer.write_all(&fill[..count]).unwrap();
        remaining -= count;
    }
    writer.write_all(suffix).unwrap();
    writer.flush().unwrap();
}

fn provider(database: &Path, id: &str) -> String {
    Connection::open(database)
        .expect("open fixture database")
        .query_row(
            "SELECT model_provider FROM threads WHERE id = ?1",
            [id],
            |row| row.get(0),
        )
        .expect("read provider")
}

#[test]
fn list_is_sqlite_only_bounded_and_paginated() {
    let (_temporary, home, _journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 201);
    let invalid_rollout = home.join("sessions/rollout-invalid.jsonl");
    fs::create_dir_all(invalid_rollout.parent().unwrap()).unwrap();
    let large_invalid = fs::File::create(&invalid_rollout).unwrap();
    large_invalid.set_len(96 * 1024 * 1024).unwrap();
    drop(large_invalid);

    let first = list_sessions(&home, 500, 0).expect("first page");
    assert_eq!(first.limit, 50);
    assert_eq!(first.total, 201);
    assert_eq!(first.visible_total, None);
    assert_eq!(first.sessions.len(), 50);
    assert!(first.has_more);
    assert_eq!(first.sessions[0].id, "thread-200");
    assert_eq!(first.sessions[0].title, "Title 200");

    let second = list_sessions(&home, 50, 50).expect("second page");
    assert_eq!(second.sessions.len(), 50);
    assert!(second.has_more);
    assert_eq!(second.sessions[0].id, "thread-150");
    let visibility =
        list_sessions_for_provider(&home, 50, 0, Some("openai")).expect("visibility count");
    assert_eq!(visibility.visible_total, Some(201));
}

#[test]
fn conversation_history_hides_internal_threads_and_orders_newest_first() {
    let (_temporary, home, _journal) = fixture();
    let database = home.join("state_5.sqlite");
    let connection = Connection::open(&database).expect("open conversation fixture");
    connection
        .execute_batch(
            "CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                title TEXT,
                cwd TEXT,
                model_provider TEXT,
                archived INTEGER,
                created_at_ms INTEGER,
                updated_at_ms INTEGER,
                rollout_path TEXT,
                has_user_event INTEGER,
                thread_source TEXT
            );
            CREATE TABLE thread_spawn_edges (
                parent_thread_id TEXT NOT NULL,
                child_thread_id TEXT NOT NULL PRIMARY KEY,
                status TEXT NOT NULL
            );
            INSERT INTO threads VALUES
                ('root-older', 'Shared conversation', '/work/shared', 'openai', 0, 1000, 4000, '/root-older', 1, 'user'),
                ('root-newest', 'Newest conversation', '/work/newest', 'openai', 0, 2000, 9000, '/root-newest', 1, 'user'),
                ('child-linked', 'Shared conversation', '/work/shared', 'openai', 0, 3000, 8000, '/child-linked', 1, NULL),
                ('child-orphan', 'Shared conversation', '/work/shared', 'openai', 0, 3500, 8500, '/child-orphan', 1, 'subagent');
            INSERT INTO thread_spawn_edges VALUES
                ('root-older', 'child-linked', 'closed');",
        )
        .expect("create conversation fixture");
    drop(connection);

    let all = list_sessions_for_provider(&home, 50, 0, Some("openai")).expect("all session rows");
    assert_eq!(all.total, 4);

    let conversations = list_conversations_for_provider(&home, 50, 0, Some("openai"))
        .expect("top-level conversations");
    assert_eq!(conversations.total, 2);
    assert_eq!(conversations.visible_total, Some(2));
    assert_eq!(
        conversations
            .sessions
            .iter()
            .map(|row| row.id.as_str())
            .collect::<Vec<_>>(),
        vec!["root-newest", "root-older"]
    );

    let search =
        search_conversations_for_provider(&home, "Shared conversation", 50, 0, Some("openai"))
            .expect("conversation search");
    assert_eq!(search.total, 1);
    assert_eq!(search.sessions[0].id, "root-older");

    let workspace =
        list_workspace_conversations_for_provider(&home, "/work/shared", 50, 0, Some("openai"))
            .expect("workspace conversations");
    assert_eq!(workspace.total, 1);
    assert_eq!(workspace.sessions[0].id, "root-older");

    let workspaces = list_conversation_workspaces(&home, 50, 0).expect("conversation workspaces");
    assert_eq!(workspaces.total, 2);
    assert_eq!(workspaces.workspaces[0].cwd, "/work/newest");
    let details = lookup_conversation_workspaces(&home, &["/work/shared".to_string()])
        .expect("conversation workspace details");
    assert_eq!(details.workspaces[0].session_count, 1);
}

#[test]
fn cli_list_uses_camel_case_and_optional_provider_visibility() {
    let (_temporary, home, _journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 2);
    let binary = env!("CARGO_BIN_EXE_ai-access-session-core");
    let output = Command::new(binary)
        .args([
            "list",
            "--codex-home",
            home.to_str().unwrap(),
            "--limit",
            "1",
            "--offset",
            "0",
            "--provider",
            "openai",
        ])
        .output()
        .expect("run list sidecar");
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let records = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(records.len(), 2);
    assert_eq!(records[0]["schema_version"], 1);
    let data = &records[1]["data"];
    assert_eq!(data["total"], 2);
    assert_eq!(data["visibleTotal"], 2);
    assert_eq!(data["limit"], 1);
    assert_eq!(data["hasMore"], true);
    assert!(data.get("databasePath").is_some());
    assert!(data.get("visible_total").is_none());
    let session = &data["sessions"][0];
    assert_eq!(session["currentProvider"], "openai");
    assert!(session.get("createdAt").is_some());
    assert!(session.get("updatedAt").is_some());
    assert!(session.get("rolloutPath").is_some());
    assert!(session.get("current_provider").is_none());
}

#[test]
fn search_is_sqlite_only_literal_bounded_and_paginated() {
    let (_temporary, home, _journal) = fixture();
    let database = home.join("state_5.sqlite");
    create_database(&database, 75);
    let connection = Connection::open(&database).unwrap();
    connection
        .execute(
            "UPDATE threads SET title = 'Budget 100%_done' WHERE id = 'thread-001'",
            [],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE threads SET title = 'Budget 100AAAdone' WHERE id = 'thread-002'",
            [],
        )
        .unwrap();
    drop(connection);
    let invalid_rollout = home.join("sessions/rollout-invalid.jsonl");
    fs::create_dir_all(invalid_rollout.parent().unwrap()).unwrap();
    fs::write(&invalid_rollout, b"not jsonl").unwrap();

    let literal = search_sessions_for_provider(&home, "%_", 50, 0, Some("openai"))
        .expect("literal wildcard search");
    assert_eq!(literal.total, 1);
    assert_eq!(literal.visible_total, Some(1));
    assert_eq!(literal.sessions[0].id, "thread-001");
    assert!(!literal.has_more);

    let page = search_sessions_for_provider(&home, "Title", 500, 0, None)
        .expect("bounded metadata search");
    assert_eq!(page.limit, 50);
    assert_eq!(page.total, 73);
    assert_eq!(page.sessions.len(), 50);
    assert!(page.has_more);
    let second =
        search_sessions_for_provider(&home, "Title", 50, 50, None).expect("second search page");
    assert_eq!(second.sessions.len(), 23);
    assert!(!second.has_more);

    for invalid in ["", "   ", "line\nbreak"] {
        let error = search_sessions_for_provider(&home, invalid, 50, 0, None)
            .expect_err("invalid query must fail");
        assert_eq!(error.code, "invalid_search_query");
    }
    let oversized = "x".repeat(201);
    let error = search_sessions_for_provider(&home, &oversized, 50, 0, None)
        .expect_err("oversized query must fail");
    assert_eq!(error.code, "invalid_search_query");
}

#[test]
fn cli_search_returns_only_metadata_page() {
    let (_temporary, home, _journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 2);
    let binary = env!("CARGO_BIN_EXE_ai-access-session-core");
    let output = Command::new(binary)
        .args([
            "search",
            "--codex-home",
            home.to_str().unwrap(),
            "--query",
            "Title 001",
            "--limit",
            "1",
            "--offset",
            "0",
            "--provider",
            "openai",
        ])
        .output()
        .expect("run search sidecar");
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let result: Value = serde_json::from_str(
        String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .last()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["command"], "search");
    assert_eq!(result["data"]["total"], 1);
    assert_eq!(result["data"]["sessions"][0]["id"], "thread-001");
    assert!(result["data"]["sessions"][0].get("preview").is_none());
    assert!(result["data"]["sessions"][0]
        .get("firstUserMessage")
        .is_none());
}

#[test]
fn workspace_aggregation_and_exact_sessions_are_bounded() {
    let (_temporary, home, _journal) = fixture();
    let database = home.join("state_5.sqlite");
    create_database(&database, 0);
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "INSERT INTO threads VALUES
             ('a-1', 'A1', '/work/a', 'openai', 0, 1, 40, '/r/a1', 0),
             ('a-2', 'A2', '/work/a', 'custom', 1, 2, 30, '/r/a2', 0),
             ('a-3', 'A3', '  /work/a  ', 'openai', 0, 3, 45, '/r/a3', 0),
             ('child', 'Child', '/work/a-child', 'openai', 0, 4, 50, '/r/child', 0),
             ('empty', 'Empty', '   ', 'openai', 0, 5, 60, '/r/empty', 0);",
        )
        .unwrap();
    drop(connection);

    let first = list_workspaces(&home, 1, 0).expect("first workspace page");
    assert_eq!(first.total, 2);
    assert_eq!(first.limit, 1);
    assert!(first.has_more);
    assert_eq!(first.workspaces[0].cwd, "/work/a-child");
    assert_eq!(first.workspaces[0].session_count, 1);
    assert_eq!(first.workspaces[0].archived_count, 0);
    assert_eq!(first.workspaces[0].latest_updated_at, json!(50));

    let second = list_workspaces(&home, 50, 1).expect("second workspace page");
    assert_eq!(second.workspaces.len(), 1);
    assert!(!second.has_more);
    assert_eq!(second.workspaces[0].cwd, "/work/a");
    assert_eq!(second.workspaces[0].session_count, 3);
    assert_eq!(second.workspaces[0].archived_count, 1);
    assert_eq!(second.workspaces[0].latest_updated_at, json!(45));

    let details = lookup_workspaces(&home, &[" /work/a ".to_string(), "/missing".to_string()])
        .expect("bounded workspace details");
    assert_eq!(details.limit, 2);
    assert_eq!(details.total, 1);
    assert_eq!(details.workspaces[0].cwd, "/work/a");
    assert_eq!(details.workspaces[0].session_count, 3);
    assert_eq!(details.workspaces[0].archived_count, 1);
    assert_eq!(details.workspaces[0].latest_updated_at, json!(45));

    let too_many = vec!["/work/a".to_string(); 21];
    let error =
        lookup_workspaces(&home, &too_many).expect_err("oversized workspace lookup must fail");
    assert_eq!(error.code, "invalid_workspace_paths");

    let sessions =
        list_workspace_sessions_for_provider(&home, "  /work/a  ", 50, 0, Some("openai"))
            .expect("exact workspace sessions");
    assert_eq!(sessions.total, 3);
    assert_eq!(sessions.visible_total, Some(2));
    assert_eq!(sessions.sessions.len(), 3);
    assert!(sessions.sessions.iter().all(|row| row.id != "child"));

    for invalid in ["", "   ", "line\nbreak"] {
        let error = list_workspace_sessions_for_provider(&home, invalid, 50, 0, None)
            .expect_err("invalid workspace must fail");
        assert_eq!(error.code, "invalid_workspace_path");
    }
    let oversized = "x".repeat(4097);
    let error = list_workspace_sessions_for_provider(&home, &oversized, 50, 0, None)
        .expect_err("oversized workspace must fail");
    assert_eq!(error.code, "invalid_workspace_path");
}

#[test]
fn cli_workspace_commands_return_only_metadata() {
    let (_temporary, home, _journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 2);
    let binary = env!("CARGO_BIN_EXE_ai-access-session-core");

    let aggregate = Command::new(binary)
        .args([
            "workspaces",
            "--codex-home",
            home.to_str().unwrap(),
            "--limit",
            "1",
            "--offset",
            "0",
        ])
        .output()
        .expect("run workspaces sidecar");
    assert!(aggregate.status.success());
    assert!(aggregate.stderr.is_empty());
    let aggregate_result: Value = serde_json::from_str(
        String::from_utf8(aggregate.stdout)
            .unwrap()
            .lines()
            .last()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(aggregate_result["command"], "workspaces");
    assert_eq!(aggregate_result["data"]["total"], 2);
    assert_eq!(aggregate_result["data"]["workspaces"][0]["sessionCount"], 1);
    assert!(aggregate_result["data"]["workspaces"][0]
        .get("latestUpdatedAt")
        .is_some());

    let details = Command::new(binary)
        .args([
            "workspace-details",
            "--codex-home",
            home.to_str().unwrap(),
            "--cwds-json",
            r#"["/workspace/001","/workspace/000","/missing"]"#,
        ])
        .output()
        .expect("run workspace-details sidecar");
    assert!(details.status.success());
    assert!(details.stderr.is_empty());
    let details_result: Value = serde_json::from_str(
        String::from_utf8(details.stdout)
            .unwrap()
            .lines()
            .last()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(details_result["command"], "workspace-details");
    assert_eq!(details_result["data"]["total"], 2);
    assert_eq!(
        details_result["data"]["workspaces"][0]["cwd"],
        "/workspace/001"
    );
    assert_eq!(
        details_result["data"]["workspaces"][1]["cwd"],
        "/workspace/000"
    );

    let sessions = Command::new(binary)
        .args([
            "workspace-sessions",
            "--codex-home",
            home.to_str().unwrap(),
            "--cwd",
            "/workspace/001",
            "--provider",
            "openai",
        ])
        .output()
        .expect("run workspace-sessions sidecar");
    assert!(sessions.status.success());
    assert!(sessions.stderr.is_empty());
    let sessions_result: Value = serde_json::from_str(
        String::from_utf8(sessions.stdout)
            .unwrap()
            .lines()
            .last()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(sessions_result["command"], "workspace-sessions");
    assert_eq!(sessions_result["data"]["total"], 1);
    assert_eq!(sessions_result["data"]["sessions"][0]["id"], "thread-001");
    assert!(sessions_result["data"]["sessions"][0]
        .get("preview")
        .is_none());
}

#[test]
fn interrupted_journal_is_read_only_bound_and_camel_case() {
    let (_temporary, home, _journal) = fixture();
    let absent_root = home.join("absent-recovery");
    assert_eq!(
        interrupted_journal(&home, &absent_root).expect("no lock is not an error"),
        None
    );

    let recovery_root = home.join("recovery");
    fs::create_dir(&recovery_root).unwrap();
    let transaction_id = "01234567-89ab-4def-8123-456789abcdef";
    let journal_directory = recovery_root.join(transaction_id);
    fs::create_dir(&journal_directory).unwrap();
    let canonical_home = fs::canonicalize(&home).unwrap();
    fs::write(
        journal_directory.join("journal.json"),
        serde_json::to_vec(&json!({
            "version": 1,
            "transactionId": transaction_id,
            "codexHome": canonical_home,
            "createdAtUnixSeconds": 1,
            "state": "applying_rollouts",
            "databaseBackupComplete": false,
            "encryptedPayload": {
                "algorithm": "AES-256-GCM",
                "nonce": "",
                "ciphertext": ""
            }
        }))
        .unwrap(),
    )
    .unwrap();
    let lock_directory = home.join("tmp");
    fs::create_dir(&lock_directory).unwrap();
    let lock = lock_directory.join("ai-access-session-core.lock");
    fs::write(
        &lock,
        serde_json::to_vec(&json!({
            "version": 1,
            "transactionId": transaction_id,
            "pid": u32::MAX,
            "startedAtUnixSeconds": 1,
            "stage": "applying_rollouts"
        }))
        .unwrap(),
    )
    .unwrap();

    let pending = interrupted_journal(&home, &recovery_root)
        .expect("dead transaction is discoverable")
        .expect("pending journal");
    assert_eq!(pending.transaction_id, transaction_id);
    assert_eq!(
        pending.journal_path,
        Some(fs::canonicalize(&journal_directory).unwrap())
    );
    assert!(!pending.prewrite);

    let binary = env!("CARGO_BIN_EXE_ai-access-session-core");
    let output = Command::new(binary)
        .args([
            "pending",
            "--codex-home",
            home.to_str().unwrap(),
            "--recovery-root",
            recovery_root.to_str().unwrap(),
        ])
        .output()
        .expect("run pending sidecar");
    assert!(output.status.success());
    let result: Value = serde_json::from_str(
        String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .last()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["data"]["journal"]["transactionId"], transaction_id);
    assert!(result["data"]["journal"].get("journalPath").is_some());
    assert_eq!(result["data"]["journal"]["prewrite"], false);
    assert!(result["data"]["journal"].get("transaction_id").is_none());

    let manifest_path = journal_directory.join("journal.json");
    let mut large_manifest: Value =
        serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    large_manifest["padding"] = Value::String("x".repeat(5 * 1024 * 1024));
    fs::write(&manifest_path, serde_json::to_vec(&large_manifest).unwrap()).unwrap();
    let large_pending = interrupted_journal(&home, &recovery_root)
        .expect("journal above the legacy 4 MiB limit is accepted")
        .expect("large pending journal");
    assert_eq!(large_pending.transaction_id, transaction_id);

    fs::write(
        &lock,
        serde_json::to_vec(&json!({
            "version": 1,
            "transactionId": transaction_id,
            "pid": std::process::id(),
            "startedAtUnixSeconds": 1,
            "stage": "applying_rollouts"
        }))
        .unwrap(),
    )
    .unwrap();
    let active = interrupted_journal(&home, &recovery_root)
        .expect_err("live transaction must remain locked");
    assert_eq!(active.code, "transaction_locked");

    fs::write(
        &lock,
        serde_json::to_vec(&json!({
            "version": 1,
            "transactionId": "not-a-uuid",
            "pid": u32::MAX,
            "startedAtUnixSeconds": 1,
            "stage": "applying_rollouts"
        }))
        .unwrap(),
    )
    .unwrap();
    let invalid = interrupted_journal(&home, &recovery_root)
        .expect_err("invalid transaction ID must fail closed");
    assert_eq!(invalid.code, "invalid_transaction_lock");
}

#[test]
fn stale_prewrite_lock_is_archived_only_before_any_journal_exists() {
    let (_temporary, home, _journal) = fixture();
    let recovery_root = home.join("recovery");
    fs::create_dir(&recovery_root).unwrap();
    let lock_directory = home.join("tmp");
    fs::create_dir(&lock_directory).unwrap();
    let lock = lock_directory.join("ai-access-session-core.lock");
    let transaction_id = "11234567-89ab-4def-8123-456789abcdef";
    fs::write(
        &lock,
        serde_json::to_vec(&json!({
            "version": 1,
            "transactionId": transaction_id,
            "pid": u32::MAX,
            "startedAtUnixSeconds": 1,
            "stage": "inspect"
        }))
        .unwrap(),
    )
    .unwrap();

    let pending = interrupted_journal(&home, &recovery_root)
        .expect("prewrite lock is discoverable")
        .expect("pending prewrite");
    assert_eq!(pending.transaction_id, transaction_id);
    assert_eq!(pending.journal_path, None);
    assert!(pending.prewrite);

    let binary = env!("CARGO_BIN_EXE_ai-access-session-core");
    let output = Command::new(binary)
        .args([
            "clear-prewrite-lock",
            "--codex-home",
            home.to_str().unwrap(),
            "--recovery-root",
            recovery_root.to_str().unwrap(),
            "--transaction-id",
            transaction_id,
        ])
        .output()
        .expect("clear stale prewrite lock");
    assert!(output.status.success());
    let result: Value = serde_json::from_str(
        String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .last()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result["data"]["transactionId"], transaction_id);
    assert_eq!(result["data"]["cleared"], true);
    assert!(!lock.exists());
    assert_eq!(
        fs::read_dir(&lock_directory)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("ai-access-session-core.lock.prewrite-")
            })
            .count(),
        1
    );
    assert_eq!(interrupted_journal(&home, &recovery_root).unwrap(), None);

    let write_stage_id = "21234567-89ab-4def-8123-456789abcdef";
    fs::write(
        &lock,
        serde_json::to_vec(&json!({
            "version": 1,
            "transactionId": write_stage_id,
            "pid": u32::MAX,
            "startedAtUnixSeconds": 1,
            "stage": "applying_rollouts"
        }))
        .unwrap(),
    )
    .unwrap();
    let forbidden = clear_stale_prewrite_lock(&home, &recovery_root, write_stage_id)
        .expect_err("write-stage lock must never be cleared");
    assert_eq!(forbidden.code, "prewrite_clear_forbidden");
    assert!(lock.exists());

    let journal_id = "31234567-89ab-4def-8123-456789abcdef";
    fs::write(
        &lock,
        serde_json::to_vec(&json!({
            "version": 1,
            "transactionId": journal_id,
            "pid": u32::MAX,
            "startedAtUnixSeconds": 1,
            "stage": "preparing_recovery"
        }))
        .unwrap(),
    )
    .unwrap();
    fs::create_dir(recovery_root.join(journal_id)).unwrap();
    let journal_exists = clear_stale_prewrite_lock(&home, &recovery_root, journal_id)
        .expect_err("prewrite lock with journal directory must not be cleared");
    assert_eq!(journal_exists.code, "prewrite_journal_exists");
    assert!(lock.exists());
}

#[test]
fn inspect_and_repair_active_and_archived_sessions_without_touching_nested_db() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-active",
        "openai",
        "/old/active",
        0,
    );
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-archived",
        "legacy",
        "/old/archived",
        0,
    );
    let (active, active_original) = write_rollout(
        &home,
        "sessions/2026/rollout-active.jsonl",
        "thread-active",
        "openai",
        "/new/active",
        true,
    );
    let (archived, archived_original) = write_rollout(
        &home,
        "archived_sessions/rollout-archived.jsonl",
        "thread-archived",
        "legacy",
        "/new/archived",
        false,
    );
    let nested = home.join("sqlite/codex-dev.db");
    fs::create_dir_all(nested.parent().unwrap()).unwrap();
    create_database(&nested, 0);
    insert_thread(&nested, "thread-nested", "do-not-touch", "/nested", 0);

    let preview = inspect(&home, "custom").expect("inspect");
    assert_eq!(preview.rollout_files, 2);
    assert_eq!(preview.session_meta_records, 2);
    assert_eq!(preview.rollout_files_needing_repair, 2);
    assert_eq!(preview.rollout_patch_count, 2);
    assert_eq!(preview.journal_limit_bytes, 64 * 1024 * 1024);
    assert!(preview.estimated_journal_bytes > 0);
    assert!(preview.capacity_safe);
    assert_eq!(preview.sqlite_provider_mismatches, 2);
    assert!(preview.needs_repair);

    let result = repair(&home, "custom", &journal, &JOURNAL_KEY).expect("repair");
    assert_eq!(result.changed_rollout_files, 2);
    assert_eq!(result.changed_session_meta_records, 2);
    assert_eq!(result.sqlite_provider_rows_updated, 2);
    assert_eq!(
        provider(&home.join("state_5.sqlite"), "thread-active"),
        "custom"
    );
    assert_eq!(
        provider(&home.join("state_5.sqlite"), "thread-archived"),
        "custom"
    );
    assert_eq!(provider(&nested, "thread-nested"), "do-not-touch");

    let active_text = fs::read_to_string(&active).unwrap();
    let active_expected =
        String::from_utf8(active_original)
            .unwrap()
            .replacen("\"openai\"", "\"custom\"", 1);
    assert_eq!(active_text, active_expected);
    let archived_text = fs::read_to_string(&archived).unwrap();
    let archived_expected =
        String::from_utf8(archived_original)
            .unwrap()
            .replacen("\"legacy\"", "\"custom\"", 1);
    assert_eq!(archived_text, archived_expected);

    let connection = Connection::open(home.join("state_5.sqlite")).unwrap();
    let active_evidence: (i64, String) = connection
        .query_row(
            "SELECT has_user_event, cwd FROM threads WHERE id = 'thread-active'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(active_evidence, (1, "/new/active".to_string()));
    let archived_evidence: (i64, String) = connection
        .query_row(
            "SELECT has_user_event, cwd FROM threads WHERE id = 'thread-archived'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(archived_evidence, (0, "/new/archived".to_string()));
}

#[test]
fn explicit_rollback_restores_exact_rollout_bytes_and_sqlite() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-1",
        "openai",
        "/old",
        0,
    );
    let (rollout, original) = write_rollout(
        &home,
        "sessions/rollout-one.jsonl",
        "thread-1",
        "openai",
        "/new",
        true,
    );

    let repaired = repair(&home, "custom", &journal, &JOURNAL_KEY).expect("repair");
    let recovery_path = repaired.journal_path.expect("journal path");
    assert_ne!(fs::read(&rollout).unwrap(), original);
    assert_eq!(provider(&home.join("state_5.sqlite"), "thread-1"), "custom");

    let manifest = fs::read_to_string(recovery_path.join("journal.json")).unwrap();
    for sensitive in [
        "thread-1",
        "model_provider",
        "/old",
        "/new",
        "\"openai\"",
        "\"custom\"",
    ] {
        assert!(
            !manifest.contains(sensitive),
            "journal leaked sensitive marker {sensitive}"
        );
    }
    assert!(manifest.contains("\"encryptedPayload\""));
    assert!(manifest.contains("\"codexHome\""));
    let encrypted_backup = recovery_path.join("state_5.sqlite.backup.aesgcm");
    let backup_bytes = fs::read(&encrypted_backup).unwrap();
    assert!(!backup_bytes.starts_with(b"SQLite format 3"));
    assert!(!recovery_path
        .join(".state_5.sqlite.backup.plaintext.tmp")
        .exists());
    #[cfg(unix)]
    assert_eq!(
        fs::metadata(&encrypted_backup)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );

    let wrong_key = [0x11; 32];
    let error = rollback(&recovery_path, &wrong_key).expect_err("wrong key must fail");
    assert_eq!(error.code, "journal_decryption_failed");
    assert_ne!(fs::read(&rollout).unwrap(), original);
    assert_eq!(provider(&home.join("state_5.sqlite"), "thread-1"), "custom");

    let restored = rollback(&recovery_path, &JOURNAL_KEY).expect("rollback");
    assert_eq!(restored.restored_rollout_files, 1);
    assert!(restored.database_restored);
    assert_eq!(fs::read(&rollout).unwrap(), original);
    assert_eq!(provider(&home.join("state_5.sqlite"), "thread-1"), "openai");

    let repeated = rollback(&recovery_path, &JOURNAL_KEY).expect("idempotent rollback");
    assert!(repeated.already_rolled_back);
}

#[test]
fn rollback_accepts_24mib_manifest_and_rejects_unbounded_manifest() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-large-journal",
        "openai",
        "/old",
        0,
    );
    let (rollout, original) = write_rollout(
        &home,
        "sessions/rollout-large-journal.jsonl",
        "thread-large-journal",
        "openai",
        "/new",
        true,
    );
    let repaired = repair(&home, "custom", &journal, &JOURNAL_KEY).expect("repair");
    let recovery_path = repaired.journal_path.expect("journal path");
    let manifest_path = recovery_path.join("journal.json");
    let mut manifest: Value = serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    manifest["padding"] = Value::String("x".repeat(24 * 1024 * 1024));
    fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    assert!(fs::metadata(&manifest_path).unwrap().len() > 4 * 1024 * 1024);

    rollback(&recovery_path, &JOURNAL_KEY).expect("24 MiB recovery journal");
    assert_eq!(
        provider(&home.join("state_5.sqlite"), "thread-large-journal"),
        "openai"
    );
    assert_eq!(fs::read(&rollout).unwrap(), original);

    let oversized = journal.join("oversized");
    fs::create_dir(&oversized).unwrap();
    let oversized_manifest = oversized.join("journal.json");
    let file = fs::File::create(&oversized_manifest).unwrap();
    file.set_len(64 * 1024 * 1024 + 1).unwrap();
    let error = rollback(&oversized, &JOURNAL_KEY).expect_err("unbounded journal must fail");
    assert_eq!(error.code, "journal_too_large");
}

#[test]
fn injected_failure_rolls_back_every_surface() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-1",
        "openai",
        "/old",
        0,
    );
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-2",
        "openai",
        "/old",
        0,
    );
    let (first, first_original) = write_rollout(
        &home,
        "sessions/rollout-one.jsonl",
        "thread-1",
        "openai",
        "/new/one",
        true,
    );
    let (second, second_original) = write_rollout(
        &home,
        "sessions/rollout-two.jsonl",
        "thread-2",
        "openai",
        "/new/two",
        true,
    );
    let mut options = RepairOptions::new(&journal);
    options.failure_point = Some(FailurePoint::AfterSqlite);

    let error = repair_with_options(&home, "custom", options, &JOURNAL_KEY, |_| {})
        .expect_err("injected repair must fail");
    assert_eq!(error.code, "injected_failure");
    assert!(error.message.contains("rolled back"));
    assert_eq!(fs::read(first).unwrap(), first_original);
    assert_eq!(fs::read(second).unwrap(), second_original);
    assert_eq!(provider(&home.join("state_5.sqlite"), "thread-1"), "openai");
    assert_eq!(provider(&home.join("state_5.sqlite"), "thread-2"), "openai");
}

#[test]
fn caller_supplied_transaction_id_determines_recovery_path() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-1",
        "openai",
        "/old",
        0,
    );
    let (rollout, original) = write_rollout(
        &home,
        "sessions/rollout-supplied-id.jsonl",
        "thread-1",
        "openai",
        "/new",
        true,
    );
    let transaction_id = "12345678-1234-4234-8234-123456789abc";
    let options = RepairOptions::new(&journal).with_transaction_id(transaction_id);
    let summary = repair_with_options(&home, "custom", options, &JOURNAL_KEY, |_| {})
        .expect("repair with supplied transaction ID");
    assert_eq!(summary.transaction_id.as_deref(), Some(transaction_id));
    let expected_journal = fs::canonicalize(&journal).unwrap().join(transaction_id);
    assert_eq!(
        summary.journal_path.as_deref(),
        Some(expected_journal.as_path())
    );
    assert!(expected_journal.join("journal.json").is_file());
    rollback(summary.journal_path.as_deref().unwrap(), &JOURNAL_KEY)
        .expect("rollback supplied transaction journal");
    assert_eq!(fs::read(rollout).unwrap(), original);

    let invalid = RepairOptions::new(&journal).with_transaction_id("not-a-uuid");
    let error = repair_with_options(&home, "custom", invalid, &JOURNAL_KEY, |_| {})
        .expect_err("invalid supplied transaction ID must fail");
    assert_eq!(error.code, "invalid_transaction_id");
}

#[test]
fn malformed_rollout_or_unknown_schema_never_partially_writes() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-1",
        "openai",
        "/old",
        0,
    );
    let malformed = home.join("sessions/rollout-broken.jsonl");
    fs::create_dir_all(malformed.parent().unwrap()).unwrap();
    fs::write(&malformed, b"{broken json\n").unwrap();
    let error = repair(&home, "custom", &journal, &JOURNAL_KEY).expect_err("malformed rollout");
    assert_eq!(error.code, "invalid_rollout_json");
    assert_eq!(fs::read(&malformed).unwrap(), b"{broken json\n");
    assert_eq!(provider(&home.join("state_5.sqlite"), "thread-1"), "openai");

    fs::remove_file(&malformed).unwrap();
    let (rollout, original) = write_rollout(
        &home,
        "sessions/rollout-good.jsonl",
        "thread-1",
        "openai",
        "/new",
        true,
    );
    fs::remove_file(home.join("state_5.sqlite")).unwrap();
    let unsupported = Connection::open(home.join("state_5.sqlite")).unwrap();
    unsupported
        .execute("CREATE TABLE threads (id TEXT PRIMARY KEY)", [])
        .unwrap();
    drop(unsupported);
    let error = repair(&home, "custom", &journal, &JOURNAL_KEY).expect_err("unknown schema");
    assert_eq!(error.code, "unsupported_sqlite_schema");
    assert_eq!(fs::read(rollout).unwrap(), original);
}

#[test]
fn missing_provider_is_inserted_minimally_and_duplicate_provider_fails_closed() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-1",
        "openai",
        "/old",
        0,
    );
    let rollout = home.join("sessions/rollout-missing-provider.jsonl");
    fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    let original = b"{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-1\",\"cwd\":\"/new\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\"}}\n";
    fs::write(&rollout, original).unwrap();

    let result = repair(&home, "custom", &journal, &JOURNAL_KEY).expect("insert provider");
    let first: Value = serde_json::from_str(
        fs::read_to_string(&rollout)
            .unwrap()
            .lines()
            .next()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(first["payload"]["model_provider"], "custom");
    rollback(&result.journal_path.unwrap(), &JOURNAL_KEY)
        .expect("restore missing-provider rollout");
    assert_eq!(fs::read(&rollout).unwrap(), original);

    fs::write(
        &rollout,
        b"{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-1\",\"cwd\":\"/new\",\"model_provider\":\"a\",\"model_provider\":\"b\"}}\n",
    )
    .unwrap();
    let error =
        repair(&home, "custom", &journal, &JOURNAL_KEY).expect_err("duplicate provider must fail");
    assert_eq!(error.code, "invalid_session_meta");
    assert!(fs::read_to_string(&rollout)
        .unwrap()
        .contains("\"model_provider\":\"a\",\"model_provider\":\"b\""));
}

#[test]
fn unknown_sqlite_user_version_is_readable_but_never_repaired() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-1",
        "openai",
        "/old",
        0,
    );
    let connection = Connection::open(home.join("state_5.sqlite")).unwrap();
    connection.pragma_update(None, "user_version", 999).unwrap();
    connection
        .execute("ALTER TABLE threads ADD COLUMN future_field TEXT", [])
        .unwrap();
    drop(connection);
    let (rollout, original) = write_rollout(
        &home,
        "sessions/rollout-future.jsonl",
        "thread-1",
        "openai",
        "/new",
        true,
    );

    let page = list_sessions(&home, 50, 0).expect("unknown schema remains listable");
    assert_eq!(page.total, 1);
    let error = repair(&home, "custom", &journal, &JOURNAL_KEY)
        .expect_err("unknown schema must block writes");
    assert_eq!(error.code, "unsupported_sqlite_schema");
    assert!(error.message.contains("user_version 999"));
    assert_eq!(fs::read(rollout).unwrap(), original);
    assert_eq!(provider(&home.join("state_5.sqlite"), "thread-1"), "openai");
}

#[test]
fn existing_lock_fails_closed() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    let lock = home.join("tmp/ai-access-session-core.lock");
    fs::create_dir_all(lock.parent().unwrap()).unwrap();
    fs::write(
        &lock,
        serde_json::to_vec(&json!({
            "version": 1,
            "transactionId": "live-transaction",
            "pid": std::process::id(),
            "startedAtUnixSeconds": 1,
            "stage": "applying_rollouts"
        }))
        .unwrap(),
    )
    .unwrap();

    let error = repair(&home, "custom", &journal, &JOURNAL_KEY).expect_err("lock must block");
    assert_eq!(error.code, "transaction_locked");
}

#[test]
fn matching_dead_lock_can_be_taken_over_only_by_its_rollback() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-1",
        "openai",
        "/old",
        0,
    );
    let (rollout, original) = write_rollout(
        &home,
        "sessions/rollout-one.jsonl",
        "thread-1",
        "openai",
        "/new",
        true,
    );
    let repaired = repair(&home, "custom", &journal, &JOURNAL_KEY).unwrap();
    let transaction_id = repaired.transaction_id.clone().unwrap();
    let lock = home.join("tmp/ai-access-session-core.lock");
    fs::write(
        &lock,
        serde_json::to_vec(&json!({
            "version": 1,
            "transactionId": transaction_id,
            "pid": i32::MAX as u32,
            "startedAtUnixSeconds": 1,
            "stage": "applying_sqlite"
        }))
        .unwrap(),
    )
    .unwrap();
    let blocked_repair = repair(&home, "custom", &journal, &JOURNAL_KEY)
        .expect_err("dead lock must require recovery");
    assert_eq!(blocked_repair.code, "recovery_required");
    rollback(&repaired.journal_path.unwrap(), &JOURNAL_KEY).expect("matching stale takeover");
    assert_eq!(fs::read(&rollout).unwrap(), original);
    let archived_lock_exists = fs::read_dir(home.join("tmp"))
        .unwrap()
        .filter_map(Result::ok)
        .any(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("ai-access-session-core.lock.stale-")
        });
    assert!(archived_lock_exists);

    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-1",
        "openai",
        "/old",
        0,
    );
    let (rollout, _original) = write_rollout(
        &home,
        "sessions/rollout-one.jsonl",
        "thread-1",
        "openai",
        "/new",
        true,
    );
    let repaired = repair(&home, "custom", &journal, &JOURNAL_KEY).unwrap();
    let repaired_bytes = fs::read(&rollout).unwrap();
    let lock = home.join("tmp/ai-access-session-core.lock");
    fs::write(
        &lock,
        serde_json::to_vec(&json!({
            "version": 1,
            "transactionId": "different-interrupted-transaction",
            "pid": i32::MAX as u32,
            "startedAtUnixSeconds": 1,
            "stage": "applying_rollouts"
        }))
        .unwrap(),
    )
    .unwrap();
    let error = rollback(&repaired.journal_path.unwrap(), &JOURNAL_KEY)
        .expect_err("mismatched stale lock must block");
    assert_eq!(error.code, "stale_lock_mismatch");
    assert_eq!(fs::read(&rollout).unwrap(), repaired_bytes);
}

#[test]
fn rollback_preserves_new_threads_unmanaged_columns_and_appended_rollout_bytes() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-1",
        "openai",
        "/old",
        0,
    );
    let (rollout, original) = write_rollout(
        &home,
        "sessions/rollout-one.jsonl",
        "thread-1",
        "openai",
        "/new",
        true,
    );
    let repaired = repair(&home, "custom", &journal, &JOURNAL_KEY).expect("repair");
    let recovery_path = repaired.journal_path.expect("journal path");
    let database = home.join("state_5.sqlite");
    let connection = Connection::open(&database).unwrap();
    connection
        .execute(
            "UPDATE threads SET title = 'Renamed after repair' WHERE id = 'thread-1'",
            [],
        )
        .unwrap();
    drop(connection);
    insert_thread(&database, "thread-created-later", "custom", "/later", 1);
    let (later_rollout, later_rollout_bytes) = write_rollout(
        &home,
        "sessions/rollout-created-later.jsonl",
        "thread-created-later",
        "custom",
        "/later",
        true,
    );
    let appended =
        b"{\"type\":\"response_item\",\"payload\":{\"message\":\"created after repair\"}}\n";
    let mut rollout_file = fs::OpenOptions::new().append(true).open(&rollout).unwrap();
    rollout_file.write_all(appended).unwrap();
    rollout_file.sync_all().unwrap();
    drop(rollout_file);
    let repaired_with_append = fs::read(&rollout).unwrap();
    assert!(repaired_with_append.ends_with(appended));

    rollback(&recovery_path, &JOURNAL_KEY).expect("managed inverse rollback");
    let connection = Connection::open(&database).unwrap();
    let original_row: (String, String, i64, String) = connection
        .query_row(
            "SELECT title, model_provider, has_user_event, cwd
             FROM threads WHERE id = 'thread-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .unwrap();
    assert_eq!(
        original_row,
        (
            "Renamed after repair".to_string(),
            "openai".to_string(),
            0,
            "/old".to_string()
        )
    );
    let later_row: (String, String, i64) = connection
        .query_row(
            "SELECT model_provider, cwd, has_user_event
             FROM threads WHERE id = 'thread-created-later'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(later_row, ("custom".to_string(), "/later".to_string(), 1));
    let mut expected = original;
    expected.extend_from_slice(appended);
    assert_eq!(fs::read(&rollout).unwrap(), expected);
    assert_eq!(fs::read(later_rollout).unwrap(), later_rollout_bytes);
}

#[test]
fn rollback_preserves_unrelated_session_meta_edits_while_reverting_provider() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-1",
        "openai",
        "/same",
        1,
    );
    let (rollout, _original) = write_rollout(
        &home,
        "sessions/rollout-one.jsonl",
        "thread-1",
        "openai",
        "/same",
        true,
    );
    let repaired = repair(&home, "custom", &journal, &JOURNAL_KEY).expect("repair");
    let current = fs::read_to_string(&rollout)
        .unwrap()
        .replace("\"other\":true", "\"other\":{\"later\":1}");
    fs::write(&rollout, current).unwrap();

    rollback(&repaired.journal_path.unwrap(), &JOURNAL_KEY).expect("three-way rollback");
    let restored = fs::read_to_string(&rollout).unwrap();
    assert!(restored.contains("\"model_provider\" : \"openai\""));
    assert!(restored.contains("\"other\":{\"later\":1}"));
}

#[test]
fn sqlite_managed_field_conflict_rejects_every_surface_before_writes() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 0);
    insert_thread(
        &home.join("state_5.sqlite"),
        "thread-1",
        "openai",
        "/old",
        0,
    );
    let (rollout, _original) = write_rollout(
        &home,
        "sessions/rollout-one.jsonl",
        "thread-1",
        "openai",
        "/new",
        true,
    );
    let repaired = repair(&home, "custom", &journal, &JOURNAL_KEY).expect("repair");
    let repaired_bytes = fs::read(&rollout).unwrap();
    let database = home.join("state_5.sqlite");
    Connection::open(&database)
        .unwrap()
        .execute(
            "UPDATE threads SET model_provider = 'third-party' WHERE id = 'thread-1'",
            [],
        )
        .unwrap();

    let error = rollback(&repaired.journal_path.unwrap(), &JOURNAL_KEY)
        .expect_err("fourth SQLite value must fail closed");
    assert_eq!(error.code, "concurrent_sqlite_change");
    assert_eq!(provider(&database, "thread-1"), "third-party");
    assert_eq!(fs::read(&rollout).unwrap(), repaired_bytes);
}

#[test]
fn rollout_managed_field_conflict_rejects_all_files_and_sqlite_before_writes() {
    let (_temporary, home, journal) = fixture();
    let database = home.join("state_5.sqlite");
    create_database(&database, 0);
    for thread in ["thread-a", "thread-b"] {
        insert_thread(&database, thread, "openai", "/same", 1);
    }
    let (first, _first_original) = write_rollout(
        &home,
        "sessions/rollout-a.jsonl",
        "thread-a",
        "openai",
        "/same",
        true,
    );
    let (second, _second_original) = write_rollout(
        &home,
        "sessions/rollout-b.jsonl",
        "thread-b",
        "openai",
        "/same",
        true,
    );
    let repaired = repair(&home, "custom", &journal, &JOURNAL_KEY).expect("repair");
    let first_repaired = fs::read(&first).unwrap();
    let second_repaired = fs::read_to_string(&second).unwrap();
    fs::write(
        &second,
        second_repaired.replacen("\"custom\"", "\"third-party\"", 1),
    )
    .unwrap();
    let second_conflicted = fs::read(&second).unwrap();

    let error = rollback(&repaired.journal_path.unwrap(), &JOURNAL_KEY)
        .expect_err("fourth rollout provider must fail closed");
    assert_eq!(error.code, "concurrent_rollout_change");
    assert_eq!(fs::read(&first).unwrap(), first_repaired);
    assert_eq!(fs::read(&second).unwrap(), second_conflicted);
    assert_eq!(provider(&database, "thread-a"), "custom");
    assert_eq!(provider(&database, "thread-b"), "custom");
}

#[test]
fn deleted_transaction_row_rejects_rollback_without_rollout_writes() {
    let (_temporary, home, journal) = fixture();
    let database = home.join("state_5.sqlite");
    create_database(&database, 0);
    insert_thread(&database, "thread-1", "openai", "/old", 0);
    let (rollout, _original) = write_rollout(
        &home,
        "sessions/rollout-one.jsonl",
        "thread-1",
        "openai",
        "/new",
        true,
    );
    let repaired = repair(&home, "custom", &journal, &JOURNAL_KEY).expect("repair");
    let repaired_bytes = fs::read(&rollout).unwrap();
    Connection::open(&database)
        .unwrap()
        .execute("DELETE FROM threads WHERE id = 'thread-1'", [])
        .unwrap();

    let error = rollback(&repaired.journal_path.unwrap(), &JOURNAL_KEY)
        .expect_err("deleted original row must block");
    assert_eq!(error.code, "concurrent_sqlite_change");
    assert_eq!(fs::read(&rollout).unwrap(), repaired_bytes);
}

#[test]
fn deleted_managed_rollout_rejects_rollback_without_sqlite_writes() {
    let (_temporary, home, journal) = fixture();
    let database = home.join("state_5.sqlite");
    create_database(&database, 0);
    insert_thread(&database, "thread-1", "openai", "/same", 1);
    let (rollout, _original) = write_rollout(
        &home,
        "sessions/rollout-one.jsonl",
        "thread-1",
        "openai",
        "/same",
        true,
    );
    let repaired = repair(&home, "custom", &journal, &JOURNAL_KEY).expect("repair");
    fs::remove_file(rollout).unwrap();

    let error = rollback(&repaired.journal_path.unwrap(), &JOURNAL_KEY)
        .expect_err("deleted managed rollout must block");
    assert_eq!(error.code, "concurrent_rollout_change");
    assert_eq!(provider(&database, "thread-1"), "custom");
}

#[test]
#[cfg(unix)]
fn rollback_write_failure_compensates_prior_files_and_retry_succeeds() {
    let (_temporary, home, journal) = fixture();
    let database = home.join("state_5.sqlite");
    create_database(&database, 0);
    for thread in ["thread-a", "thread-z"] {
        insert_thread(&database, thread, "openai", "/same", 1);
    }
    let (first, first_original) = write_rollout(
        &home,
        "sessions/a/rollout-a.jsonl",
        "thread-a",
        "openai",
        "/same",
        true,
    );
    let (second, second_original) = write_rollout(
        &home,
        "sessions/z/rollout-z.jsonl",
        "thread-z",
        "openai",
        "/same",
        true,
    );
    let repaired = repair(&home, "custom", &journal, &JOURNAL_KEY).expect("repair");
    let recovery_path = repaired.journal_path.unwrap();
    let appended = b"{\"type\":\"response_item\",\"payload\":{\"later\":true}}\n";
    let mut first_file = fs::OpenOptions::new().append(true).open(&first).unwrap();
    first_file.write_all(appended).unwrap();
    first_file.sync_all().unwrap();
    drop(first_file);
    let first_transaction_state = fs::read(&first).unwrap();
    let second_transaction_state = fs::read(&second).unwrap();

    let blocked_parent = second.parent().unwrap();
    let original_parent_mode = fs::metadata(blocked_parent).unwrap().permissions().mode() & 0o7777;
    fs::set_permissions(blocked_parent, fs::Permissions::from_mode(0o500)).unwrap();
    let error = rollback(&recovery_path, &JOURNAL_KEY)
        .expect_err("second atomic write must fail and compensate first");
    fs::set_permissions(
        blocked_parent,
        fs::Permissions::from_mode(original_parent_mode),
    )
    .unwrap();

    assert_eq!(error.code, "atomic_write_failed");
    assert_eq!(fs::read(&first).unwrap(), first_transaction_state);
    assert_eq!(fs::read(&second).unwrap(), second_transaction_state);
    assert_eq!(provider(&database, "thread-a"), "custom");
    assert_eq!(provider(&database, "thread-z"), "custom");

    rollback(&recovery_path, &JOURNAL_KEY).expect("retry rollback_failed journal");
    let mut expected_first = first_original;
    expected_first.extend_from_slice(appended);
    assert_eq!(fs::read(&first).unwrap(), expected_first);
    assert_eq!(fs::read(&second).unwrap(), second_original);
    assert_eq!(provider(&database, "thread-a"), "openai");
    assert_eq!(provider(&database, "thread-z"), "openai");
}

#[test]
fn import_batch_commits_and_explicit_rollback_removes_imported_state() {
    let (temporary, home, journal_root) = fixture();
    let database = home.join("state_5.sqlite");
    create_import_database(&database);
    let source = temporary.path().join("external");
    let first_id = "11111111-1111-4111-8111-111111111111";
    let second_id = "22222222-2222-4222-8222-222222222222";
    let (first_source, first_bytes) =
        write_external_rollout(&source, "first.jsonl", first_id, "Imported question one");
    let (second_source, second_bytes) = write_external_rollout(
        &source,
        "archived_sessions/second.jsonl",
        second_id,
        "Imported question two",
    );
    let transaction_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    let summary = import_sessions_with_options(
        &home,
        &source,
        ImportOptions::new(&journal_root).with_transaction_id(transaction_id),
        &JOURNAL_KEY,
        |_| {},
    )
    .expect("import external sessions");

    assert_eq!(summary.transaction_id, transaction_id);
    assert_eq!(summary.imported_sessions, 2);
    assert_eq!(summary.imported_rollout_files, 2);
    assert_eq!(summary.conflict_policy, "reject_existing_thread_id");
    assert_eq!(thread_count(&database), 2);
    assert_eq!(fs::read(&first_source).unwrap(), first_bytes);
    assert_eq!(fs::read(&second_source).unwrap(), second_bytes);
    let first_destination = home
        .join("sessions/imported")
        .join(format!("rollout-imported-{first_id}.jsonl"));
    let second_destination = home
        .join("archived_sessions/imported")
        .join(format!("rollout-imported-{second_id}.jsonl"));
    assert_eq!(fs::read(&first_destination).unwrap(), first_bytes);
    assert_eq!(fs::read(&second_destination).unwrap(), second_bytes);
    let connection = Connection::open(&database).unwrap();
    let imported: (String, String, String, i64, i64) = connection
        .query_row(
            "SELECT title, model_provider, model, created_at_ms, updated_at_ms
             FROM threads WHERE id = ?1",
            [first_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(imported.0, "Imported question one");
    assert_eq!(imported.1, "custom");
    assert_eq!(imported.2, "gpt-test");
    assert_eq!(imported.3, 1_786_874_400_125);
    assert_eq!(imported.4, 1_786_874_402_750);
    let archived: (i64, Option<i64>, String) = connection
        .query_row(
            "SELECT archived, archived_at, rollout_path FROM threads WHERE id = ?1",
            [second_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(archived.0, 1);
    assert!(archived.1.is_some());
    assert_eq!(
        archived.2,
        fs::canonicalize(&second_destination)
            .unwrap()
            .to_string_lossy()
    );
    drop(connection);

    let rolled_back = rollback(&summary.journal_path, &JOURNAL_KEY).expect("rollback import");
    assert_eq!(rolled_back.restored_rollout_files, 2);
    assert!(rolled_back.database_restored);
    assert_eq!(thread_count(&database), 0);
    assert!(!first_destination.exists());
    assert!(!second_destination.exists());
    let repeated = rollback(&summary.journal_path, &JOURNAL_KEY).expect("idempotent rollback");
    assert!(repeated.already_rolled_back);
}

#[test]
fn import_failure_after_sqlite_rolls_back_entire_batch() {
    let (temporary, home, journal_root) = fixture();
    let database = home.join("state_5.sqlite");
    create_import_database(&database);
    let source = temporary.path().join("external");
    let first_id = "33333333-3333-4333-8333-333333333333";
    let second_id = "44444444-4444-4444-8444-444444444444";
    let (first_source, first_bytes) =
        write_external_rollout(&source, "first.jsonl", first_id, "First rollback test");
    let (second_source, second_bytes) =
        write_external_rollout(&source, "second.jsonl", second_id, "Second rollback test");
    let transaction_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    let mut options = ImportOptions::new(&journal_root).with_transaction_id(transaction_id);
    options.failure_point = Some(ImportFailurePoint::AfterSqlite);
    let error = import_sessions_with_options(&home, &source, options, &JOURNAL_KEY, |_| {})
        .expect_err("injected import failure");

    assert_eq!(error.code, "injected_failure");
    assert!(error
        .message
        .contains("all imported sessions were rolled back"));
    assert_eq!(thread_count(&database), 0);
    assert_eq!(fs::read(first_source).unwrap(), first_bytes);
    assert_eq!(fs::read(second_source).unwrap(), second_bytes);
    assert!(!home
        .join("sessions/imported")
        .join(format!("rollout-imported-{first_id}.jsonl"))
        .exists());
    assert!(!home
        .join("sessions/imported")
        .join(format!("rollout-imported-{second_id}.jsonl"))
        .exists());
    let recovery = journal_root.join(transaction_id);
    let repeated = rollback(&recovery, &JOURNAL_KEY).expect("read rolled-back import journal");
    assert!(repeated.already_rolled_back);
}

#[test]
fn import_conflict_is_rejected_before_journal_or_rollout_write() {
    let (temporary, home, journal_root) = fixture();
    let database = home.join("state_5.sqlite");
    create_import_database(&database);
    let source = temporary.path().join("external");
    let id = "55555555-5555-4555-8555-555555555555";
    let (_source_file, _bytes) =
        write_external_rollout(&source, "conflict.jsonl", id, "Conflicting import");
    Connection::open(&database)
        .unwrap()
        .execute(
            "INSERT INTO threads
             (id, rollout_path, created_at, updated_at, source, model_provider,
              cwd, title, sandbox_policy, approval_mode)
             VALUES (?1, '/existing.jsonl', 1, 2, 'cli', 'openai', '',
                     'Existing', 'read-only', 'on-request')",
            [id],
        )
        .unwrap();
    let transaction_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    let error = import_sessions_with_options(
        &home,
        &source,
        ImportOptions::new(&journal_root).with_transaction_id(transaction_id),
        &JOURNAL_KEY,
        |_| {},
    )
    .expect_err("existing Thread ID must block import");

    assert_eq!(error.code, "existing_thread_conflict");
    assert_eq!(thread_count(&database), 1);
    assert!(!journal_root.join(transaction_id).exists());
    assert!(!home.join("sessions/imported").exists());
}

#[test]
fn cli_import_requires_explicit_arguments() {
    let binary = env!("CARGO_BIN_EXE_ai-access-session-core");
    let output = Command::new(binary)
        .arg("import")
        .output()
        .expect("run sidecar");
    assert_eq!(output.status.code(), Some(2));
    let lines = String::from_utf8(output.stdout).unwrap();
    let records = lines
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(records.len(), 2);
    assert_eq!(records[0]["event"], "start");
    assert_eq!(records[1]["event"], "result");
    assert_eq!(records[1]["ok"], false);
    assert_eq!(records[1]["code"], "missing_argument");
}

#[test]
fn cli_requires_valid_stdin_only_journal_key() {
    let binary = env!("CARGO_BIN_EXE_ai-access-session-core");
    let missing = Command::new(binary)
        .args([
            "repair",
            "--codex-home",
            "/private/tmp/not-used",
            "--provider",
            "custom",
            "--journal-root",
            "/private/tmp/not-used",
        ])
        .output()
        .expect("run sidecar without key");
    assert_eq!(missing.status.code(), Some(2));
    assert!(missing.stderr.is_empty());
    let missing_last: Value = serde_json::from_str(
        String::from_utf8(missing.stdout)
            .unwrap()
            .lines()
            .last()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(missing_last["code"], "missing_journal_key");

    let mut invalid = Command::new(binary)
        .args([
            "repair",
            "--codex-home",
            "/private/tmp/not-used",
            "--provider",
            "custom",
            "--journal-root",
            "/private/tmp/not-used",
            "--journal-key-stdin",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn sidecar");
    invalid
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"not-base64\n")
        .unwrap();
    drop(invalid.stdin.take());
    let invalid = invalid.wait_with_output().unwrap();
    assert_eq!(invalid.status.code(), Some(2));
    assert!(invalid.stderr.is_empty());
    let invalid_last: Value = serde_json::from_str(
        String::from_utf8(invalid.stdout)
            .unwrap()
            .lines()
            .last()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(invalid_last["code"], "invalid_journal_key");
}

#[test]
#[ignore = "release performance gate: ./Tests/Shell/test-session-core.sh --performance"]
fn performance_201_rollouts_600mb_and_96mb_max() {
    let (_temporary, home, journal) = fixture();
    create_database(&home.join("state_5.sqlite"), 201);
    let total_bytes = 600usize * 1024 * 1024;
    let largest = 96usize * 1024 * 1024;
    let remaining = total_bytes - largest;
    let normal = remaining / 200;
    let remainder = remaining % 200;
    for index in 0..201 {
        let bytes = if index == 0 {
            largest
        } else {
            normal + usize::from(index <= remainder)
        };
        write_large_rollout(&home, index, bytes);
    }
    let actual_total = fs::read_dir(home.join("sessions/2026/07"))
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.metadata().unwrap().len() as usize)
        .sum::<usize>();
    assert_eq!(actual_total, total_bytes);

    let list_started = Instant::now();
    let page = list_sessions_for_provider(&home, 50, 0, Some("openai")).unwrap();
    let list_elapsed = list_started.elapsed();
    assert_eq!(page.sessions.len(), 50);
    assert_eq!(page.total, 201);
    assert_eq!(page.visible_total, Some(201));
    assert!(
        list_elapsed < Duration::from_millis(300),
        "SQLite-only first page took {list_elapsed:?}"
    );

    let repair_started = Instant::now();
    let result = repair(&home, "custom", &journal, &JOURNAL_KEY).unwrap();
    let repair_elapsed = repair_started.elapsed();
    assert_eq!(result.changed_rollout_files, 201);
    assert!(
        repair_elapsed < Duration::from_secs(30),
        "600 MiB repair took {repair_elapsed:?}"
    );
    let peak_bytes = peak_resident_bytes();
    assert!(
        peak_bytes < 250 * 1024 * 1024,
        "600 MiB repair peak RSS was {:.1} MiB",
        peak_bytes as f64 / (1024.0 * 1024.0)
    );
    println!(
        "PERFORMANCE_EVIDENCE list_ms={} repair_ms={} peak_rss_mib={:.1}",
        list_elapsed.as_millis(),
        repair_elapsed.as_millis(),
        peak_bytes as f64 / (1024.0 * 1024.0)
    );
}
