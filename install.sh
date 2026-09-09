#!/usr/bin/env bash
#
# install.sh — link the worktree kit into ~/.local so every project can use it.
#
# Symlinks, never copies: `git pull` in this clone then updates what is
# installed, so the working copy and the installed copy cannot drift apart.
# The trade is that this clone becomes load-bearing — move or delete it and
# the commands stop resolving.
#
# Slash commands are linked the same way, into ~/.claude/commands, which is
# user scope: they then work in every project without a per-repo file.
#
# Usage:
#   ./install.sh                 # link bin, lib and the slash commands
#   ./install.sh --no-commands   # skip the slash commands
#   ./install.sh --uninstall     # remove every link this script made
#   PREFIX=/somewhere ./install.sh
#
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
LIB="$PREFIX/lib/wtkit"
CMDDIR="${CLAUDE_COMMANDS_DIR:-$HOME/.claude/commands}"

CMDS=(new-workspace new-task start-worktree remove-workspace
      wtconf ship-lock ship-classify land-local
      next-task-args next-task-preflight next-task-reset ship-land-args)
SLASH=(next-task.md ship-land.md open-worktree.md)

WANT_COMMANDS=1
for a in "$@"; do [ "$a" = "--no-commands" ] && WANT_COMMANDS=0; done

if [ "${1:-}" = "--uninstall" ]; then
  for c in "${CMDS[@]}"; do
    if [ -L "$BIN/$c" ]; then rm -f "$BIN/$c"; echo "removed $BIN/$c"; fi
  done
  for s in "${SLASH[@]}"; do
    # Only ever remove OUR symlink. A real file there is the user's own command.
    if [ -L "$CMDDIR/$s" ]; then rm -f "$CMDDIR/$s"; echo "removed $CMDDIR/$s"; fi
  done
  if [ -L "$LIB" ]; then rm -f "$LIB"; echo "removed $LIB"; fi
  exit 0
fi

mkdir -p "$BIN" "$PREFIX/lib"

# A previous copy-based install leaves a real directory here; replace it.
if [ -d "$LIB" ] && [ ! -L "$LIB" ]; then
  echo "==> Replacing the existing directory $LIB with a symlink"
  rm -rf "$LIB"
fi
ln -sfn "$SRC/lib/wtkit" "$LIB"
echo "linked $LIB -> $SRC/lib/wtkit"

for c in "${CMDS[@]}"; do
  if [ -e "$BIN/$c" ] && [ ! -L "$BIN/$c" ]; then
    echo "==> Replacing the existing file $BIN/$c with a symlink"
    rm -f "$BIN/$c"
  fi
  ln -sfn "$SRC/bin/$c" "$BIN/$c"
  echo "linked $BIN/$c -> $SRC/bin/$c"
done

if [ "$WANT_COMMANDS" -eq 1 ]; then
  mkdir -p "$CMDDIR"
  for s in "${SLASH[@]}"; do
    # Unlike the bin shims, a slash command that is a REAL file is user content
    # (hand-written, or an older copy they have since edited). Never clobber it
    # — say so and let them decide.
    if [ -e "$CMDDIR/$s" ] && [ ! -L "$CMDDIR/$s" ]; then
      echo "!! skipped $CMDDIR/$s — a real file is already there. Move it aside" >&2
      echo "!!   and re-run if you want the kit's version." >&2
      continue
    fi
    ln -sfn "$SRC/examples/commands/$s" "$CMDDIR/$s"
    echo "linked $CMDDIR/$s -> $SRC/examples/commands/$s"
  done
  echo ""
  echo "Note: a project-scoped copy of any of these (<repo>/.claude/commands/) is"
  echo "      a separate command that conflicts with the user-scope one. Remove the"
  echo "      project copy once you want the kit's version to be the only one."
fi

case ":${PATH}:" in
  *":$BIN:"*) ;;
  *) echo ""; echo "!! $BIN is not on PATH. Add to your shell rc:  export PATH=\"$BIN:\$PATH\"" >&2 ;;
esac

echo ""
echo "✅ Installed. Try:  new-workspace --help   /   ship-lock --help"
