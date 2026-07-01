#!/usr/bin/env bash
# LEGACY SHIM (2026-07-01, aiImprove audit): npm-install-review logic merged
# into bash-guards.sh (single dispatcher, one jq parse for all Bash guards).
# This shim keeps ALREADY-RUNNING sessions working — they snapshotted this
# registration at session start. New sessions register bash-guards.sh directly.
# Safe to delete (here and in chezmoi) once pre-2026-07-01 sessions are gone.
exec "$HOME/.claude/hooks/bash-guards.sh"
