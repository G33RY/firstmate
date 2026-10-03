#!/usr/bin/env bash
# fm-babysitter-context-lib.sh - deterministic context-size guard for live agents.
# Called from state/babysitter.check.sh on the babysitter watcher cadence.
set -u

FM_BABYSITTER_CONTEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_BABYSITTER_CONTEXT_DEFAULT_THRESHOLD=40
FM_BABYSITTER_CONTEXT_DEFAULT_WINDOW=200000

fm_bctx_meta_get() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_bctx_threshold_percent() {
  local cfg="$CONFIG/babysitter-context-threshold-percent" value
  value=$(cat "$cfg" 2>/dev/null || true)
  value=${value%%$'\n'*}
  case "$value" in
    ''|*[!0-9]*|0) value=$FM_BABYSITTER_CONTEXT_DEFAULT_THRESHOLD ;;
  esac
  [ "$value" -le 100 ] || value=100
  printf '%s\n' "$value"
}

fm_bctx_model_window() {  # <model>
  local model=$1
  case "$model" in
    *[Cc]laude*) printf '%s\n' "$FM_BABYSITTER_CONTEXT_DEFAULT_WINDOW" ;;
    *) printf '%s\n' "$FM_BABYSITTER_CONTEXT_DEFAULT_WINDOW" ;;
  esac
}

fm_bctx_usage_from_transcript() {  # <transcript>
  local transcript=$1 row model used window percent
  [ -f "$transcript" ] && [ -r "$transcript" ] && [ ! -L "$transcript" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  row=$(jq -r '
    def n($v): if ($v|type)=="number" then $v else 0 end;
    def usage: (.message.usage? // .usage? // empty);
    select(((.message.role? // .type? // "") == "assistant") and (usage != null))
    | usage as $u
    | (n($u.input_tokens) + n($u.input) + n($u.cache_creation_input_tokens)
       + n($u.cache_read_input_tokens) + n($u.cacheWrite) + n($u.cacheRead)) as $used
    | select($used > 0)
    | [(.message.model // .model // ""), ($used|tostring),
       ((.message.context_window // .context_window // $u.context_window // $u.contextWindow // "")|tostring)]
    | @tsv
  ' "$transcript" 2>/dev/null | tail -1) || return 1
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r model used window <<EOF
$row
EOF
  case "$used" in ''|*[!0-9]*) return 1 ;; esac
  case "$window" in ''|*[!0-9]*) window=$(fm_bctx_model_window "$model") ;; esac
  case "$window" in ''|*[!0-9]*|0) return 1 ;; esac
  percent=$(( (used * 100 + window - 1) / window ))
  printf '%s\t%s\t%s\t%s\ttranscript:%s\n' "$percent" "$used" "$window" "$model" "$transcript"
}

fm_bctx_usage_from_pane() {  # <backend> <target> <label>
  local backend=$1 target=$2 label=$3 text percent
  command -v fm_backend_capture >/dev/null 2>&1 || return 1
  text=$(fm_backend_capture "$backend" "$target" 80 "$label" 2>/dev/null) || return 1
  percent=$(printf '%s\n' "$text" | awk '
    match($0, /Ctx:[[:space:]]*([0-9]+)%[[:space:]]*used/, a) { print a[1]; found=1 }
    match($0, /Context[[:space:]]*([0-9]+)%[[:space:]]*used/, a) { print a[1]; found=1 }
    match($0, /Context[[:space:]]*([0-9]+)%[[:space:]]*left/, a) { print 100 - a[1]; found=1 }
    found { exit }
  ')
  case "$percent" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\t0\t100\tunknown\tpane\n' "$percent"
}

fm_bctx_task_transcript() {  # <meta>
  local meta=$1 path
  path=$(fm_bctx_meta_get "$meta" transcript)
  [ -n "$path" ] || path=$(fm_bctx_meta_get "$meta" claude_transcript)
  [ -n "$path" ] || return 1
  [ -f "$path" ] && [ -r "$path" ] && [ ! -L "$path" ] || return 1
  printf '%s\n' "$path"
}

fm_bctx_task_usage() {  # <id> <meta>
  local id=$1 meta=$2 backend target transcript
  if transcript=$(fm_bctx_task_transcript "$meta"); then
    fm_bctx_usage_from_transcript "$transcript" && return 0
  fi
  command -v fm_backend_of_meta >/dev/null 2>&1 || return 1
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  fm_bctx_usage_from_pane "$backend" "$target" "fm-$id"
}

fm_bctx_append_finding() {  # <kind> <summary>
  FM_STATE_OVERRIDE="$STATE" "$FM_BABYSITTER_CONTEXT_LIB_DIR/fm-babysitter-findings.sh" \
    append --kind "$1" --summary "$2" --tier 1 >/dev/null 2>&1 || true
}

fm_bctx_wake() {  # <key> <message>
  command -v fm_wake_append >/dev/null 2>&1 || return 0
  fm_wake_append check "$1" "check: $2" >/dev/null 2>&1 || true
}

fm_bctx_status_line() {  # <id>
  local log="$STATE/$1.status"
  [ -f "$log" ] || { printf 'none'; return; }
  grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -1 | tr '\n' ' ' || printf 'unreadable'
}

fm_bctx_pr_from_status() {  # <id>
  local log="$STATE/$1.status"
  [ -f "$log" ] || return 1
  grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$log" 2>/dev/null | tail -1
}

fm_bctx_progress_note() {  # <id> <meta> <percent> <threshold>
  local id=$1 meta=$2 percent=$3 threshold=$4 wt branch head pr status
  wt=$(fm_bctx_meta_get "$meta" worktree)
  status=$(fm_bctx_status_line "$id")
  branch=unknown
  head=unknown
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')
    head=$(git -C "$wt" rev-parse --short HEAD 2>/dev/null || printf 'unknown')
  fi
  pr=$(fm_bctx_pr_from_status "$id" || true)
  [ -n "$pr" ] || pr=none
  printf 'Context threshold reached (%s%% >= %s%%). Durable state before relaunch: latest_status=%s; branch=%s; head=%s; pr=%s.' \
    "$percent" "$threshold" "$status" "$branch" "$head" "$pr"
}

fm_bctx_full_gate_lock_present() {  # <worktree>
  local wt=$1
  [ -n "$wt" ] && [ -d "$wt/.no-mistakes" ] || return 1
  find "$wt/.no-mistakes" -maxdepth 4 \( -name '*full*gate*.lock' -o -name '*gate*.lock' \) -print -quit 2>/dev/null | grep -q .
}

fm_bctx_crew_state() {  # <id>
  local crew_state_bin=${FM_BABYSITTER_CONTEXT_CREW_STATE_BIN:-"$FM_BABYSITTER_CONTEXT_LIB_DIR/fm-crew-state.sh"}
  FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" FM_HOME="${FM_HOME:-}" FM_STATE_OVERRIDE="$STATE" \
    "$crew_state_bin" "$1" 2>/dev/null | head -1
}

fm_bctx_state_word() {  # <crew-state-line>
  local rest=${1#state: }
  printf '%s' "${rest%% ·*}"
}

fm_bctx_relaunch_marker_key() {  # <meta> <usage-source>
  local meta=$1 source=$2 gen
  gen=$(fm_bctx_meta_get "$meta" spawn_gen)
  [ -n "$gen" ] || gen=$source
  printf '%s\n' "$gen"
}

fm_bctx_marker_seen() {  # <marker> <key>
  [ -f "$1" ] && [ "$(cat "$1" 2>/dev/null || true)" = "$2" ]
}

fm_bctx_check_worker() {  # <id> <threshold>
  local id=$1 threshold=$2 meta="$STATE/$1.meta"
  local backend target agent_state usage percent used window model source key marker current state wt note control_bin
  [ -f "$meta" ] || return 0
  [ "$(fm_bctx_meta_get "$meta" kind)" != babysitter ] || return 0
  command -v fm_backend_of_meta >/dev/null 2>&1 || return 0
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 0
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
  [ "$agent_state" = alive ] || return 0
  usage=$(fm_bctx_task_usage "$id" "$meta" 2>/dev/null) || return 0
  IFS=$'\t' read -r percent used window model source <<EOF
$usage
EOF
  case "$percent" in ''|*[!0-9]*) return 0 ;; esac
  [ "$percent" -ge "$threshold" ] || return 0
  key=$(fm_bctx_relaunch_marker_key "$meta" "$source")
  marker="$STATE/babysitter-context/$id.relaunch"
  fm_bctx_marker_seen "$marker" "$key" && return 0
  current=$(fm_bctx_crew_state "$id")
  state=$(fm_bctx_state_word "$current")
  case "$state" in
    parked|blocked|paused) ;;
    *)
      marker="$STATE/babysitter-context/$id.deferred"
      fm_bctx_marker_seen "$marker" "$key" && return 0
      printf '%s\n' "$key" > "$marker" 2>/dev/null || true
      fm_bctx_append_finding context-deferred "worker $id context ${percent}% >= ${threshold}% but current state is ${state:-unknown}; relaunch deferred"
      return 0
      ;;
  esac
  wt=$(fm_bctx_meta_get "$meta" worktree)
  if fm_bctx_full_gate_lock_present "$wt"; then
    marker="$STATE/babysitter-context/$id.full-gate"
    fm_bctx_marker_seen "$marker" "$key" && return 0
    printf '%s\n' "$key" > "$marker" 2>/dev/null || true
    fm_bctx_append_finding context-deferred "worker $id context ${percent}% >= ${threshold}% but a full-gate lock is present; relaunch deferred"
    return 0
  fi
  note=$(fm_bctx_progress_note "$id" "$meta" "$percent" "$threshold")
  fm_bctx_append_finding context-relaunch "worker $id context ${percent}% >= ${threshold}%; relaunching at idle boundary"
  control_bin=${FM_BABYSITTER_CONTEXT_CONTROL_BIN:-"$FM_BABYSITTER_CONTEXT_LIB_DIR/fm-control.sh"}
  if FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-}}" FM_STATE_OVERRIDE="$STATE" "$control_bin" "$id" relaunch --note "$note" >/dev/null 2>&1; then
    printf '%s\n' "$key" > "$marker" 2>/dev/null || true
  else
    fm_bctx_append_finding context-alert "worker $id context ${percent}% >= ${threshold}% but relaunch failed"
    fm_bctx_wake "babysitter-context:$id" "babysitter could not relaunch worker $id after context reached ${percent}%"
  fi
}

fm_bctx_primary_transcript() {
  local record="$STATE/.babysitter-primary-transcript" path
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  path=$(awk -F '\t' 'NF >= 2 {print $2}' "$record" 2>/dev/null | tail -1)
  [ -n "$path" ] && [ -f "$path" ] && [ -r "$path" ] && [ ! -L "$path" ] || return 1
  printf '%s\n' "$path"
}

fm_bctx_check_primary() {  # <threshold>
  local threshold=$1 transcript usage percent used window model source key marker summary
  transcript=$(fm_bctx_primary_transcript) || return 0
  usage=$(fm_bctx_usage_from_transcript "$transcript" 2>/dev/null) || return 0
  IFS=$'\t' read -r percent used window model source <<EOF
$usage
EOF
  case "$percent" in ''|*[!0-9]*) return 0 ;; esac
  [ "$percent" -ge "$threshold" ] || return 0
  key="$transcript:$used:$window"
  marker="$STATE/babysitter-context/primary.alert"
  fm_bctx_marker_seen "$marker" "$key" && return 0
  summary="primary firstmate context ${percent}% >= ${threshold}%; no supported automatic primary restart placement is configured"
  fm_bctx_append_finding context-alert "$summary"
  fm_bctx_wake "babysitter-context:primary" "$summary"
  printf '%s\n' "$key" > "$marker" 2>/dev/null || true
}

fm_babysitter_context_check() {
  local enabled_flag="$CONFIG/babysitter-enabled" threshold meta id
  [ -e "$enabled_flag" ] || return 0
  mkdir -p "$STATE/babysitter-context" 2>/dev/null || return 0
  threshold=$(fm_bctx_threshold_percent)
  command -v fm_wake_append >/dev/null 2>&1 || . "$FM_BABYSITTER_CONTEXT_LIB_DIR/fm-wake-lib.sh"
  command -v fm_backend_of_meta >/dev/null 2>&1 || . "$FM_BABYSITTER_CONTEXT_LIB_DIR/fm-backend.sh"
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$id" = babysitter ] && continue
    fm_bctx_check_worker "$id" "$threshold"
  done
  fm_bctx_check_primary "$threshold"
}
