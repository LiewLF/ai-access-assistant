// SPDX-License-Identifier: AGPL-3.0-only

use ai_access_session_core::{
    clear_stale_prewrite_lock, import_sessions_with_options, inspect, interrupted_journal,
    list_conversation_workspaces, list_conversations_for_provider, list_sessions_for_provider,
    list_workspace_conversations_for_provider, list_workspace_sessions_for_provider,
    list_workspaces, lookup_conversation_workspaces, lookup_workspaces, repair_with_options,
    rollback, search_conversations_for_provider, search_sessions_for_provider, CoreError,
    ImportOptions, RepairOptions, MAX_WORKSPACE_LOOKUP_SIZE, MAX_WORKSPACE_PATH_SIZE,
    PROTOCOL_VERSION,
};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::env;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use zeroize::{Zeroize, Zeroizing};

#[derive(Debug, Serialize)]
struct ProtocolEvent<'a> {
    schema_version: u32,
    event: &'a str,
    command: &'a str,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<Value>,
}

fn main() -> ExitCode {
    let raw = match env::args_os()
        .map(|value| {
            value.into_string().map_err(|_| {
                CoreError::new("invalid_argument", "Command arguments must be valid UTF-8")
            })
        })
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(arguments) => arguments,
        Err(error) => {
            emit_error("unknown", &error);
            return ExitCode::from(2);
        }
    };
    if raw.get(1).is_some_and(|value| value == "--version") {
        emit_result(
            "version",
            json!({
                "name": "ai-access-session-core",
                "version": env!("CARGO_PKG_VERSION"),
                "protocolVersion": PROTOCOL_VERSION
            }),
        );
        return ExitCode::SUCCESS;
    }
    let command = raw.get(1).map(String::as_str).unwrap_or("help");
    if command == "help" || command == "--help" || command == "-h" {
        emit_result(
            "help",
            json!({
                "commands": ["list", "search", "workspaces", "workspace-details", "workspace-sessions", "pending", "clear-prewrite-lock", "inspect", "repair", "rollback", "import"],
                "requiresExplicitCodexHome": true,
                "maxPageSize": 50
            }),
        );
        return ExitCode::SUCCESS;
    }
    let options = match parse_options(&raw[2..]) {
        Ok(options) => options,
        Err(error) => {
            emit_error(command, &error);
            return ExitCode::from(2);
        }
    };
    emit_start(command);
    let result = run(command, &options);
    match result {
        Ok(data) => {
            emit_result(command, data);
            ExitCode::SUCCESS
        }
        Err(error) => {
            emit_error(command, &error);
            if is_usage_error(error.code) {
                ExitCode::from(2)
            } else {
                ExitCode::from(1)
            }
        }
    }
}

fn run(command: &str, options: &BTreeMap<String, String>) -> Result<Value, CoreError> {
    match command {
        "list" => {
            assert_allowed(
                options,
                &[
                    "codex-home",
                    "limit",
                    "offset",
                    "provider",
                    "top-level-only",
                ],
            )?;
            let home = required_path(options, "codex-home")?;
            let limit = optional_usize(options, "limit", 50)?;
            let offset = optional_usize(options, "offset", 0)?;
            let provider = options.get("provider").map(String::as_str);
            let top_level_only = optional_bool(options, "top-level-only", false)?;
            let page = if top_level_only {
                list_conversations_for_provider(&home, limit, offset, provider)?
            } else {
                list_sessions_for_provider(&home, limit, offset, provider)?
            };
            serde_json::to_value(page).map_err(json_error)
        }
        "search" => {
            assert_allowed(
                options,
                &[
                    "codex-home",
                    "query",
                    "limit",
                    "offset",
                    "provider",
                    "top-level-only",
                ],
            )?;
            let home = required_path(options, "codex-home")?;
            let query = required(options, "query")?;
            let limit = optional_usize(options, "limit", 50)?;
            let offset = optional_usize(options, "offset", 0)?;
            let provider = options.get("provider").map(String::as_str);
            let top_level_only = optional_bool(options, "top-level-only", false)?;
            let page = if top_level_only {
                search_conversations_for_provider(&home, query, limit, offset, provider)?
            } else {
                search_sessions_for_provider(&home, query, limit, offset, provider)?
            };
            serde_json::to_value(page).map_err(json_error)
        }
        "workspaces" => {
            assert_allowed(
                options,
                &["codex-home", "limit", "offset", "top-level-only"],
            )?;
            let home = required_path(options, "codex-home")?;
            let limit = optional_usize(options, "limit", 50)?;
            let offset = optional_usize(options, "offset", 0)?;
            let top_level_only = optional_bool(options, "top-level-only", false)?;
            let page = if top_level_only {
                list_conversation_workspaces(&home, limit, offset)?
            } else {
                list_workspaces(&home, limit, offset)?
            };
            serde_json::to_value(page).map_err(json_error)
        }
        "workspace-details" => {
            assert_allowed(options, &["codex-home", "cwds-json", "top-level-only"])?;
            let home = required_path(options, "codex-home")?;
            let workspaces = required_workspace_paths(options, "cwds-json")?;
            let top_level_only = optional_bool(options, "top-level-only", false)?;
            let page = if top_level_only {
                lookup_conversation_workspaces(&home, &workspaces)?
            } else {
                lookup_workspaces(&home, &workspaces)?
            };
            serde_json::to_value(page).map_err(json_error)
        }
        "workspace-sessions" => {
            assert_allowed(
                options,
                &[
                    "codex-home",
                    "cwd",
                    "limit",
                    "offset",
                    "provider",
                    "top-level-only",
                ],
            )?;
            let home = required_path(options, "codex-home")?;
            let cwd = required(options, "cwd")?;
            let limit = optional_usize(options, "limit", 50)?;
            let offset = optional_usize(options, "offset", 0)?;
            let provider = options.get("provider").map(String::as_str);
            let top_level_only = optional_bool(options, "top-level-only", false)?;
            let page = if top_level_only {
                list_workspace_conversations_for_provider(&home, cwd, limit, offset, provider)?
            } else {
                list_workspace_sessions_for_provider(&home, cwd, limit, offset, provider)?
            };
            serde_json::to_value(page).map_err(json_error)
        }
        "pending" => {
            assert_allowed(options, &["codex-home", "recovery-root"])?;
            let home = required_path(options, "codex-home")?;
            let recovery_root = required_path(options, "recovery-root")?;
            Ok(json!({
                "journal": interrupted_journal(&home, &recovery_root)?
            }))
        }
        "clear-prewrite-lock" => {
            assert_allowed(options, &["codex-home", "recovery-root", "transaction-id"])?;
            let home = required_path(options, "codex-home")?;
            let recovery_root = required_path(options, "recovery-root")?;
            let transaction_id = required(options, "transaction-id")?;
            serde_json::to_value(clear_stale_prewrite_lock(
                &home,
                &recovery_root,
                transaction_id,
            )?)
            .map_err(json_error)
        }
        "inspect" => {
            assert_allowed(options, &["codex-home", "provider"])?;
            let home = required_path(options, "codex-home")?;
            let provider = required(options, "provider")?;
            serde_json::to_value(inspect(&home, provider)?).map_err(json_error)
        }
        "repair" => {
            assert_allowed(
                options,
                &[
                    "codex-home",
                    "provider",
                    "journal-root",
                    "transaction-id",
                    "journal-key-stdin",
                ],
            )?;
            let home = required_path(options, "codex-home")?;
            let provider = required(options, "provider")?;
            let journal_root = required_path(options, "journal-root")?;
            let key = read_journal_key(options)?;
            let mut repair_options = RepairOptions::new(journal_root);
            if let Some(transaction_id) = options.get("transaction-id") {
                repair_options = repair_options.with_transaction_id(transaction_id);
            }
            let summary = repair_with_options(&home, provider, repair_options, &key, |progress| {
                if let Ok(data) = serde_json::to_value(progress) {
                    emit_progress("repair", data);
                }
            })?;
            serde_json::to_value(summary).map_err(json_error)
        }
        "rollback" => {
            assert_allowed(options, &["journal", "journal-key-stdin"])?;
            let journal = required_path(options, "journal")?;
            let key = read_journal_key(options)?;
            serde_json::to_value(rollback(&journal, &key)?).map_err(json_error)
        }
        "import" => {
            assert_allowed(
                options,
                &[
                    "codex-home",
                    "source-root",
                    "journal-root",
                    "transaction-id",
                    "journal-key-stdin",
                ],
            )?;
            let home = required_path(options, "codex-home")?;
            let source_root = required_path(options, "source-root")?;
            let journal_root = required_path(options, "journal-root")?;
            let key = read_journal_key(options)?;
            let mut import_options = ImportOptions::new(journal_root);
            if let Some(transaction_id) = options.get("transaction-id") {
                import_options = import_options.with_transaction_id(transaction_id);
            }
            let summary = import_sessions_with_options(
                &home,
                &source_root,
                import_options,
                &key,
                |progress| {
                    if let Ok(data) = serde_json::to_value(progress) {
                        emit_progress("import", data);
                    }
                },
            )?;
            serde_json::to_value(summary).map_err(json_error)
        }
        _ => Err(CoreError::new(
            "unknown_command",
            format!("Unknown command: {command}"),
        )),
    }
}

fn parse_options(values: &[String]) -> Result<BTreeMap<String, String>, CoreError> {
    let mut options = BTreeMap::new();
    let mut index = 0usize;
    while index < values.len() {
        let flag = values
            .get(index)
            .ok_or_else(|| CoreError::new("invalid_argument", "Missing command option"))?;
        let key = flag.strip_prefix("--").ok_or_else(|| {
            CoreError::new(
                "invalid_argument",
                format!("Expected --option, found {flag:?}"),
            )
        })?;
        if key.is_empty() {
            return Err(CoreError::new("invalid_argument", "Empty option name"));
        }
        if key == "journal-key-stdin" {
            if options
                .insert(key.to_string(), "true".to_string())
                .is_some()
            {
                return Err(CoreError::new(
                    "duplicate_argument",
                    "Duplicate option: --journal-key-stdin",
                ));
            }
            index += 1;
            continue;
        }
        let value = values.get(index + 1).ok_or_else(|| {
            CoreError::new("invalid_argument", format!("Missing value for --{key}"))
        })?;
        if options.insert(key.to_string(), value.to_string()).is_some() {
            return Err(CoreError::new(
                "duplicate_argument",
                format!("Duplicate option: --{key}"),
            ));
        }
        index += 2;
    }
    Ok(options)
}

fn read_journal_key(options: &BTreeMap<String, String>) -> Result<Zeroizing<[u8; 32]>, CoreError> {
    if options.get("journal-key-stdin").map(String::as_str) != Some("true") {
        return Err(CoreError::new(
            "missing_journal_key",
            "session writes and rollback require --journal-key-stdin",
        ));
    }
    let mut input = String::new();
    io::stdin()
        .take(1025)
        .read_to_string(&mut input)
        .map_err(|_| {
            CoreError::new(
                "invalid_journal_key",
                "Cannot read journal encryption key from stdin",
            )
        })?;
    if input.len() > 1024 {
        input.zeroize();
        return Err(CoreError::new(
            "invalid_journal_key",
            "Journal key input is too large",
        ));
    }
    let encoded = Zeroizing::new(input.trim_end_matches(['\r', '\n']).to_string());
    input.zeroize();
    if encoded.is_empty() || encoded.trim() != encoded.as_str() {
        return Err(CoreError::new(
            "invalid_journal_key",
            "Journal key must be unadorned RFC4648 Base64",
        ));
    }
    let mut decoded = STANDARD.decode(encoded.as_bytes()).map_err(|_| {
        CoreError::new(
            "invalid_journal_key",
            "Journal key is not valid RFC4648 Base64",
        )
    })?;
    if decoded.len() != 32 {
        decoded.zeroize();
        return Err(CoreError::new(
            "invalid_journal_key",
            "Journal key must decode to exactly 32 bytes",
        ));
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&decoded);
    decoded.zeroize();
    Ok(Zeroizing::new(key))
}

fn is_usage_error(code: &str) -> bool {
    matches!(
        code,
        "invalid_argument"
            | "missing_argument"
            | "duplicate_argument"
            | "unknown_argument"
            | "unknown_command"
            | "missing_journal_key"
            | "invalid_journal_key"
            | "invalid_workspace_path"
            | "invalid_workspace_paths"
    )
}

fn assert_allowed(options: &BTreeMap<String, String>, allowed: &[&str]) -> Result<(), CoreError> {
    if let Some(unexpected) = options.keys().find(|key| !allowed.contains(&key.as_str())) {
        return Err(CoreError::new(
            "unknown_argument",
            format!("Unknown option: --{unexpected}"),
        ));
    }
    Ok(())
}

fn required<'a>(options: &'a BTreeMap<String, String>, key: &str) -> Result<&'a str, CoreError> {
    options
        .get(key)
        .map(String::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            CoreError::new(
                "missing_argument",
                format!("Missing required option: --{key}"),
            )
        })
}

fn required_path(options: &BTreeMap<String, String>, key: &str) -> Result<PathBuf, CoreError> {
    Ok(PathBuf::from(required(options, key)?))
}

fn required_workspace_paths(
    options: &BTreeMap<String, String>,
    key: &str,
) -> Result<Vec<String>, CoreError> {
    let raw = required(options, key)?;
    let maximum_bytes = MAX_WORKSPACE_LOOKUP_SIZE
        .saturating_mul(MAX_WORKSPACE_PATH_SIZE.saturating_mul(4).saturating_add(8));
    if raw.len() > maximum_bytes {
        return Err(CoreError::new(
            "invalid_workspace_paths",
            "Workspace lookup payload is too large",
        ));
    }
    serde_json::from_str::<Vec<String>>(raw).map_err(|_| {
        CoreError::new(
            "invalid_workspace_paths",
            "--cwds-json must be a JSON array of workspace paths",
        )
    })
}

fn optional_usize(
    options: &BTreeMap<String, String>,
    key: &str,
    fallback: usize,
) -> Result<usize, CoreError> {
    options.get(key).map_or(Ok(fallback), |value| {
        value.parse::<usize>().map_err(|_| {
            CoreError::new(
                "invalid_argument",
                format!("--{key} must be a non-negative integer"),
            )
        })
    })
}

fn optional_bool(
    options: &BTreeMap<String, String>,
    key: &str,
    fallback: bool,
) -> Result<bool, CoreError> {
    options
        .get(key)
        .map_or(Ok(fallback), |value| match value.as_str() {
            "true" => Ok(true),
            "false" => Ok(false),
            _ => Err(CoreError::new(
                "invalid_argument",
                format!("--{key} must be true or false"),
            )),
        })
}

fn json_error(error: serde_json::Error) -> CoreError {
    CoreError::new("json_encode_failed", error.to_string())
}

fn emit_start(command: &str) {
    emit(ProtocolEvent {
        schema_version: PROTOCOL_VERSION,
        event: "start",
        command,
        ok: true,
        code: None,
        message: None,
        data: None,
    });
}

fn emit_progress(command: &str, data: Value) {
    emit(ProtocolEvent {
        schema_version: PROTOCOL_VERSION,
        event: "progress",
        command,
        ok: true,
        code: None,
        message: None,
        data: Some(data),
    });
}

fn emit_result(command: &str, data: Value) {
    emit(ProtocolEvent {
        schema_version: PROTOCOL_VERSION,
        event: "result",
        command,
        ok: true,
        code: None,
        message: None,
        data: Some(data),
    });
}

fn emit_error(command: &str, error: &CoreError) {
    emit(ProtocolEvent {
        schema_version: PROTOCOL_VERSION,
        event: "result",
        command,
        ok: false,
        code: Some(error.code),
        message: Some(&error.message),
        data: None,
    });
}

fn emit(event: ProtocolEvent<'_>) {
    let stdout = io::stdout();
    let mut output = stdout.lock();
    if serde_json::to_writer(&mut output, &event).is_ok() {
        let _ = output.write_all(b"\n");
        let _ = output.flush();
    }
}
