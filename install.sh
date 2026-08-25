#!/usr/bin/env bash
#
# install.sh — link the worktree kit into ~/.local so every project can use it.
#
# Symlinks, never copies: `git pull` in this clone then updates what is
# installed, so the working copy and the installed copy cannot drift apart.
# The trade is that this clone becomes load-bearing — move or delete it and
# the commands stop resolving.
#
# Usage:
#   ./install.sh              # link into ~/.local
#   ./install.sh --uninstall  # remove the links
#   PREFIX=/somewhere ./install.sh
#
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
LIB="$PREFIX/lib/wtkit"
CMDS=(new-workspace new-task remove-workspace)

if [ "${1:-}" = "--uninstall" ]; then
  for c in "${CMDS[@]}"; do
    if [ -L "$BIN/$c" ]; then rm -f "$BIN/$c"; echo "removed $BIN/$c"; fi
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

case ":${PATH}:" in
  *":$BIN:"*) ;;
  *) echo ""; echo "!! $BIN is not on PATH. Add to your shell rc:  export PATH=\"$BIN:\$PATH\"" >&2 ;;
esac

echo ""
echo "✅ Installed. Try:  new-workspace --help"
