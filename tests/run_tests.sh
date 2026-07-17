#!/usr/bin/env bash
# Run the Busted test suite for Lightroom Llama plugin modules.
# Usage:  ./tests/run_tests.sh [spec file or directory]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$SCRIPT_DIR"

busted \
    -e "dofile('helpers/mock_sdk.lua')" \
    "${1:-spec/}"
