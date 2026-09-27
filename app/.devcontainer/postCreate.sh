#!/usr/bin/env bash
# Compatibility entry point; SDK installation belongs to the shared Dockerfile.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/setup.py"
