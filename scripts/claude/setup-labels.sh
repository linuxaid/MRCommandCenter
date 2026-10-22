#!/usr/bin/env bash
# Creates (or updates) the labels the work-issues workflow uses. Safe to run more than once.
set -euo pipefail

gh label create "claude"             --color "D97757" --description "Queued for Claude to work" --force
gh label create "claude:in-progress" --color "FBCA04" --description "Claude is working this now" --force
gh label create "claude:needs-info"  --color "0E8A16" --description "Claude asked a question; waiting on a human" --force
gh label create "claude:pr-open"     --color "1D76DB" --description "PR open, waiting for human review" --force
gh label create "claude:blocked"     --color "B60205" --description "Claude got stuck; needs a human" --force

echo "Labels ready."
