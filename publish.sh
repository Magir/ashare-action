#!/usr/bin/env bash
# Publish to ashare (Issue #19): one file to ashare.net, the link in a comment on the pull request.
# Inputs come from action.yml as env: FILE, TITLE, API_KEY, BASE_URL, VISIBILITY, EXPIRES_IN, ARTIFACT_ID, COMMENT, GITHUB_TOKEN.
# From the runner: GITHUB_API_URL, GITHUB_REPOSITORY, GITHUB_EVENT_PATH, GITHUB_OUTPUT. Needs curl and jq (both on ubuntu runners).
set -euo pipefail

die(){ echo "::error::$*" >&2; exit 1; }
uri(){ jq -rn --arg v "$1" '$v|@uri'; }

FILE=${FILE:-}; TITLE=${TITLE:-}; BASE_URL=${BASE_URL:-https://ashare.net}; BASE_URL=${BASE_URL%/}
VISIBILITY=${VISIBILITY:-}; EXPIRES_IN=${EXPIRES_IN:-}; ARTIFACT_ID=${ARTIFACT_ID:-}; COMMENT=${COMMENT:-true}
GH_API=${GITHUB_API_URL:-https://api.github.com}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

[ -n "${API_KEY:-}" ] || die "api-key is empty. Pass it from a secret: api-key: \${{ secrets.ASHARE_API_KEY }}. On pull requests from forks GitHub does not pass secrets."
[ -n "$FILE" ] || die "file is empty: give the path to a .html, .md or .zip report"
case "$(tr '[:upper:]' '[:lower:]' <<<"${FILE##*.}")" in
  html|htm) FORMAT=html ;;
  md|markdown) FORMAT=md ;;
  zip) FORMAT=zip ;;
  *) die "file must end with .html, .htm, .md, .markdown or .zip: $FILE" ;;
esac
[ -f "$FILE" ] || die "file not found: $FILE (working directory $PWD)"
case "$VISIBILITY" in
  ''|public|private|company) ;;
  *) die "visibility must be public, private, company or empty: $VISIBILITY" ;;
esac

# ashare <path?query>: POST the file, body in $TMP/res, HTTP status on stdout. Errors of the API are JSON {error}.
ashare(){
  local args=(-sS -o "$TMP/res" -w '%{http_code}' -X POST "$BASE_URL/api/$1" -H "Authorization: Bearer $API_KEY" --data-binary @"$FILE")
  [ "$FORMAT" = zip ] && args+=(-H 'Content-Type: application/zip')
  curl "${args[@]}" || die "could not reach $BASE_URL"
}
github(){ # github <method> <path> [json] → body in $TMP/gh; dies on anything but 2xx
  local s args=(-sS -o "$TMP/gh" -w '%{http_code}' -X "$1" "$GH_API/$2" -H "Authorization: Bearer $GITHUB_TOKEN"
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
  [ -n "${3:-}" ] && args+=(-H 'Content-Type: application/json' -d "$3")
  s=$(curl "${args[@]}") || die "could not reach $GH_API"
  [[ $s == 2* ]] && return
  local hint=''; [ "$s" = 403 ] && hint='. Give the job "permissions: pull-requests: write"; on pull requests from forks the token is read-only.'
  die "GitHub API $1 /$2: HTTP $s: $(jq -r '.message // empty' "$TMP/gh" 2>/dev/null || true)$hint"
}

PR=''
[ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ] && PR=$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")
CID=''
if [ "$COMMENT" != true ]; then
  echo "comment: off"
elif [ -z "$PR" ]; then
  echo "comment: no pull request in this ${GITHUB_EVENT_NAME:-run} event, skipping the comment"
else
  [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || die "github-token and GITHUB_REPOSITORY are needed to comment on the pull request"
  # Our earlier comment holds the id of the document for this file: <!-- ashare id=<id> file=<file> -->. Only comments of the
  # token's own account count: anyone may comment on a public PR, and a planted marker must not point CI at another document.
  ME=$(curl -fsS "$GH_API/user" -H "Authorization: Bearer $GITHUB_TOKEN" 2>/dev/null | jq -r '.login // empty' 2>/dev/null || true)
  ME=${ME:-github-actions[bot]} # GITHUB_TOKEN may not read /user, its comments are github-actions[bot]'s
  for ((page = 1; ; page++)); do
    github GET "repos/$GITHUB_REPOSITORY/issues/$PR/comments?per_page=100&page=$page"
    HIT=$(jq -r --arg me "$ME" --arg f "$FILE" 'map(select(.user.login == $me)
      | (.body | capture("<!-- ashare id=(?<id>[A-Za-z0-9]+) file=(?<file>.+?) -->")?) as $m
      | select($m.file == $f) | "\(.id) \($m.id)") | first // empty' "$TMP/gh")
    [ -n "$HIT" ] || [ "$(jq length "$TMP/gh")" -lt 100 ] && break
  done
  if [ -n "$HIT" ]; then CID=${HIT% *}; [ -n "$ARTIFACT_ID" ] || { ARTIFACT_ID=${HIT#* }; FROM_COMMENT=1; }; fi
fi

Q="format=$FORMAT"
[ -n "$TITLE" ] && Q+="&title=$(uri "$TITLE")"
[ -n "$VISIBILITY" ] && Q+="&visibility=$(uri "$VISIBILITY")"
[ -n "$EXPIRES_IN" ] && Q+="&expires_in=$(uri "$EXPIRES_IN")"
S=''
if [ -n "$ARTIFACT_ID" ]; then
  S=$(ashare "artifacts/$(uri "$ARTIFACT_ID")/versions?$Q")
  # The document from our comment was deleted on ashare: start a new one rather than fail every run from now on.
  if [ "$S" = 404 ] && [ -n "${FROM_COMMENT:-}" ]; then echo "document $ARTIFACT_ID from the comment is gone, publishing a new one"; S=''; fi
fi
[ -n "$S" ] || S=$(ashare "artifacts?$Q")
[[ $S == 2* ]] || die "ashare: HTTP $S: $(jq -r '.error // empty' "$TMP/res" 2>/dev/null || head -c 300 "$TMP/res")"
read -r ID URL VERSION VIS < <(jq -r '"\(.id) \(.url) \(.version) \(.visibility)"' "$TMP/res")
echo "published $URL v$VERSION, $VIS"
[ -n "${GITHUB_OUTPUT:-}" ] && printf 'id=%s\nurl=%s\nversion=%s\n' "$ID" "$URL" "$VERSION" >>"$GITHUB_OUTPUT"

[ "$COMMENT" = true ] && [ -n "$PR" ] || exit 0
if [ -z "$TITLE" ]; then # the title ashare took from <title> or the first heading
  TITLE=$(curl -fsS "$BASE_URL/api/artifacts/$ID" -H "Authorization: Bearer $API_KEY" | jq -r .title) || TITLE=$FILE
fi
BODY=$(jq -n --arg b "<!-- ashare id=$ID file=$FILE -->
Report: $TITLE → $URL (v$VERSION)" '{body: $b}')
if [ -n "$CID" ]; then github PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$CID" "$BODY"; echo "comment updated: $(jq -r .html_url "$TMP/gh")"
else github POST "repos/$GITHUB_REPOSITORY/issues/$PR/comments" "$BODY"; echo "comment posted: $(jq -r .html_url "$TMP/gh")"; fi
