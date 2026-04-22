#!/bin/sh
# addon/webui/tests/run.sh — run Node-based webui tests, graceful-skip if
# Node <18 not installed.

set -eu

cd "$(dirname "$0")/../.."

if ! command -v node >/dev/null 2>&1; then
    echo "node not installed — skipping webui tests"
    exit 0
fi

# Extract major version
node_major="$(node --version | sed 's/^v//; s/\..*//')"
if [ "${node_major}" -lt 18 ] 2>/dev/null; then
    echo "node ${node_major} < 18; skipping webui tests"
    exit 0
fi

node --test webui/tests/parser.test.js webui/tests/validator.test.js webui/tests/geo.test.js
