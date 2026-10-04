#!/usr/bin/env bash
# fm-babysitter-context-lib.sh - deterministic context-size guard for live agents.
# Called from state/babysitter.check.sh on the babysitter watcher cadence.
set -u

FM_BABYSITTER_CONTEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_BABYSITTER_CONTEXT_DEFAULT_THRESHOLD=40
FM_BABYSITTER_CONTEXT_DEFAULT_WINDOW=200000
FM_BABYSITTER_CONTEXT_LONG_WINDOW=1000000
FM_BABYSITTER_CONTEXT_TAIL_BYTES=4194304

fm_bctx_meta_get() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_bctx_shell_quote() {  # <value>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
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
  case "$1" in
    *'[1m]'*) printf '%s\n' "$FM_BABYSITTER_CONTEXT_LONG_WINDOW" ;;
    *) printf '%s\n' "$FM_BABYSITTER_CONTEXT_DEFAULT_WINDOW" ;;
  esac
}

fm_bctx_usage_row() {  # reads transcript JSONL on stdin; prints the last assistant <model><TAB><used-tokens>
  jq -Rr '
    def n($v): if ($v|type)=="number" then $v else 0 end;
    def usage: (.message.usage? // .usage? // empty);
    fromjson?
    | select(((.message.role? // .type? // "") == "assistant") and (usage != null))
    | usage as $u
    | (n($u.input_tokens) + n($u.input) + n($u.cache_creation_input_tokens)
       + n($u.cache_read_input_tokens) + n($u.cacheWrite) + n($u.cacheRead)) as $used
    | select($used > 0)
    | [(.message.model // .model // ""), ($used|tostring)]
    | @tsv
  ' 2>/dev/null | tail -1
}

fm_bctx_usage_from_transcript() {  # <transcript>
  local transcript=$1 row model used window percent
  [ -f "$transcript" ] && [ -r "$transcript" ] && [ ! -L "$transcript" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  row=$(tail -c "$FM_BABYSITTER_CONTEXT_TAIL_BYTES" "$transcript" 2>/dev/null | fm_bctx_usage_row)
  [ -n "$row" ] || row=$(fm_bctx_usage_row < "$transcript")
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r model used <<EOF
$row
EOF
  case "$used" in ''|*[!0-9]*) return 1 ;; esac
  window=$(fm_bctx_model_window "$model")
  percent=$(( (used * 100 + window - 1) / window ))
  printf '%s\t%s\t%s\t%s\ttranscript:%s\n' "$percent" "$used" "$window" "$model" "$transcript"
}

fm_bctx_usage_from_pane() {  # <backend> <target> <label>
  local backend=$1 target=$2 label=$3 text line number percent
  command -v fm_backend_capture >/dev/null 2>&1 || return 1
  text=$(fm_backend_capture "$backend" "$target" 80 "$label" 2>/dev/null) || return 1
  line=$(printf '%s\n' "$text" \
    | grep -Eo '(Ctx:|Context)[[:space:]]*[0-9]+%[[:space:]]*(used|left)' | head -1) || true
  number=$(printf '%s' "$line" | sed -E 's/^[^0-9]*([0-9]+)%.*$/\1/')
  case "$number" in ''|*[!0-9]*) return 1 ;; esac
  case "$line" in
    *used) percent=$number ;;
    *left) percent=$(( 100 - number )) ;;
    *) return 1 ;;
  esac
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

fm_bctx_record_get() {  # <record> <key>
  local record=$1 key=$2
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  grep "^$key=" "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true
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
  local wt=$1 lock=${FM_BABYSITTER_CONTEXT_FULL_GATE_LOCK:-/tmp/fm-full-gate.lock}
  if [ -e "$lock" ]; then
    if command -v lockf >/dev/null 2>&1; then
      lockf -k -t 0 "$lock" true >/dev/null 2>&1 || return 0
    else
      return 0
    fi
  fi
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
  mkdir -p "$STATE/babysitter-context" 2>/dev/null || return 0
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

fm_bctx_latest_transcript_turn() {  # <transcript>; prints <role><TAB><has-open-tool-use>
  local transcript=$1
  command -v jq >/dev/null 2>&1 || return 1
  jq -r '
    select((.isSidechain // false) != true)
    | (.message.role? // .type? // empty) as $role
    | select($role == "assistant" or $role == "user")
    | [$role, ([(.message.content? // [])[]? | select(type == "object" and .type == "tool_use")] | length > 0 | tostring)]
    | @tsv
  ' "$transcript" 2>/dev/null | tail -1
}

fm_bctx_primary_idle_boundary() {  # <transcript>
  local transcript=$1 turn role open_tool busy_state
  turn=$(fm_bctx_latest_transcript_turn "$transcript") || return 1
  IFS=$'\t' read -r role open_tool <<EOF
$turn
EOF
  [ "$role" = assistant ] && [ "$open_tool" = false ] || return 1
  busy_state=$(fm_bctx_record_get "$STATE/.babysitter-primary-busy" state || true)
  [ "$busy_state" = idle ]
}

fm_bctx_primary_placement_record() {
  local record="$STATE/.babysitter-primary-placement"
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  printf '%s\n' "$record"
}

fm_bctx_fresh_launch_command() {  # <launch-command>
  local word skip_value=0
  local -a words=() kept=()
  [ -n "$1" ] || return 1
  read -r -a words <<< "$1"
  for word in "${words[@]}"; do
    if [ "$skip_value" = 1 ]; then
      skip_value=0
      case "$word" in -*) ;; *) continue ;; esac
    fi
    case "$word" in
      --continue|-c|--resume=*) continue ;;
      --resume|-r) skip_value=1; continue ;;
    esac
    kept+=("$word")
  done
  [ "${#kept[@]}" -gt 0 ] || return 1
  printf '%s\n' "${kept[*]}"
}

fm_bctx_primary_restart_command() {  # <placement-record>
  local record=$1 command cwd
  command=$(fm_bctx_record_get "$record" launch_command || true)
  command=$(fm_bctx_fresh_launch_command "$command") || return 1
  cwd=$(fm_bctx_record_get "$record" cwd || true)
  [ -n "$cwd" ] || cwd="$FM_BABYSITTER_CONTEXT_LIB_DIR/.."
  printf 'cd %s && exec %s\n' "$(fm_bctx_shell_quote "$cwd")" "$command"
}

fm_bctx_wait_primary_dead() {  # <backend> <target>
  local backend=$1 target=$2 i state
  i=0
  while [ "$i" -lt 30 ]; do
    state=$(fm_backend_foreground_agent_state "$backend" "$target" 2>/dev/null || printf unreadable)
    case "$state" in dead|missing) return 0 ;; esac
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

fm_bctx_wait_pid_exit() {  # <pid>
  local pid=$1 i=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$i" -lt 30 ] || return 1
    sleep 0.2
    i=$((i + 1))
  done
}

fm_bctx_restart_primary_tmux() {  # <placement-record>
  local record=$1 target launch composer state
  target=$(fm_bctx_record_get "$record" target || true)
  [ -n "$target" ] || return 1
  command -v fm_backend_foreground_agent_state >/dev/null 2>&1 || return 1
  command -v fm_backend_composer_state >/dev/null 2>&1 || return 1
  state=$(fm_backend_foreground_agent_state tmux "$target" 2>/dev/null || printf unreadable)
  [ "$state" = alive ] || return 1
  composer=$(fm_backend_composer_state tmux "$target" "" 2>/dev/null || printf unknown)
  [ "$composer" = empty ] || return 1
  launch=$(fm_bctx_primary_restart_command "$record") || return 1
  fm_backend_send_text_submit tmux "$target" /exit 3 0.1 0.5 "" >/dev/null 2>&1 || return 1
  fm_bctx_wait_primary_dead tmux "$target" || return 1
  fm_backend_source tmux || return 1
  fm_backend_tmux_send_literal "$target" "$launch" || return 1
  fm_backend_tmux_send_key "$target" Enter || return 1
}

fm_bctx_terminal_contents() {  # <tty>
  local osa_bin=${FM_BABYSITTER_CONTEXT_OSASCRIPT_BIN:-osascript}
  [ "$(uname 2>/dev/null)" = Darwin ] || return 1
  command -v "$osa_bin" >/dev/null 2>&1 || return 1
  "$osa_bin" - "$@" 2>/dev/null <<'OSA'
on run argv
  set targetTTY to item 1 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        set tabTTY to tty of t as text
        if tabTTY is targetTTY or tabTTY is "/dev/" & targetTTY or "/dev/" & tabTTY is targetTTY then
          return contents of t as text
        end if
      end repeat
    end repeat
  end tell
  error "terminal tty not found"
end run
OSA
}

fm_bctx_terminal_contents_hash() {  # <tty>
  local contents
  contents=$(fm_bctx_terminal_contents "$1") || return 1
  printf '%s' "$contents" | cksum | awk '{print $1 ":" $2}'
}

fm_bctx_terminal_contents_unchanged() {  # <placement-record> <tty>
  local record=$1 tty=$2 recorded current
  recorded=$(fm_bctx_record_get "$record" terminal_contents_hash || true)
  [ -n "$recorded" ] || return 1
  current=$(fm_bctx_terminal_contents_hash "$tty") || return 1
  [ "$current" = "$recorded" ]
}

fm_bctx_terminal_send() {  # <tty> <command>
  local osa_bin=${FM_BABYSITTER_CONTEXT_OSASCRIPT_BIN:-osascript}
  "$osa_bin" - "$@" >/dev/null 2>&1 <<'OSA'
on run argv
  set targetTTY to item 1 of argv
  set sendCommand to item 2 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        set tabTTY to tty of t as text
        if tabTTY is targetTTY or tabTTY is "/dev/" & targetTTY or "/dev/" & tabTTY is targetTTY then
          do script sendCommand in t
          return "sent"
        end if
      end repeat
    end repeat
  end tell
  error "terminal tty not found"
end run
OSA
}

fm_bctx_restart_primary_terminal() {  # <placement-record>
  local record=$1 tty pid launch
  tty=$(fm_bctx_record_get "$record" tty || true)
  [ -n "$tty" ] || return 1
  pid=$(fm_bctx_record_get "$record" pid || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  launch=$(fm_bctx_primary_restart_command "$record") || return 1
  fm_bctx_terminal_contents_unchanged "$record" "$tty" || return 1
  fm_bctx_terminal_send "$tty" /exit || return 1
  fm_bctx_wait_pid_exit "$pid" || return 1
  fm_bctx_terminal_send "$tty" "$launch"
}

fm_bctx_restart_primary() {  # <placement-record>
  local record=$1 placement
  placement=$(fm_bctx_record_get "$record" placement || true)
  case "$placement" in
    tmux) fm_bctx_restart_primary_tmux "$record" ;;
    terminal) fm_bctx_restart_primary_terminal "$record" ;;
    *) return 1 ;;
  esac
}

fm_bctx_check_primary() {  # <threshold>
  local threshold=$1 transcript usage percent used window model source key marker summary placement_record
  mkdir -p "$STATE/babysitter-context" 2>/dev/null || return 0
  transcript=$(fm_bctx_primary_transcript) || return 0
  usage=$(fm_bctx_usage_from_transcript "$transcript" 2>/dev/null) || return 0
  IFS=$'\t' read -r percent used window model source <<EOF
$usage
EOF
  case "$percent" in ''|*[!0-9]*) return 0 ;; esac
  [ "$percent" -ge "$threshold" ] || return 0
  key="$transcript:$used:$window"
  marker="$STATE/babysitter-context/primary.relaunch"
  fm_bctx_marker_seen "$marker" "$key" && return 0
  if fm_bctx_primary_idle_boundary "$transcript" \
     && placement_record=$(fm_bctx_primary_placement_record) \
     && fm_bctx_restart_primary "$placement_record"; then
    summary="primary firstmate context ${percent}% >= ${threshold}%; restarted into a fresh session at idle boundary"
    fm_bctx_append_finding context-relaunch "$summary"
  else
    marker="$STATE/babysitter-context/primary.alert"
    fm_bctx_marker_seen "$marker" "$key" && return 0
    summary="primary firstmate context ${percent}% >= ${threshold}%; no supported safe primary restart boundary was proven"
    fm_bctx_append_finding context-alert "$summary"
    fm_bctx_wake "babysitter-context:primary" "$summary"
  fi
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
