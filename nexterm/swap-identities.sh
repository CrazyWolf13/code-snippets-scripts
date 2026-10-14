#!/usr/bin/env bash
# @name: Swap identity on connections
# @description: Replaces one identity with another on all Nexterm connections (run on the Nexterm host)
set -euo pipefail

command -v jq >/dev/null || apt-get install -y jq >/dev/null
command -v curl >/dev/null || apt-get install -y curl >/dev/null

@NEXTERM:INPUT BASE "Nexterm URL" "http://127.0.0.1:6989"
@NEXTERM:INPUT KEY "Nexterm API key"
BASE="${BASE%/}"

api() { curl -fsS -X "$1" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" ${3:+-d "$3"} "$BASE/api/$2"; }

@NEXTERM:STEP "Loading identities"
IDENTITIES=$(api GET identities/list | jq -r 'map("\"\(.id) - \(.name | gsub("[\":]"; "")) (\(.username // "-"))\"") | join(" ")')
@NEXTERM:SELECT OLD "Identity to replace" $IDENTITIES
@NEXTERM:SELECT NEW "Replace it with" $IDENTITIES
OLD="${OLD%% *}"; NEW="${NEW%% *}"
if [ "$OLD" = "$NEW" ]; then
  @NEXTERM:WARN "Old and new identity are the same"
  exit 1
fi

ENTRIES=$(api GET entries/list | jq -c --argjson old "$OLD" '[.. | objects | select(.type? == "server" and any((.identities? // [])[]; . == $old))] | unique_by(.id)')
COUNT=$(jq length <<<"$ENTRIES")
if [ "$COUNT" -eq 0 ]; then
  @NEXTERM:INFO "No connections use identity $OLD"
  exit 0
fi
jq -r '.[] | "  \(.name)"' <<<"$ENTRIES"
@NEXTERM:CONFIRM "Switch these $COUNT connections from identity $OLD to $NEW?"

@NEXTERM:STEP "Updating connections"
jq -c --argjson old "$OLD" --argjson new "$NEW" '.[] | {id, name, ids: (.identities | map(if . == $old then $new else . end) | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end))}' <<<"$ENTRIES" |
while read -r e; do
  printf '%s: ' "$(jq -r .name <<<"$e")"
  api PATCH "entries/$(jq -r .id <<<"$e")" "$(jq -c '{identities: .ids}' <<<"$e")" | jq -r '.message // .' || echo "FAILED"
done
@NEXTERM:SUCCESS "Updated $COUNT connections"
