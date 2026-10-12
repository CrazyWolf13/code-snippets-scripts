#!/usr/bin/env bash
# @name: Swap identity on connections
# @description: Replaces one identity with another on all Nexterm connections (run on the Nexterm host)
set -euo pipefail

DEFAULT_URL="http://127.0.0.1:6989"

command -v jq >/dev/null || apt-get install -y jq >/dev/null
command -v curl >/dev/null || apt-get install -y curl >/dev/null

read -rp "Nexterm URL [$DEFAULT_URL]: " BASE
BASE="${BASE:-$DEFAULT_URL}"; BASE="${BASE%/}"
read -rsp "Nexterm API key: " KEY; echo

api() { curl -fsS -X "$1" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" ${3:+-d "$3"} "$BASE/api/$2"; }

echo "Identities:"
api GET identities/list | jq -r '.[] | "  id \(.id)\t\(.name)\t(user: \(.username // "-"))"'
read -rp "Old identity id: " OLD
read -rp "New identity id: " NEW

ENTRIES=$(api GET entries/list | jq -c --argjson old "$OLD" '[.. | objects | select(.type? == "server" and any((.identities? // [])[]; . == $old))] | unique_by(.id)')
COUNT=$(jq length <<<"$ENTRIES")
[ "$COUNT" -gt 0 ] || { echo "No connections use identity $OLD"; exit 0; }
echo "$COUNT connections use identity $OLD:"
jq -r '.[] | "  \(.name)"' <<<"$ENTRIES"
read -rp "Switch them to identity $NEW? [y/N] " ok
[ "$ok" = "y" ] || { echo "Aborted"; exit 0; }

jq -c --argjson old "$OLD" --argjson new "$NEW" '.[] | {id, name, ids: (.identities | map(if . == $old then $new else . end) | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end))}' <<<"$ENTRIES" |
while read -r e; do
  printf '%s: ' "$(jq -r .name <<<"$e")"
  api PATCH "entries/$(jq -r .id <<<"$e")" "$(jq -c '{identities: .ids}' <<<"$e")" | jq -r '.message // .' || echo "FAILED"
done
