Run the project's full ship workflow on the current feature branch, then merge
the resulting PR into the base branch. Designed to be run across parallel
worktrees: because it merges before returning, the next `/ship-land` reads the
freshly-merged base and gets the next version number with no collision.

Serialization is **automatic on the default merge path** — a cross-worktree
advisory lock (`ship-lock`) makes a second cooperating `/ship-land` wait for the
first instead of colliding on `VERSION`/`CHANGELOG.md`. It is advisory: it
serializes other `/ship-land` runs that respect it, not a manual merge or a
hand-edited `VERSION`.

Everything project-specific comes from `.claude/workspace.conf` via `wtconf`:
which branch to merge into, which merge method, which paths the test suite
cannot observe, which skill actually ships, and the project's version-bump rule.

Argument received: "$ARGUMENTS"

## Arguments

All optional, order-free, combinable (e.g. `/ship-land skip-tests no-merge`):

- `no-merge` / `pr-only` — stop after the ship skill, leave the PR open, do NOT merge.
- `skip-tests` — force the docs-only fast path even if step 0 classifies the diff
  as app-relevant. Recorded in the PR body.
- `full-tests` — force the full suite even if step 0 classifies the diff as
  inert. Wins over `skip-tests` if both are passed (fail-closed).
- `--steal` / `steal` — forcibly reclaim a lock you have determined is orphaned
  (a session that died mid-ship). It `rm -rf`s whatever is at the lock path and
  prints a loud warning. It does **not** verify the holder is dead — YOU are
  asserting that; using it on a live run re-arms the double-bump the lock exists
  to prevent. Only ever passed on the initial acquire.

### 0. Read the project config

```bash
eval "$(wtconf --agent)"
echo "base=$BASE_BRANCH merge=$MERGE_METHOD ship=${SHIP_SKILL:-(none)}"
echo "floor=${VERSION_BUMP_FLOOR:-(skill default)} reserved=${RESERVED_VERSION_SEGMENT:-(none)}"
echo "inert=${INERT_PATHS:-(none — tests never skipped)}"
```

If `SHIP_SKILL` is empty, **stop**: this project has not adopted a ship
workflow, so there is nothing for `/ship-land` to run. Tell the user to set
`SHIP_SKILL` in `.claude/workspace.conf` (or ship by hand).

### 1. Acquire the serial lock — before anything else

Two `/ship-land` runs in parallel worktrees both bump `VERSION`/`CHANGELOG.md`;
landed at once they collide on exactly those lines. `ship-lock` prevents that.
Its mechanics, failure modes and the reasoning behind them live in the script —
read `ship-lock --help` rather than restating them here.

The scope is the **whole command**, not a narrow critical section: the ship
skill is invoked as an opaque unit, and a whole-command scope is correct anyway
because that skill re-reads and merges the base at its own start — valid
precisely when only one ship runs at a time.

```bash
# Pass --steal ONLY on this initial attempt, and only when the user asked for
# it. Fail closed: --steal drives a destructive rm -rf, so any UNRECOGNIZED
# token disarms it — "/ship-land don't --steal" must never reach it.
# Capture the raw argument string ONCE, into a quoted heredoc. Claude Code
# splices the user's text in verbatim BEFORE the shell parses it, so a prose
# description like "corrigir o 500 (criar & guardar)" would otherwise be read
# as shell: the parentheses are a syntax error, and `backticks`, $(...), ; and
# > would RUN. A quoted delimiter makes every byte inert text.
ARGS=$(cat <<'GSTACK_EOF'
$ARGUMENTS
GSTACK_EOF
)
# zsh does not word-split unquoted parameters and bash does; the tool shell is
# not guaranteed to be either, so ask for the same behaviour explicitly.
[ -n "${ZSH_VERSION:-}" ] && setopt shwordsplit
STEAL=""; WANT=no; UNKNOWN=no
set -f
for tok in $ARGS; do
  case "$tok" in
    --steal|steal) WANT=yes ;;
    skip-tests|full-tests|no-merge|pr-only) : ;;
    *) UNKNOWN=yes ;;
  esac
done
set +f
if [ "$WANT" = yes ] && [ "$UNKNOWN" = yes ]; then
  echo "--steal IGNORED: unrecognized token(s) present — pass it alone to steal."
elif [ "$WANT" = yes ]; then STEAL="--steal"; fi
ship-lock acquire $STEAL
```

**Read the sentinel, not the vibe.**

- `ACQUIRED RUN_TOKEN=<t>` → you hold the lock. **Remember that literal token
  for the whole run** — it is your only proof of ownership and the release step
  needs it. Continue to step 2.
- `LOCK_BUSY` → you do NOT hold it. Go to Contention. Never continue.
- `LOCK_CORRUPT` / `LOCK_ERROR` / `LOCK_UNRESOLVABLE` → stop and surface it as
  the script explains. Do not poll on a corpse.

#### Contention

Poll with `ship-lock status` about every 30s. Foreground `sleep` is blocked
here, so wait with the **Monitor tool** and an until-condition, not a bash sleep
loop. Each cycle re-prints the holder and its age, so the user sees progress.

- `LOCK_FREE` → re-acquire with a plain `ship-lock acquire` (**never** `--steal`
  on a re-acquire: a human steal is a one-time act on the initial attempt, or a
  steal that loses the race becomes a repeat stealer). On `ACQUIRED`, remember
  the new token and continue. On `LOCK_BUSY`, another waiter won — resume polling.
- Still `STILL_HELD` after **~30 minutes** → **STOP and report**. Do not
  auto-steal, do not proceed:

  > Lock still held by `<worktree>` (`<branch>`) after ~30 min. If that session
  > died, run `/ship-land --steal` to reclaim it; otherwise wait for it to
  > finish and re-run `/ship-land`.

  Auto-stealing is forbidden because there is no liveness signal — no process
  holds the lock across the command, so 30 min is a heuristic for "probably
  dead", not proof. A legitimate slow ship whose lock got auto-stolen would
  double-bump `VERSION`, the exact collision the lock prevents.

### Release the lock

**Best-effort, not airtight.** This is agent-driven prose with no shell `trap`,
so a hard crash between acquire and release cannot self-release; that needs a
human `/ship-land --steal`. What it does guarantee is that on every exit path
the agent DOES reach, it releases. Run it on **every** such exit: (a) success
after the merge, (b) the ship skill halting for any reason, (c) any error or
abort, (d) the `no-merge` / `pr-only` return.

**Only release if THIS run acquired.** If this invocation went to Contention and
never acquired, you have no token — there is nothing of yours to release, so do
not run this at all.

```bash
ship-lock release --token '<the RUN_TOKEN you remembered from acquire>'
```

`RELEASED` or `ALREADY_GONE` are both fine. `TOKEN_MISMATCH` means the lock is
not yours — leave it and say so. Do not consider `/ship-land` finished, success
or not, until this has run.

### 2. Docs-only fast path — classify the diff

A test suite cannot observe a change to prose or agent tooling, so running it
there is ceremony, not coverage. `ship-classify` decides, from the project's
`INERT_PATHS`. It is an allowlist and it fails closed — a project that declares
none never skips.

Parse the flags **deterministically**, never by reading the prose. `skip-tests`
disables the suite ahead of an auto-merge, so an exact token match is the whole
gate.

```bash
# Capture the raw argument string ONCE, into a quoted heredoc. Claude Code
# splices the user's text in verbatim BEFORE the shell parses it, so a prose
# description like "corrigir o 500 (criar & guardar)" would otherwise be read
# as shell: the parentheses are a syntax error, and `backticks`, $(...), ; and
# > would RUN. A quoted delimiter makes every byte inert text.
ARGS=$(cat <<'GSTACK_EOF'
$ARGUMENTS
GSTACK_EOF
)
# zsh does not word-split unquoted parameters and bash does; the tool shell is
# not guaranteed to be either, so ask for the same behaviour explicitly.
[ -n "${ZSH_VERSION:-}" ] && setopt shwordsplit
WANT_SKIP=no; WANT_FULL=no; NO_MERGE=no; UNKNOWN=no
set -f
for tok in $ARGS; do
  case "$tok" in
    skip-tests) WANT_SKIP=yes ;;
    full-tests) WANT_FULL=yes ;;
    no-merge|pr-only) NO_MERGE=yes ;;
    --steal|steal) : ;;                 # consumed by step 1; recognized so it
                                        # never counts as UNKNOWN here
    *) echo "  unrecognized argument: $tok"; UNKNOWN=yes ;;
  esac
done
# A stray word next to a destructive flag is likelier a negation ("don't
# skip-tests") than noise, and word splitting cannot tell them apart. Refuse
# the skip rather than guess.
if [ "$UNKNOWN" = yes ] && [ "$WANT_SKIP" = yes ]; then
  echo "  skip-tests IGNORED: unrecognized tokens present — pass it alone to skip"
  WANT_SKIP=no
fi
set +f
echo "ARGS: skip=$WANT_SKIP full=$WANT_FULL no_merge=$NO_MERGE"
ship-classify
```

Resolve, honoring the arguments:

- `full-tests` → **run the suite**, whatever the classification.
- `skip-tests` → **skip**, and note the manual override in the PR body.
- else `INERT_DIFF: yes` → **skip**.
- else → **run the suite**.

When skipping, print one line so it is never silent:
`Tests skipped: docs-only diff (N files, all inert). Review steps still run.`

Then carry the decision into step 3: tell the ship skill its test steps are
pre-cleared, and record `Tests: skipped (docs-only diff)` in the PR body.
**Every other step still runs** — the pre-landing review is the only coverage a
docs-only diff gets, and it is exactly what catches defects in tooling changes.
Never skip it. If the fast path was taken and the ship skill later applies a fix
during review, re-run `ship-classify` against the new diff before continuing.

### 3. Ship

Invoke `SHIP_SKILL` and let it run to completion (merge base → tests → review →
version bump → changelog → push → PR). Respect every one of its stop
conditions. If it halts for ANY reason — red tests, unresolved review items, a
version collision, a bump-level question, or it applied fixes and asked to
re-run — then **run the Release block, then STOP and report.** Never merge a
branch whose ship did not finish green, and never leave the lock held after
halting: that deadlocks every other worktree until the 30-min threshold.

**Version bump — project rule.** When `VERSION_BUMP_FLOOR` is set, it is the
**floor** for a normal ship: if the ship skill would auto-pick a lower segment,
pick the floor instead. When `RESERVED_VERSION_SEGMENT` is set, `/ship-land`
must **never** land a bump of that segment — it is reserved for out-of-band
hotfixes branched from a deployed tag. Both default to unset, in which case the
ship skill's own choice stands.

### 4. Merge decision

Only reached when the ship finished green with an open PR.

- `no-merge` / `pr-only` → **run the Release block**, report the PR URL, do NOT
  merge, then print this warning verbatim (with the PR number):

  > WARNING: the ship bumped VERSION/CHANGELOG on this branch but did NOT merge,
  > and the serial lock is now released. Any other `/ship-land` started before
  > you merge this PR will read the SAME base and pick the SAME next version — a
  > collision at merge time. Merge PR #<n> promptly, or expect to resolve that
  > conflict by hand.

  The lock is released rather than held because `no-merge` is an open-ended
  manual opt-out; holding it would deadlock every other worktree. `no-merge`
  therefore does NOT carry the serialization guarantee — the warning hands
  ordering back to the human.
- Otherwise (default) → `gh pr merge <PR#> $MERGE_METHOD`. Do NOT pass
  `--delete-branch`: the feature's worktree may still be checked out on it.

### 5. Fast-forward the base branch's working tree

Only after a successful default merge. `/ship-land` runs from a feature
worktree, so the base branch is checked out in a *different* working tree — you
cannot `git checkout` it from here.

- `git fetch origin "$BASE_BRANCH"` to pick up the merge commit.
- Find the working tree holding it: `git worktree list --porcelain`, the entry
  whose `branch` is `refs/heads/$BASE_BRANCH`.
- If found: `git -C <that-path> merge --ff-only "origin/$BASE_BRANCH"`. Safe —
  the merge commit is a strict descendant, so it can only fast-forward. If it
  fails (the base tree has diverged or has local commits), do NOT force it:
  report that it needs a manual `git pull` and continue.
- If the base is not checked out anywhere: `git fetch origin "$BASE_BRANCH:$BASE_BRANCH"`.
- Leave untracked and ignored files in the base tree untouched.

### 6. Release the lock, then report

Run the Release block (the merge is done, so the next waiter may proceed). Then
report the merged PR, the new base HEAD, the version now on the base, and
whether the base working tree was fast-forwarded. State clearly that this did
**not** deploy.

**On any error or abort not covered above** — a `gh`/`git` failure mid-run, an
unexpected exception, a manual stop — run the Release block before you finish,
so a crash never leaves the lock held.

## Notes

- Serialization is automatic on the **default** path only. `/ship-land no-merge`,
  a manual merge, and a hand-edited `VERSION` are NOT covered — land those in
  series by hand.
- The fast path skips ONLY the app test suite. Review, version bump, changelog
  and merge all run unchanged.
- This does NOT deploy and does NOT remove the feature's worktree.
- Keep the base checkout pristine — never commit on it directly. A stray local
  commit there breaks step 5's fast-forward and forces a manual `git pull`.
