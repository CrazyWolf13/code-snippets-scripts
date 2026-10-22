#!/usr/bin/env bash
# @name: Nexterm: Run snippet or script on a folder
# @description: Runs a Nexterm snippet or script on every SSH connection in a folder, one by one (run on the Nexterm host)
set -euo pipefail

command -v jq >/dev/null || apt-get install -y jq >/dev/null
command -v curl >/dev/null || apt-get install -y curl >/dev/null

@NEXTERM:INPUT BASE "Nexterm URL" "http://127.0.0.1:6989"
BASE="${BASE%/}"
# Ask again until the key works (Nexterm's dialog can submit an empty value when Enter is pressed on the previous one)
while :; do
  @NEXTERM:INPUT KEY "Nexterm API key"
  [ -n "$KEY" ] || continue
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" "$BASE/api/entries/list" || true)
  [ "$CODE" = 200 ] && break
  if [ "$CODE" = 000 ]; then
    @NEXTERM:WARN "Can't reach Nexterm at $BASE"
    exit 1
  fi
  @NEXTERM:WARN "API key rejected (HTTP $CODE), try again"
done

api() { curl -sS -X "$1" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" ${3:+-d "$3"} "$BASE/api/$2"; }
list() { api GET "$1" | jq -c 'if type == "array" then . else [] end' 2>/dev/null || echo '[]'; }

@NEXTERM:STEP "Loading snippets and scripts"
# Scripts with directives need Nexterm's runner, so they can't run over the API
MARK="@NEXT""ERM:"
ITEMS=$(jq -sc --arg mark "$MARK" '
  (.[0] + .[1] | map({kind: "Snippet", id, name, body: .command})) +
  (.[2] + .[3] | map({kind: "Script", id, name, body: .content}))
  | map(select((.body // "") != "" and (.body | contains($mark) | not)))
  | unique_by([.kind, .id]) | sort_by(.kind, (.name | ascii_downcase))' \
  <(list snippets/all) <(list snippets/sources) <(list scripts/all) <(list scripts/sources))
if [ "$(jq length <<<"$ITEMS")" -eq 0 ]; then
  @NEXTERM:WARN "No runnable snippets or scripts found"
  exit 1
fi
CHOICES=$(jq -r 'to_entries | map("\"\(.key + 1) - \(.value.kind): \(.value.name | gsub("[\":]"; ""))\"") | join(" ")' <<<"$ITEMS")
@NEXTERM:SELECT ITEM "What to run" $CHOICES
ITEM="${ITEM%% *}"
NAME=$(jq -r --argjson i "$ITEM" '.[$i - 1].name' <<<"$ITEMS")
BODY=$(jq -r --argjson i "$ITEM" '.[$i - 1].body' <<<"$ITEMS")

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
@NEXTERM:SELECT ONERROR "If a host fails" "Continue with the next host" "Stop"

jq -r '.[] | "  \(.name)"' <<<"$ENTRIES"
if grep -qE '(^|[;&|[:space:]])read[[:space:]]' <<<"$BODY"; then
  @NEXTERM:WARN "$NAME contains a read prompt. Commands run without a terminal, so prompts get no answer."
fi
@NEXTERM:CONFIRM "Run $NAME on these $COUNT SSH connections (including subfolders), one by one?"

# The body is sent base64-encoded, so quotes and multiple lines survive; it runs with bash, or sh if bash is missing
CMD="printf '%s' '$(printf '%s' "$BODY" | base64 -w0)' | base64 -d | \"\$(command -v bash || command -v sh)\""
PAYLOAD=$(jq -nc --arg c "$CMD" '{command: $c}')

@NEXTERM:STEP "Running $NAME"
OK=0; FAILED=0
while read -r e; do
  HOST=$(jq -r .name <<<"$e")
  echo "===== $HOST"
  RES=$(api POST "connections/$(jq -r .id <<<"$e")/exec" "$PAYLOAD" || true)
  if jq -e '.exitCode? != null' <<<"$RES" >/dev/null 2>&1; then
    jq -r '(.stdout // "") + (.stderr // "") | sub("\n+$"; "")' <<<"$RES"
    RC=$(jq -r .exitCode <<<"$RES")
  else
    echo "ERROR: $(jq -r '.message // .error // tostring' <<<"$RES" 2>/dev/null || echo "no valid response")"
    RC=1
  fi
  if [ "$RC" -eq 0 ]; then
    OK=$((OK + 1))
  else
    FAILED=$((FAILED + 1))
    echo "-> failed (exit $RC)"
    if [ "$ONERROR" = "Stop" ]; then break; fi
  fi
done < <(jq -c '.[] | {id, name}' <<<"$ENTRIES")

if [ "$FAILED" -eq 0 ]; then
  @NEXTERM:SUCCESS "$NAME finished on all $OK connections"
else
  @NEXTERM:WARN "$NAME: $OK succeeded, $FAILED failed"
fi
