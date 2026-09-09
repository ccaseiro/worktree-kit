# TODOS

## Infrastructure

### WTKIT_HOME — let worktrees and config live outside `.claude/`

**What:** Thread a `WTKIT_HOME` environment variable (defaulting to `.claude`)
through the two hardcoded path constants, so worktrees and `workspace.conf` can
live somewhere that is not named after Claude.

**Why:** The kit does not actually require Claude. `wtkit_launch_claude`
degrades cleanly when the binary is absent (`lib/wtkit/common.sh`, the
`command -v claude` branch) and `--no-launch` skips it outright; worktree
creation, port allocation, `.env` generation, docker and the whole fan-in run
regardless. But every path is Claude-named and hardcoded, with no override.
Someone who would rather not advertise the toolchain, or who is not using
Claude at all, has no way to move them.

**Context:** Raised and deliberately deferred on 2026-09-08 — the workaround
already works, so this is about naming, not function. Gitignoring `.claude`
was verified to work end to end: the conf is read off disk in the main checkout
and never through git, and the slash commands install at user scope
(`install.sh` links them into `~/.claude/commands`), so a gitignored `.claude`
breaks nothing.

There are ~26 mentions of `.claude` across `bin/` and `lib/`, but only five
sites actually construct a path and need to change:

- `lib/wtkit/common.sh` — `WTKIT_CONF="$MAIN_ROOT/.claude/workspace.conf"`
- `bin/start-worktree` — `WT_ROOT="$MAIN_ROOT/.claude/worktrees"`
- `bin/new-task`, `bin/new-workspace`, `bin/remove-workspace` — the three
  `WT_DIR="$MAIN_ROOT/.claude/worktrees/…"` assignments

The rest are comments, help text, and the `~/.claude/commands` install path,
which is Claude's own directory and should stay.

Less of the configuration surface depends on `.claude/` than when this was
first raised: the base branch now lives in `git config wtkit.baseBranch`, and
the remote name in `git config wtkit.remote`.

Worth doing together with it: decide whether an existing `.claude/worktrees/`
is migrated or just left where it is, since the launchers would stop finding it.

**Effort:** S
**Priority:** P3
**Depends on:** None

### Warn once, not per process, when something is genuinely off

**What:** Give the kit a way to say something once per user-facing command
rather than once per script invocation.

**Why:** A single `/next-task` now runs several scripts, each of which loads the
conf. Any warning `wtkit_load_conf` emits is therefore printed several times for
one user action. The "base is not on the remote" case was fixed by scoping the
warning to when it is actually a surprise, but the underlying duplication is
still there for the next warning someone adds.

**Context:** Surfaced 2026-09-09 while splitting the slash commands into
scripts. The obvious approach — a marker file, or an environment variable
exported by the first process — is more machinery than the current one warning
justified, which is why it was scoped instead. Revisit if a second repeated
warning appears.

**Effort:** S
**Priority:** P4
**Depends on:** None
