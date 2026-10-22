#!/usr/bin/env bash
# Runs the work-issues skill headless, one issue per pass, for up to
# CLAUDE_WORKER_MAX_ISSUES passes. Meant to be started by launchd.
#
# Runs in a DEDICATED clone (not the copy you edit by hand), so Claude never
# trips over your uncommitted work. Set CLAUDE_WORKER_REPO to override.
set -uo pipefail

REPO_DIR="${CLAUDE_WORKER_REPO:-$HOME/claude-worker/MRCommandCenter}"
LOG_DIR="$HOME/Library/Logs/mrcc-claude-worker"
LOCK_DIR="/tmp/mrcc-claude-worker.lock"
MAX_BUDGET_USD="${CLAUDE_WORKER_MAX_BUDGET_USD:-10}"
MAX_ISSUES="${CLAUDE_WORKER_MAX_ISSUES:-3}"

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

  echo "=== $(date) starting worker in $REPO_DIR (up to $MAX_ISSUES issues) ==="

  # Only one run at a time.
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another run is in progress; exiting."
    exit 0
  fi
  trap 'rmdir "$LOCK_DIR"' EXIT

  cd "$REPO_DIR" || { echo "Repo not found at $REPO_DIR"; exit 1; }

  STATUS=0
  for ((pass = 1; pass <= MAX_ISSUES; pass++)); do
    # Cheap check first so an empty queue costs nothing.
    BEFORE=$(eligible_count)
    if [ "${BEFORE:-0}" = "0" ]; then
      echo "No eligible issues."
      break
    fi
    echo "--- pass $pass of $MAX_ISSUES: $BEFORE eligible issue(s) ---"

    # dontAsk: anything not covered by .claude/settings.json allow rules is denied, never prompted.
    # `once`: one issue per pass, so CLAUDE_WORKER_MAX_ISSUES caps the run.
    claude -p "/work-issues once" \
      --permission-mode dontAsk \
      --permission-prompts none \
      --max-budget-usd "$MAX_BUDGET_USD" \
      --output-format json
    STATUS=$?
    echo "--- pass $pass finished with exit code $STATUS ---"
    if [ "$STATUS" != "0" ]; then
      echo "Stopping after a failed pass."
      break
    fi

    # Every finished pass labels its issue, so the queue shrinks. If it didn't
    # (for example the tree wasn't clean), another pass would just repeat it.
    AFTER=$(eligible_count)
    if [ "${AFTER:-0}" -ge "${BEFORE:-0}" ]; then
      echo "Queue didn't shrink ($BEFORE -> $AFTER); stopping."
      break
    fi
  done

  echo "=== $(date) finished with exit code $STATUS ==="

  # Keep 30 days of logs.
  find "$LOG_DIR" -name '*.log' -mtime +30 -delete
  exit $STATUS
}

main "$@"
exit
