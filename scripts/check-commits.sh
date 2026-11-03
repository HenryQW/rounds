#!/bin/sh
# Fails if a commit subject in <range> does not follow Conventional Commits (AGENTS.md): `type(scope): summary`, with
# a known type, an optional scope and `!`, and a lower-case summary with no full stop. Merges are left out.
# Usage: scripts/check-commits.sh <range>, for example v0.1.1..HEAD.
set -e
BAD="$(git log --no-merges --format='%h %s' "$1" | grep -Ev '^[0-9a-f]+ (feat|fix|docs|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: [a-z0-9].*[^.]$' || true)"
if [ -n "$BAD" ]; then
    echo "Not Conventional Commits (type(scope): lower-case summary, no full stop):"
    echo "$BAD"
    exit 1
fi
echo "$(git rev-list --no-merges --count "$1") commit subjects follow Conventional Commits."
