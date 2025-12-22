#!/usr/bin/env bash

set -e

VARS=(
  BATCHER_CA_CRT
  BATCHER_TLS_CRT
  BATCHER_TLS_KEY
  PROPOSER_CA_CRT
  PROPOSER_TLS_CRT
  PROPOSER_TLS_KEY
  CHALLENGER_CA_CRT
  CHALLENGER_TLS_CRT
  CHALLENGER_TLS_KEY
  ROLLUP_CONFIG
  L2_GENESIS
)

failed=0

for var in "${VARS[@]}"; do
  value="${!var}"

  if [[ -z "$value" ]]; then
    echo "❌ $var is empty"
    failed=1
  elif [[ ! -f "$value" ]]; then
    echo "❌ $var points to non-existing file: $value"
    failed=1
  else
    echo "✅ $var OK: $value"
  fi
done

if [[ $failed -ne 0 ]]; then
  echo
  echo "Some path checks failed."
  exit 1
else
  echo
  echo "All path checks passed."
fi