#!/usr/bin/env bash
# Prints today's release version and tag: two-digit year, then month and day without
# leading zeros (26.10.27, 26.1.5). Apple requires each part of an app version to be a
# plain number, so zero padding would be dropped anyway. One release per day.
set -euo pipefail
date +%y.%-m.%-d
