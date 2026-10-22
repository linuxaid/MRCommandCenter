#!/usr/bin/env bash
# Runs one pass of the work-issues skill, headless. Meant to be started by launchd.
#
# Runs in a DEDICATED clone (not the copy you edit by hand), so Claude never
# trips over your uncommitted work. Set CLAUDE_WORKER_REPO to override.
set -uo pipefail

REPO_DIR="${CLAUDE_WORKER_REPO:-$HOME/claude-worker/MRCommandCenter}"
LOG_DIR="$HOME/Library/Logs/mrcc-claude-worker"
LOCK_DIR="/tmp/mrcc-claude-worker.lock"
MAX_BUDGET_USD="${CLAUDE_WORKER_MAX_BUDGET_USD:-10}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H%M%S).log"
exec >>"$LOG_FILE" 2>&1

echo "=== $(date) starting worker in $REPO_DIR ==="

# Only one run at a time.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another run is in progress; exiting."
  exit 0
fi
trap 'rmdir "$LOCK_DIR"' EXIT

cd "$REPO_DIR" || { echo "Repo not found at $REPO_DIR"; exit 1; }

# Cheap check first so an empty queue costs nothing.
ELIGIBLE=$(gh issue list --state open --label claude --json labels \
  --jq '[.[] | select([.labels[].name] | any(. == "claude:in-progress" or . == "claude:needs-info" or . == "claude:pr-open" or . == "claude:blocked") | not)] | length')
if [ "${ELIGIBLE:-0}" = "0" ]; then
  echo "No eligible issues."
  exit 0
fi
echo "$ELIGIBLE eligible issue(s)."

# dontAsk: anything not covered by .claude/settings.json allow rules is denied, never prompted.
claude -p "/work-issues" \
  --permission-mode dontAsk \
  --permission-prompts none \
  --max-budget-usd "$MAX_BUDGET_USD" \
  --output-format json
STATUS=$?

echo "=== $(date) finished with exit code $STATUS ==="

# Keep 30 days of logs.
find "$LOG_DIR" -name '*.log' -mtime +30 -delete
exit $STATUS
