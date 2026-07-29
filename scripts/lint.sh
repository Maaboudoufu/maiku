#!/usr/bin/env bash
# Formats and lints Swift sources. Exits nonzero on failure.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! swift format --version >/dev/null 2>&1; then
	echo "swift format is unavailable in this toolchain; skipping." >&2
	exit 0
fi

MODE="${1:-lint}"
case "$MODE" in
fix) swift format --in-place --recursive Sources Tests ;;
lint) swift format lint --strict --recursive Sources Tests ;;
*)
	echo "usage: $0 [lint|fix]" >&2
	exit 2
	;;
esac
