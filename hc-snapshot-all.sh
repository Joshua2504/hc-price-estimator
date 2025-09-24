#!/usr/bin/env bash
set -euo pipefail

# Hetzner Cloud: Snapshot all servers
# - Creates a snapshot for every server in the project
# - Uses live API via HCLOUD_TOKEN
#
# Usage:
#   HCLOUD_TOKEN=xxx ./hc-snapshot-all.sh [--wait] [--force] [--prefix PREFIX] [--dry-run]
#
# Options:
#   --wait        Wait for each snapshot action to complete
#   --force       Force snapshot even if server state is not ideal
#   --prefix PFX  Description prefix (default: "snapshot-YYYY-MM-DD-")
#   --dry-run     Print what would be done without calling the API

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HC_PRICE_ENV_FILE:-}"
if [[ -z "$ENV_FILE" ]]; then
  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_FILE="$SCRIPT_DIR/.env"
  elif [[ -f ./.env ]]; then
    ENV_FILE="./.env"
  fi
fi

if [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

API="https://api.hetzner.cloud/v1"
AUTH_HEADER="Authorization: Bearer ${HCLOUD_TOKEN:-}"
if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
  echo "Error: Please export HCLOUD_TOKEN first (or place it in .env)." >&2
  exit 1
fi

PRICE_KIND="net" # unused here, kept for parity

api_get() {
  # $1: path
  curl -fsSL -H "$AUTH_HEADER" -H "Content-Type: application/json" "$API/$1"
}

api_post_status() {
  # $1: path, $2: json body
  # Prints: response body, then a newline, then HTTP status code
  curl -sS -X POST \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    -d "$2" "$API/$1" \
    -w $'\n%{http_code}'
}

# fetch all pages for a collection endpoint; prints concatenated items as a JSON array
# $1: collection path (e.g., "servers"); $2: top-level key (e.g., "servers")
fetch_all() {
  local path="$1"
  local key="$2"
  local page=1
  local per_page=50
  local first=1
  echo -n '['
  while :; do
    local resp
    resp="$(api_get "$path?page=$page&per_page=$per_page")"
    local items
    items="$(jq -c ".${key}[]" <<<"$resp")"
    if [[ -z "$items" ]]; then
      break
    fi
    while IFS= read -r line; do
      if [[ $first -eq 0 ]]; then echo -n ','; fi
      echo -n "$line"
      first=0
    done <<< "$items"
    local next_page
    next_page="$(jq -r '.meta.pagination.next_page' <<<"$resp" 2>/dev/null || echo null)"
    if [[ "$next_page" == "null" || -z "$next_page" ]]; then
      break
    fi
    page=$next_page
  done
  echo ']'
}

WAIT=0
FORCE=0
PREFIX="snapshot-$(date +%F)-"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) WAIT=1; shift ;;
    --force) FORCE=1; shift ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

echo "Finding servers…"
SERVERS_JSON="$(fetch_all servers servers)"
COUNT="$(jq 'length // 0' <<<"$SERVERS_JSON")"
echo "Servers: $COUNT"

if [[ "${COUNT:-0}" -eq 0 ]]; then
  echo "No servers found."
  exit 0
fi

force_json=$([[ $FORCE -eq 1 ]] && echo true || echo false)

printf "\nTriggering snapshots%s%s with prefix '%s'\n" \
  "$([[ $FORCE -eq 1 ]] && echo ' (force)')" \
  "$([[ $WAIT -eq 1 ]] && echo ' and waiting')" \
  "$PREFIX"

while read -r srv; do
  id="$(jq -r '.id' <<<"$srv")"
  name="$(jq -r '.name // ("server-" + (.id|tostring))' <<<"$srv")"
  desc="${PREFIX}${name}"

  payload="$(jq -n --arg desc "$desc" --arg type snapshot --argjson force "$force_json" '{description:$desc, type:$type} + (if $force then {force:true} else {} end)')"

  if [[ $DRY_RUN -eq 1 ]]; then
    printf -- "- [dry-run] Would snapshot %s (id %s) with description '%s'\n" "$name" "$id" "$desc"
    continue
  fi

  printf -- "- Creating snapshot for %s (id %s)… " "$name" "$id"
  resp_with_code="$(api_post_status "servers/$id/actions/create_image" "$payload")"
  http_code="${resp_with_code##*$'\n'}"
  resp_body="${resp_with_code%$'\n'*}"

  if [[ ! "$http_code" =~ ^[0-9]+$ ]]; then
    echo "failed"
    echo "  Error: Unexpected response" | sed 's/^/  /'
    echo "$resp_body" | sed 's/^/    /'
    continue
  fi

  if (( http_code < 200 || http_code >= 300 )); then
    echo "failed ($http_code)"
    err_msg="$(jq -r 'try .error.message // .message // empty' <<<"$resp_body")"
    if [[ -n "$err_msg" ]]; then
      echo "  Error: $err_msg" | sed 's/^/  /'
    else
      echo "$resp_body" | sed 's/^/    /'
    fi
    # Helpful hint for 403
    if [[ "$http_code" == "403" ]]; then
      echo "  Hint: Ensure your API token has write permissions for the project." | sed 's/^/  /'
    fi
    continue
  fi

  action_id="$(jq -r '.action.id // empty' <<<"$resp_body")"
  image_id="$(jq -r '.image.id // empty' <<<"$resp_body")"
  echo "ok (action $action_id, image $image_id)"

  if [[ $WAIT -eq 1 && -n "${action_id:-}" ]]; then
    while :; do
      sleep 2
      aresp="$(api_get "actions/$action_id")"
      astatus="$(jq -r '.action.status // "unknown"' <<<"$aresp")"
      case "$astatus" in
        success) echo "  -> completed"; break ;;
        error)   echo "  -> error"; jq -c '.action' <<<"$aresp" | sed 's/^/     /'; break ;;
        running) printf "." ;;
        *)      printf " (%s)" "$astatus" ;;
      esac
    done
  fi
done < <(jq -c '.[]' <<<"$SERVERS_JSON")

echo "\nDone."
