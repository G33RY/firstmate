#!/usr/bin/env bash
# fm-decision-ledger-page.sh - publish or refresh one project's decision-ledger
# page, updating the same page in place instead of creating a new one.
#
# Owned contract: `decision-ledger` skill (.agents/skills/decision-ledger).
# That skill is the ledger's single owner (entry format, when to append, when
# to publish); this script owns only the mechanics of getting one rendered
# HTML artifact onto a stable, revisitable URL.
#
# Why a raw API call instead of `lavish-axi share`: that CLI command only
# creates a new ht-ml.app page (POST /v1/sites) and has no update subcommand
# today, so calling it again would recreate the page under a new URL every
# time - exactly the orphaned-link pile the ledger exists to avoid. The
# ht-ml.app API itself does support an in-place update
# (PUT /v1/sites/<site_id>, Authorization: Bearer <update_key>), verified live
# and recorded in docs/verification/decision-ledger-page.md. This script uses
# that endpoint directly and keeps the identity it returns (site_id,
# update_key, url) in the project's sidecar record so a later call updates the
# same page.
#
# Usage:
#   fm-decision-ledger-page.sh publish <project> <html-file>
#   fm-decision-ledger-page.sh info <project>
#
# publish   Create the project's page on first use, or update the existing one
#           in place on every later call. <html-file> must be one
#           self-contained HTML document (inline or CDN-only assets; no
#           sibling local files - nothing here inlines them). On first
#           publish, generates a random page password so the ledger is never
#           fully public, and records the site's identity and that password in
#           the sidecar. Prints `url: <url>` then `password: <password>`.
# info      Print the stored `url:`/`password:` for a project that already has
#           a page, or fail if it has none yet.
#
# Sidecar: $FM_HOME/data/decisions/<project>/page.json (mode 600; holds
# site_id, update_key, url, password). Absent until the first successful
# publish for that project. Never edit it by hand.
#
# A stored update_key that ht-ml.app now rejects (401/404: revoked, deleted,
# or the API changed) is reported as a failure rather than silently
# re-published under a new URL, so an intentionally broken link is never
# quietly replaced without a human noticing the record needed manual repair.
#
# Test seam: FM_DECISION_LEDGER_HTTP_EXEC replaces the HTTP call entirely.
# When set, it is invoked as `"$EXEC" <method> <url> <bearer-or-empty>
# <body-file>` and must print the response body to stdout followed by a
# trailing `HTTP_STATUS:<code>` line, matching this script's own curl usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
API="${LAVISH_AXI_HTML_APP_API_URL:-https://api.ht-ml.app}"
API="${API%/}"
TIMEOUT="${FM_DECISION_LEDGER_TIMEOUT_SECS:-30}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
  exit 2
}

fail() {
  printf 'fm-decision-ledger-page: %s\n' "$*" >&2
  exit 1
}

require_project() {
  case "${1:-}" in
    '') fail "missing <project>" ;;
    */*) fail "project must be a bare name, not a path: $1" ;;
  esac
}

record_path() { printf '%s/decisions/%s/page.json\n' "$DATA" "$1"; }

# <method> <url> <bearer-or-empty> <body-file> -> body on stdout, sets HTTP_STATUS
http_call() {
  local method=$1 url=$2 bearer=$3 body_file=$4 out status
  if [ -n "${FM_DECISION_LEDGER_HTTP_EXEC:-}" ]; then
    out=$("$FM_DECISION_LEDGER_HTTP_EXEC" "$method" "$url" "$bearer" "$body_file") || fail "test exec failed"
  else
    command -v curl >/dev/null 2>&1 || fail "curl is required to publish a decision-ledger page"
    if [ -n "$bearer" ]; then
      out=$(curl -sS -m "$TIMEOUT" -X "$method" "$url" \
        -H 'content-type: application/json' -H "authorization: Bearer $bearer" \
        --data-binary "@$body_file" -w '\nHTTP_STATUS:%{http_code}') \
        || fail "request to ht-ml.app failed"
    else
      out=$(curl -sS -m "$TIMEOUT" -X "$method" "$url" \
        -H 'content-type: application/json' --data-binary "@$body_file" \
        -w '\nHTTP_STATUS:%{http_code}') \
        || fail "request to ht-ml.app failed"
    fi
  fi
  status=$(printf '%s' "$out" | tail -n1 | sed -n 's/^HTTP_STATUS:\([0-9]*\)$/\1/p')
  case "$status" in [0-9][0-9][0-9]) ;; *) fail "unexpected response from ht-ml.app: $out" ;; esac
  HTTP_STATUS=$status
  HTTP_BODY=$(printf '%s' "$out" | sed '$d')
}

random_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
  fi
}

write_record() {  # <path> <json>
  local path=$1 json=$2 tmp
  mkdir -p "$(dirname "$path")"
  tmp=$(umask 077; mktemp "$(dirname "$path")/.page.XXXXXX") || fail "cannot stage $path"
  printf '%s\n' "$json" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$path"
}

cmd_publish() {
  local project=$1 html_file=$2 record
  require_project "$project"
  [ -f "$html_file" ] || fail "no such file: $html_file"
  record=$(record_path "$project")
  body_file=$(mktemp) || fail "cannot stage request body"
  trap 'rm -f "$body_file"' EXIT

  if [ -f "$record" ]; then
    local site_id update_key password url
    site_id=$(jq -er '.site_id' "$record") || fail "corrupt record: $record"
    update_key=$(jq -er '.update_key' "$record") || fail "corrupt record: $record"
    password=$(jq -er '.password' "$record") || fail "corrupt record: $record"
    jq -n --rawfile html "$html_file" '{html_content: $html}' > "$body_file"
    http_call PUT "$API/v1/sites/$site_id" "$update_key" "$body_file"
    case "$HTTP_STATUS" in
      2??) ;;
      401|404)
        fail "stored page for '$project' ($API/v1/sites/$site_id) no longer accepts updates (HTTP $HTTP_STATUS); investigate before deleting $record to publish a fresh page"
        ;;
      *) fail "ht-ml.app update failed (HTTP $HTTP_STATUS): $HTTP_BODY" ;;
    esac
    url=$(printf '%s' "$HTTP_BODY" | jq -er '.url') || fail "ht-ml.app response missing url: $HTTP_BODY"
    write_record "$record" "$(jq -n --arg site_id "$site_id" --arg update_key "$update_key" \
      --arg url "$url" --arg password "$password" \
      '{site_id: $site_id, update_key: $update_key, url: $url, password: $password}')"
    printf 'url: %s\n' "$url"
    printf 'password: %s\n' "$password"
    return 0
  fi

  local password site_id update_key url
  password=$(random_password)
  jq -n --rawfile html "$html_file" --arg password "$password" '{html_content: $html, password: $password}' > "$body_file"
  http_call POST "$API/v1/sites" "" "$body_file"
  case "$HTTP_STATUS" in
    2??) ;;
    *) fail "ht-ml.app publish failed (HTTP $HTTP_STATUS): $HTTP_BODY" ;;
  esac
  site_id=$(printf '%s' "$HTTP_BODY" | jq -er '.site_id') || fail "ht-ml.app response missing site_id: $HTTP_BODY"
  update_key=$(printf '%s' "$HTTP_BODY" | jq -er '.update_key') || fail "ht-ml.app response missing update_key: $HTTP_BODY"
  url=$(printf '%s' "$HTTP_BODY" | jq -er '.url') || fail "ht-ml.app response missing url: $HTTP_BODY"
  write_record "$record" "$(jq -n --arg site_id "$site_id" --arg update_key "$update_key" \
    --arg url "$url" --arg password "$password" \
    '{site_id: $site_id, update_key: $update_key, url: $url, password: $password}')"
  printf 'url: %s\n' "$url"
  printf 'password: %s\n' "$password"
}

cmd_info() {
  local project=$1 record
  require_project "$project"
  record=$(record_path "$project")
  [ -f "$record" ] || fail "no published page recorded for '$project' yet"
  printf 'url: %s\n' "$(jq -er '.url' "$record")"
  printf 'password: %s\n' "$(jq -er '.password' "$record")"
}

command -v jq >/dev/null 2>&1 || fail "jq is required"

case "${1:-}" in
  publish) shift; [ $# -eq 2 ] || usage; cmd_publish "$1" "$2" ;;
  info) shift; [ $# -eq 1 ] || usage; cmd_info "$1" ;;
  *) usage ;;
esac
