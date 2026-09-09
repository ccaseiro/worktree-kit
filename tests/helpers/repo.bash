#!/usr/bin/env bash
#
# Fixture helpers: build a throwaway repo of a given SHAPE, per test.
#
# Every assertion in this suite is an integration test against real git. That
# is deliberate, not laziness — every bug this suite exists to pin was a wrong
# answer from a real `git rev-list` or `git rev-parse` against a ref that did
# or did not exist. A mocked git would have happily reproduced the bug.
#
# The shapes that matter, and why each one is a shape:
#   remote default is NOT main   — the hardcoded origin/main guard passed here
#   base exists only locally     — no origin/ form to reconstruct
#   base exists both ways        — the remote must win
#   base exists nowhere          — "cannot tell" must not read as zero
#   no remote at all             — even the final fallback does not resolve

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The stub dir comes FIRST: it shadows `claude` so no test can spawn a real
# session. Pass --no-launch as well; this is the belt to that braces.
export PATH="$KIT_ROOT/tests/helpers/stub:$KIT_ROOT/bin:$PATH"
export WTKIT_LIB="$KIT_ROOT/lib/wtkit"

# Keep the developer's own git config out of the fixtures: a global
# init.defaultBranch, a commit template, or hooks would otherwise change what
# these tests measure depending on whose machine they run on.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0

_git() { git -c init.defaultBranch=develop -c user.email=t@t -c user.name=t "$@"; }

# wtk_new_tmp — a private directory for one test.
wtk_new_tmp() {
  TESTDIR="$(mktemp -d "${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/wtkit.XXXXXX")"
  # Resolve it. On macOS /tmp and /var are symlinks into /private, and git
  # reports the physical path from rev-parse --show-toplevel — so the fixture
  # guard would compare /var/... against /private/var/... and reject every
  # fixture as "outside the fixture".
  TESTDIR="$(cd "$TESTDIR" && pwd -P)"
  export TESTDIR
}

wtk_teardown() {
  # Worktrees hold no locks, so a plain rm is enough — but never let an unset
  # TESTDIR turn this into `rm -rf /`.
  [ -n "${TESTDIR:-}" ] && [ -d "$TESTDIR" ] && rm -rf "$TESTDIR"
  return 0
}

# wtk_assert_fixture — the seatbelt.
#
# Every bin/ command resolves its target from the CURRENT DIRECTORY, and bats
# runs from the kit's own checkout. A test that forgets to cd would therefore
# point remove-workspace — which force-deletes branches — at this repository.
# That is not a hypothetical: it is what the first draft of this suite did.
# Called by the fixture builders, so no test has to remember.
wtk_assert_fixture() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "FIXTURE GUARD: not inside a git repo" >&2; return 1; }
  case "$top" in
    "$TESTDIR"/*) return 0 ;;
    *) echo "FIXTURE GUARD: cwd resolves to '$top', outside the fixture at" >&2
       echo "               '$TESTDIR'. Refusing to run a destructive command" >&2
       echo "               against a real repository." >&2
       return 1 ;;
  esac
}

# wtk_mk_repo [remote_default]
#   A bare "remote" plus a clone of it. The remote's default branch is develop
#   unless told otherwise, because a repo whose default IS main cannot detect
#   a hardcoded origin/main.
#   Sets: REPO (the clone), REMOTE (the bare repo).
wtk_mk_repo() {
  local def="${1:-develop}"
  REMOTE="$TESTDIR/remote.git"
  _git init -q --bare "$REMOTE"
  _git init -q "$TESTDIR/seed"
  ( cd "$TESTDIR/seed"
    echo base > app.txt
    _git add app.txt
    _git commit -q -m init
    _git branch -M "$def"
    _git push -q "$REMOTE" "$def" ) >/dev/null
  _git -C "$REMOTE" symbolic-ref HEAD "refs/heads/$def"
  REPO="$TESTDIR/repo"
  _git clone -q "$REMOTE" "$REPO" 2>/dev/null
  _git -C "$REPO" config user.email t@t
  _git -C "$REPO" config user.name t
  _git -C "$REPO" remote set-head origin --auto >/dev/null 2>&1
  mkdir -p "$REPO/.claude"
  export REPO REMOTE
  cd "$REPO" || return 1
  wtk_assert_fixture
}

# wtk_mk_repo_no_remote — a repo with no remote at all, so even the historical
#   origin/main fallback fails to resolve.
wtk_mk_repo_no_remote() {
  REPO="$TESTDIR/solo"
  _git init -q "$REPO"
  _git -C "$REPO" config user.email t@t
  _git -C "$REPO" config user.name t
  _git -C "$REPO" commit -q --allow-empty -m init
  mkdir -p "$REPO/.claude"
  export REPO
  cd "$REPO" || return 1
  wtk_assert_fixture
}

# wtk_push_branch <name> — give the remote a branch of this name too.
wtk_push_branch() {
  _git -C "$REPO" push -q origin "$1"
  _git -C "$REPO" fetch -q origin
}

# wtk_mk_integration <name> [n_commits] — a LOCAL-only branch, left checked out.
wtk_mk_integration() {
  local name="$1" n="${2:-1}" i=0
  _git -C "$REPO" switch -qc "$name"
  # Not `seq 1 $n`: BSD seq prints "1 0" for `seq 1 0` where GNU seq prints
  # nothing, so a zero-commit fixture silently got two commits on macOS and
  # none on Linux. An explicit counter has no dialect.
  while [ "$i" -lt "$n" ]; do
    i=$(( i + 1 ))
    _git -C "$REPO" commit -q --allow-empty -m "integration $i"
  done
}

# wtk_set_base <branch> — the run-local override every tool now reads.
wtk_set_base() { _git -C "$REPO" config wtkit.baseBranch "$1"; }

wtk_conf() { printf '%s\n' "$@" > "$REPO/.claude/workspace.conf"; }

# wtk_mk_workspace <n> <base> [n_commits] — a worktree + branch off <base>.
#   Sets WS to its path.
wtk_mk_workspace() {
  local n="$1" base="$2" cnt="${3:-1}" i=0
  WS="$REPO/.claude/worktrees/workspace-$n"
  _git -C "$REPO" worktree add -q "$WS" -b "workspace/$n" "$base"
  while [ "$i" -lt "$cnt" ]; do
    i=$(( i + 1 ))
    _git -C "$WS" commit -q --allow-empty -m "agent $n work $i"
  done
  export WS
}

wtk_tip() { _git -C "${2:-$REPO}" rev-parse "$1"; }
wtk_has_branch() { _git -C "$REPO" show-ref --verify --quiet "refs/heads/$1"; }
wtk_count() { _git -C "${2:-$REPO}" log --oneline "$1" | wc -l | tr -d ' '; }
