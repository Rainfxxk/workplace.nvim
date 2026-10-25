#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

nvim --headless --clean -u NONE -l tests/run.lua
