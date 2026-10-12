#!/usr/bin/env bash
# @name: Remove Guacamole key on all hosts
# @description: Runs the Guacamole key removal on every SSH connection in Nexterm (run on the Nexterm host)
set -euo pipefail

DEFAULT_URL="http://127.0.0.1:6989"
NEXTERM_KEY='AAAAC3NzaC1lZDI1NTE5AAAAIHQ9vmsolyPNE2tEo+Fry1tRya+I8j7u1iWnP0daEvbx'
GUAC_KEY='AAAAC3NzaC1lZDI1NTE5AAAAIOLS6/oYdkVgafkXbNJgthJJAiWFLGQ4cIyIZL/ZhTQZ'
CMD="F=\"\$HOME/.ssh/authorized_keys\"; if grep -qF '$GUAC_KEY' \"\$F\"; then if grep -qF '$NEXTERM_KEY' \"\$F\"; then printf '%s\n' \"\$(grep -vF '$GUAC_KEY' \"\$F\")\" > \"\$F\"; echo removed; else echo 'skipped: Nexterm key missing'; fi; else echo 'not present'; fi"

command -v jq >/dev/null || apt-get install -y jq >/dev/null
command -v curl >/dev/null || apt-get install -y curl >/dev/null

read -rp "Nexterm URL [$DEFAULT_URL]: " BASE
BASE="${BASE:-$DEFAULT_URL}"; BASE="${BASE%/}"
read -rsp "Nexterm API key: " KEY; echo
read -rp "Only connections whose name contains (Enter = all): " FILTER

api() { curl -sS -X "$1" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" ${3:+-d "$3"} "$BASE/api/$2"; }

ENTRIES=$(api GET entries/list | jq -c --arg f "$FILTER" '[.. | objects | select(.type? == "server" and .protocol? == "ssh" and (.name | ascii_downcase | contains($f | ascii_downcase)))] | unique_by(.id)')
COUNT=$(jq length <<<"$ENTRIES")
[ "$COUNT" -gt 0 ] || { echo "No matching SSH connections"; exit 0; }
echo "$COUNT SSH connections:"
jq -r '.[] | "  \(.name)"' <<<"$ENTRIES"
read -rp "Run the key removal on all of them? [y/N] " ok
[ "$ok" = "y" ] || { echo "Aborted"; exit 0; }

BODY=$(jq -nc --arg c "$CMD" '{command: $c}')
jq -c '.[] | {id, name}' <<<"$ENTRIES" | while read -r e; do
  printf '%-40s ' "$(jq -r .name <<<"$e")"
  api POST "connections/$(jq -r .id <<<"$e")/exec" "$BODY" \
    | jq -r 'if .exitCode? != null then ((.stdout // "") + (.stderr // "") | gsub("\n$"; "")) else "ERROR: " + (.message // .error // tostring) end' 2>/dev/null \
    || echo "ERROR: no valid response"
done
