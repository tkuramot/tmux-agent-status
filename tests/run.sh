#!/usr/bin/env bash
# Runs the tests, each file against its own tmux server.
# Usage: tests/run.sh [plugin|agent|list|gh|recipes]...

set -u

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -gt 0 ] || set -- plugin agent list gh recipes
failed=""
for name in "$@"; do
	printf '\n# %s\n' "$name"
	bash "$dir/$name.sh" || failed="$failed $name"
done
if [ -n "$failed" ]; then
	printf '\nfailed:%s\n' "$failed"
	exit 1
fi
printf '\nall passed\n'
