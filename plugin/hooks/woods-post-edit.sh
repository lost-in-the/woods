#!/usr/bin/env bash
# Claude PostToolUse adapter; the shared runner owns queueing and refresh.
exec "$BASH" "${BASH_SOURCE[0]%/*}/woods-refresh.sh" claude
