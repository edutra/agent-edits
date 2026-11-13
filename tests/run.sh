#!/usr/bin/env bash
# Runs every test: the hook, the installer, the popup and the viewer.
# Usage: tests/run.sh [-v] [-k PATTERN]   (any python -m unittest option)
# PYTHON picks the interpreter (default: python3).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec "${PYTHON:-python3}" -m unittest discover -s . -p 'test_*.py' "$@"
