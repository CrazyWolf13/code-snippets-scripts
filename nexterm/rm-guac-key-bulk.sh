#!/usr/bin/env bash
# @name: Nexterm: Remove Guacamole key in a folder
# @description: Runs the Guacamole key removal on all SSH connections in a Nexterm folder (run on the Nexterm host)
set -euo pipefail

NEXTERM_KEY='AAAAC3NzaC1lZDI1NTE5AAAAIHQ9vmsolyPNE2tEo+Fry1tRya+I8j7u1iWnP0daEvbx'
GUAC_KEY='AAAAC3NzaC1lZDI1NTE5AAAAIOLS6/oYdkVgafkXbNJgthJJAiWFLGQ4cIyIZL/ZhTQZ'
CMD="F=\"\$HOME/.ssh/authorized_keys\"; if grep -qF '$GUAC_KEY' \"\$F\"; then if grep -qF '$NEXTERM_KEY' \"\$F\"; then printf '%s\n' \"\$(grep -vF '$GUAC_KEY' \"\$F\")\" > \"\$F\"; echo removed; else echo 'skipped: Nexterm key missing'; fi; else echo 'not present'; fi"

command -v jq >/dev/null || apt-get install -y jq >/dev/null
command -v curl >/dev/null || apt-get install -y curl >/dev/null

@NEXTERM:INPUT BASE "Nexterm URL" "http://127.0.0.1:6989"
@NEXTERM:INPUT KEY "Nexterm API key"
BASE="${BASE%/}"

api() { curl -sS -X "$1" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" ${3:+-d "$3"} "$BASE/api/$2"; }

@NEXTERM:STEP "Loading folders"
TREE=$(api GET entries/list)
FOLDERS=$(jq -c 'def f($p): .[]? | select((.entries? | type) == "array") | ($p + [.name // (.id|tostring)]) as $np | {path: ($np | join(" / ")), node: .}, (.entries | f($np)); [f([])]' <<<"$TREE")
CHOICES=$(jq -r '["\"0 - All connections\""] + (to_entries | map("\"\(.key + 1) - \(.value.path | gsub("[\":]"; ""))\"")) | join(" ")' <<<"$FOLDERS")
@NEXTERM:SELECT SEL "Folder" $CHOICES
SEL="${SEL%% *}"

if [ "$SEL" != "0" ]; then
  SCOPE=$(jq -c --argjson i "$SEL" '[.[$i - 1].node // empty]' <<<"$FOLDERS")
else
  SCOPE="$TREE"
fi

ENTRIES=$(jq -c '[.. | objects | select(.type? == "server" and .protocol? == "ssh")] | unique_by(.id)' <<<"$SCOPE")
COUNT=$(jq length <<<"$ENTRIES")
if [ "$COUNT" -eq 0 ]; then
  @NEXTERM:INFO "No SSH connections there"
  exit 0
fi
jq -r '.[] | "  \(.name)"' <<<"$ENTRIES"
@NEXTERM:CONFIRM "Run the key removal on these $COUNT SSH connections (including subfolders)?"

@NEXTERM:STEP "Removing key"
BODY=$(jq -nc --arg c "$CMD" '{command: $c}')
jq -c '.[] | {id, name}' <<<"$ENTRIES" | while read -r e; do
  printf '%-40s ' "$(jq -r .name <<<"$e")"
  api POST "connections/$(jq -r .id <<<"$e")/exec" "$BODY" \
    | jq -r 'if .exitCode? != null then ((.stdout // "") + (.stderr // "") | gsub("\n$"; "")) else "ERROR: " + (.message // .error // tostring) end' 2>/dev/null \
    || echo "ERROR: no valid response"
done
@NEXTERM:SUCCESS "Done with $COUNT connections"
