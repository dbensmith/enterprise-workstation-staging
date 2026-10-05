#!/usr/bin/env bash
# Make the repo's vendored open-gsd (gsd-core) reachable at ~/.claude/gsd-core.
# GSD skills and agents reference ~/.claude/gsd-core directly; on a machine with a
# global install this is a no-op, in a fresh cloud session it links the repo copy.
set -u
project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
src="$project_dir/.claude/gsd-core"
dest="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/gsd-core"

[ -d "$src" ] || exit 0
[ -e "$dest" ] && exit 0

mkdir -p "$(dirname "$dest")"
ln -s "$src" "$dest" 2>/dev/null || cp -r "$src" "$dest"
exit 0
