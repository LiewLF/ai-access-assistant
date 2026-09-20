// SPDX-License-Identifier: AGPL-3.0-only

use ai_access_session_core::{
    list_conversation_workspaces, list_conversations_for_provider, list_sessions_for_provider,
    list_workspace_conversations_for_provider, lookup_conversation_workspaces,
    search_conversations_for_provider,
};
use rusqlite::Connection;
use tempfile::TempDir;

fn fixture(with_source: bool) -> TempDir {
    let home = tempfile::tempdir().expect("temporary Codex home");
    let db = Connection::open(home.path().join("state_5.sqlite")).unwrap();
    db.execute_batch(
        "CREATE TABLE threads (
            id TEXT PRIMARY KEY, title TEXT, cwd TEXT, model_provider TEXT,
            updated_at_ms INTEGER
        );",
    )
    .unwrap();
    if with_source {
        db.execute_batch("ALTER TABLE threads ADD COLUMN thread_source TEXT;")
            .unwrap();
    }
    home
}

#[test]
fn guardian_history_filters_metadata_before_pagination_and_counts() {
    let home = fixture(true);
    let db = Connection::open(home.path().join("state_5.sqlite")).unwrap();
    // No spawn table: guardian metadata must suffice. A normal user may use the same title.
    db.execute_batch(
        "INSERT INTO threads VALUES
            ('guardian', 'The following is the Codex agent history', '/shared', 'openai', 90, 'guardian_review'),
            ('guardian-only', 'Internal', '/internal', 'openai', 100, 'guardian_review'),
            ('user', 'The following is the Codex agent history', '/shared', 'openai', 80, 'user'),
            ('unknown', 'Unknown source', '/shared', 'openai', 70, 'future_source'),
            ('null', 'Null source', '/shared', 'openai', 60, NULL),
            ('subagent', 'Child', '/shared', 'openai', 95, 'subagent');",
    )
    .unwrap();
    drop(db);
    let all = list_sessions_for_provider(home.path(), 50, 0, Some("openai")).unwrap();
    assert_eq!(all.total, 6);
    assert_eq!(all.sessions.len(), 6);
    assert_eq!(all.visible_total, Some(6));
    let first = list_conversations_for_provider(home.path(), 1, 0, Some("openai")).unwrap();
    assert_eq!(first.total, 3);
    assert_eq!(first.visible_total, Some(3));
    assert_eq!(first.sessions[0].id, "user");
    assert!(first.has_more);
    let second = list_conversations_for_provider(home.path(), 1, 1, Some("openai")).unwrap();
    assert_eq!(second.sessions[0].id, "unknown");
    let last = list_conversations_for_provider(home.path(), 1, 2, Some("openai")).unwrap();
    assert_eq!(last.sessions[0].id, "null");
    assert!(!last.has_more);
    let search =
        search_conversations_for_provider(home.path(), "The following", 50, 0, Some("openai"))
            .unwrap();
    assert_eq!(search.total, 1);
    assert_eq!(search.visible_total, Some(1));
    assert_eq!(search.sessions[0].id, "user");
    let workspace =
        list_workspace_conversations_for_provider(home.path(), "/shared", 1, 1, Some("openai"))
            .unwrap();
    assert_eq!(workspace.total, 3);
    assert_eq!(workspace.visible_total, Some(3));
    assert_eq!(workspace.sessions[0].id, "unknown");
    let workspaces = list_conversation_workspaces(home.path(), 50, 0).unwrap();
    assert_eq!(workspaces.total, 1);
    assert_eq!(workspaces.workspaces[0].cwd, "/shared");
    assert_eq!(workspaces.workspaces[0].session_count, 3);
    let details = lookup_conversation_workspaces(
        home.path(),
        &["/shared".to_owned(), "/internal".to_owned()],
    )
    .unwrap();
    assert_eq!(details.workspaces.len(), 1);
    assert_eq!(details.workspaces[0].session_count, 3);
}

#[test]
fn guardian_history_preserves_legacy_schema_and_spawn_filter() {
    let home = fixture(false);
    let db = Connection::open(home.path().join("state_5.sqlite")).unwrap();
    db.execute_batch(
        "INSERT INTO threads VALUES
            ('user', 'The following is the Codex agent history', '/shared', 'openai', 80),
            ('child', 'Child', '/shared', 'openai', 90);",
    )
    .unwrap();
    let legacy = list_conversations_for_provider(home.path(), 50, 0, None).unwrap();
    assert_eq!(legacy.total, 2);
    db.execute_batch(
        "CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT);
         INSERT INTO thread_spawn_edges VALUES ('user', 'child');",
    )
    .unwrap();
    let linked = list_conversations_for_provider(home.path(), 50, 0, None).unwrap();
    assert_eq!(linked.total, 1);
    assert_eq!(linked.sessions[0].id, "user");
}
