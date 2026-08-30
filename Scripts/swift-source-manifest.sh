#!/bin/zsh

# Shared loader for every direct swiftc runner. Source paths live only in
# swift-source-manifest.tsv; runner scripts select their existing input set by
# tag and keep their own compiler flags, frameworks, architecture and output.

typeset -ga AI_ACCESS_SWIFT_SOURCES

ai_access_load_swift_sources() {
  emulate -L zsh
  setopt ERR_RETURN NO_UNSET PIPE_FAIL

  local project_root="$1"
  local runner_id="$2"
  local manifest="$project_root/Scripts/swift-source-manifest.tsv"
  local relative_path runner_tags

  AI_ACCESS_SWIFT_SOURCES=()
  while IFS=$'\t' read -r relative_path runner_tags; do
    [[ -z "$relative_path" || "$relative_path" == \#* ]] && continue
    if [[ ",$runner_tags," == *",$runner_id,"* ]]; then
      if [[ ! -f "$project_root/$relative_path" ]]; then
        echo "Swift source manifest entry is missing: $relative_path" >&2
        return 1
      fi
      AI_ACCESS_SWIFT_SOURCES+=("$project_root/$relative_path")
    fi
  done < "$manifest"

  if (( ${#AI_ACCESS_SWIFT_SOURCES[@]} == 0 )); then
    echo "Swift source manifest has no inputs for runner: $runner_id" >&2
    return 1
  fi
}
