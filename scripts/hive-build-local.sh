#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/hive-build-local.sh [--ref main|TAG] [--board BOARD|all]

The GitHub ref is resolved to an immutable SHA, uploaded to Gitea as a
one-shot ci/build/* ref, and dispatched to the local develop runner.
Set GITEA_TOKEN in the environment; it is never written to the repository.
EOF
}

ref=main
board=all
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) ref="${2:?missing value for --ref}"; shift 2 ;;
    --board) board="${2:?missing value for --board}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$board" in
  all|nanopi-zero2|nanopi-r3s|orangepi4-lts) ;;
  *) echo "invalid board: $board" >&2; exit 2 ;;
esac

: "${GITEA_TOKEN:?set GITEA_TOKEN before running this script}"
git fetch --tags origin

if [[ "$ref" == "main" ]]; then
  source_sha="$(git rev-parse origin/main^{commit})"
  release_tag=""
else
  source_sha="$(git rev-parse "refs/tags/${ref}^{commit}")"
  release_tag="$ref"
fi

short_sha="${source_sha:0:7}"
build_ref="ci/build/manual-$(date -u +%Y%m%d%H%M%S)-${short_sha}-$$"
askpass="$(mktemp)"
cleanup() { rm -f "$askpass"; }
trap cleanup EXIT
cat >"$askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' 'SakuraPuare' ;;
  *Password*) printf '%s\n' "${GITEA_TOKEN}" ;;
  *) exit 1 ;;
esac
ASKPASS
chmod 700 "$askpass"
export GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0

git remote get-url gitea >/dev/null 2>&1 || \
  git remote add gitea https://gitea.sakurapuare.com/SakuraPuare/Hive.git
git push gitea "${source_sha}:refs/heads/${build_ref}"

payload="$(jq -n \
  --arg ref "$build_ref" \
  --arg source_sha "$source_sha" \
  --arg build_ref "$build_ref" \
  --arg board "$board" \
  --arg release_tag "$release_tag" \
  '{ref:$ref,inputs:{source_sha:$source_sha,build_ref:$build_ref,board:$board,release_tag:$release_tag}}')"
response="$(curl --fail-with-body --silent --show-error \
  --request POST \
  --url 'https://gitea.sakurapuare.com/api/v1/repos/SakuraPuare/Hive/actions/workflows/build-image.yml/dispatches?return_run_details=true' \
  --header 'Accept: application/json' \
  --header 'Content-Type: application/json' \
  --header "Authorization: token ${GITEA_TOKEN}" \
  --data "$payload")"

printf 'source_sha=%s\nbuild_ref=%s\nboard=%s\n' "$source_sha" "$build_ref" "$board"
if [[ -n "$response" ]]; then
  printf '%s\n' "$response" | jq -r '.html_url // .id // empty'
fi
