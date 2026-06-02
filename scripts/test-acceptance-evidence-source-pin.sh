#!/usr/bin/env bash
set -euo pipefail

readonly root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

readonly source_commit=0123456789abcdef0123456789abcdef01234567
readonly source_sha=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

jq \
  --arg productionUrl 'https://worker.example' \
  --arg deploymentTimestampUtc '2026-06-02T00:00:00Z' \
  --arg sourceCodeUrl 'https://github.com/agent/example' \
  --arg sourceArchiveUrl 'https://github.com/agent/example/archive/unrelated.tar.gz' \
  --arg sourceArchiveSha256 "$source_sha" \
  --arg sourceMirrorCommit "$source_commit" \
  '
    .productionUrl = $productionUrl
    | .deploymentTimestampUtc = $deploymentTimestampUtc
    | .sourceCodeUrl = $sourceCodeUrl
    | .sourceArchiveUrl = $sourceArchiveUrl
    | .sourceArchiveSha256 = $sourceArchiveSha256
    | .sourceMirrorCommit = $sourceMirrorCommit
  ' \
  "$root/ACCEPTANCE-EVIDENCE.example.json" \
  >"$test_root/evidence.json"

set +e
BARNACLE_SKIP_PUBLIC_SOURCE_CODE_CHECK=1 \
  BARNACLE_SKIP_REMOTE_SOURCE_CHECK=1 \
  BARNACLE_SKIP_PUBLIC_PREFLIGHT=1 \
  "$root/scripts/validate-acceptance-evidence.sh" "$test_root/evidence.json" \
  >"$test_root/validator.log" 2>&1
status=$?
set -e

if [[ $status != 2 ]]; then
  printf 'expected source-pin mismatch to exit 2, got %s\n' "$status" >&2
  exit 1
fi
if ! rg -q 'sourceArchiveUrl must be pinned to sourceMirrorCommit' "$test_root/validator.log"; then
  printf 'source-pin mismatch did not report the expected reason\n' >&2
  exit 1
fi

printf 'acceptance-evidence-source-pin-tests-passed\n'
