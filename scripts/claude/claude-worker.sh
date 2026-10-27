#!/usr/bin/env bash
# Runs the work-issues skill headless: one pass that works up to CLAUDE_WORKER_MAX_ISSUES
# issues into today's release (tag and app version yy.m.d). One release per day, so once
# today's release exists, later runs exit straight away. Meant to be started by launchd.
#
# Runs in a DEDICATED clone (not the copy you edit by hand), so Claude never
# trips over your uncommitted work. Set CLAUDE_WORKER_REPO to override.
set -uo pipefail

REPO_DIR="${CLAUDE_WORKER_REPO:-$HOME/claude-worker/MRCommandCenter}"
LOG_DIR="$HOME/Library/Logs/mrcc-claude-worker"
LOCK_DIR="/tmp/mrcc-claude-worker.lock"
MAX_ISSUES="${CLAUDE_WORKER_MAX_ISSUES:-5}"
# Per run, so it scales with the number of issues a release can hold.
MAX_BUDGET_USD="${CLAUDE_WORKER_MAX_BUDGET_USD:-$((10 * MAX_ISSUES))}"

# Issues labeled `claude` with none of the state labels.
eligible_count() {
  gh issue list --state open --label claude --json labels \
    --jq '[.[] | select([.labels[].name] | any(. == "claude:in-progress" or . == "claude:needs-info" or . == "claude:pr-open" or . == "claude:blocked") | not)] | length'
}

# Everything runs inside main, which bash parses in full before running. Each pass
# pulls main into this clone, which can rewrite this file mid-run.
main() {
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H%M%S).log"
  exec >>"$LOG_FILE" 2>&1

  echo "=== $(date) starting worker in $REPO_DIR (up to $MAX_ISSUES issues in today's release) ==="

  # Only one run at a time.
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another run is in progress; exiting."
    exit 0
  fi
  trap 'rmdir "$LOCK_DIR"' EXIT

  cd "$REPO_DIR" || { echo "Repo not found at $REPO_DIR"; exit 1; }

  STATUS=0
  # Cheap checks first, so a day that's already released or an empty queue costs nothing.
  VERSION=$(bash scripts/claude/release-version.sh)
  ELIGIBLE=$(eligible_count)
  if gh release view "$VERSION" >/dev/null 2>&1; then
    echo "Already released today ($VERSION)."
  elif [ "${ELIGIBLE:-0}" = "0" ]; then
    echo "No eligible issues."
  else
    echo "--- $ELIGIBLE eligible issue(s); building release $VERSION ---"
    # dontAsk: anything not covered by .claude/settings.json allow rules is denied, never prompted.
    claude -p "/work-issues $MAX_ISSUES" \
      --permission-mode dontAsk \
      --permission-prompts none \
      --max-budget-usd "$MAX_BUDGET_USD" \
      --output-format json
    STATUS=$?
    echo "--- finished with exit code $STATUS ---"
  fi

  echo "=== $(date) finished with exit code $STATUS ==="

  # Keep 30 days of logs.
  find "$LOG_DIR" -name '*.log' -mtime +30 -delete
  exit $STATUS
}

main "$@"
exit
