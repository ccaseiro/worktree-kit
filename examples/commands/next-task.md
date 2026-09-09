Start a NEW task in the **current worktree and Claude session** — keeping this
session's context — after the previous task has been shipped. It resets the
worktree to a fresh branch off the latest base, then hands off. No new session,
no lost context.

**When to use:** you finished a task with `/ship-land` (which leaves the
worktree behind) and want to start the next one WITHOUT losing this
conversation's context. Ideal inside a long-lived workspace from
`new-workspace`. For **independent / parallel** tasks with a throwaway worktree
and session, use `new-task` instead. Never commit new work on the just-merged
branch — this command branches off the latest base for you.

Everything project-specific comes from `.claude/workspace.conf`, read through
`wtconf`. A repo with no conf still works: it gets the branch reset, and the
docker and menu layers are skipped.

## Argument

`$ARGUMENTS` is the new task description (a sentence or two), plus optional
tokens anywhere in the string:

- `slug=<kebab-slug>` — force the branch slug (otherwise derived from the description).
- `via=<skill>` — after prepping the branch, route the task through a skill
  instead of choosing interactively (a leading slash is fine: `via=/feat`).
- `/<skill>` — shorthand for `via=<skill>`. Accepted **only** when all hold: it
  is the leading token, it is a bare name with no embedded or trailing slash, it
  is listed in the project's `TASK_ENTRY_SKILLS`, and no explicit `via=` appears
  anywhere in the arguments (order-independent — a trailing `via=` wins, and the
  shorthand token then stays in the description). Anything failing those stays
  **plain description**, token intact — so `fix the /opt/foo path`,
  `/reports/create/ 500 on save` and `/deploy fails on staging` all keep their
  text and route nowhere.
- `--fresh` — after resetting the branch, DON'T carry the previous task's
  conversation into the new one. A slash command cannot wipe its own context
  window, so this stops after prep and asks you to run the built-in `/clear`
  (step 5A).
- `--fresh-db` — recreate the worktree's database from scratch instead of just
  running the conf's `post_up` (step 4B).

`/next-task` does NOT dive straight into implementation. It preps the branch,
then either routes to the `via=` skill or presents the entry-point choice.

## Steps

### 1. Read the project config, parse the flags, refuse if unsafe

Both halves of this run as scripts. The parsing is security-sensitive and the
guard stands in front of a `git branch -D`; neither belongs in prose that gets
re-read and re-interpreted on every invocation. `make test` covers both.

```bash
eval "$(wtconf --agent)"   # REMOTE_NAME, BASE_REF, BASE_BRANCH, TASK_ENTRY_SKILLS, …

# The heredoc stays HERE because $ARGUMENTS is spliced in by Claude Code before
# any shell sees it — a quoted delimiter is what makes those bytes inert text
# rather than shell. next-task-args reads them on stdin and never re-expands.
eval "$(next-task-args <<'GSTACK_EOF'
$ARGUMENTS
GSTACK_EOF
)"                          # -> FRESH, FRESH_DB, SLUG, VIA, DESC

next-task-preflight         # -> report; exits non-zero on any stop condition
```

- `next-task-preflight` exiting non-zero → **stop** and show its message
  verbatim. It has already checked all four conditions: run from the main
  checkout, uncommitted changes, a base it cannot resolve (unknown is not
  zero — step 3 force-deletes this branch), and commits not yet landed.
- Otherwise continue. `FRESH`, `FRESH_DB`, `SLUG`, `VIA` and `DESC` are set.

### 2. Derive the new slug and branch

- Use `SLUG` if `slug=` set it; otherwise derive a short kebab-case slug from
  `DESC` (e.g. "add CSV export to the report list" → `report-list-csv-export`).
- Validate it against `^[a-z0-9]+(-[a-z0-9]+)*$`. The new branch is `feature/<slug>`.
- If `feature/<slug>` already exists (`git show-ref --verify --quiet refs/heads/feature/<slug>`), pick another slug or ask.

### 3. Reset to a fresh branch off the latest base

```bash
next-task-reset "$SLUG"
```

`next-task-reset` re-runs the whole preflight itself before touching anything,
so the check and the force-delete cannot drift apart. It validates the slug,
refuses a branch name that already exists, creates `feature/<slug>` off the
resolved base, and deletes the old branch — which the preflight has just
proved is fully landed.

### 4. Catch the worktree's runtime up to the new base

The stack is still running on the same ports, but it was set up for the OLD
base. `start-worktree` is the one idempotent path that converges it — it runs
the conf's `post_up` on **every** start, not just the first, which is exactly
what applies new migrations after the branch moves.

**4A — default:**

```bash
# Rebuild only when the base moved a path the project flagged as image-affecting
# (REBUILD_TRIGGER_PATHS, e.g. "requirements.txt Dockerfile"). HEAD@{1} is the
# previous branch tip, before step 3's switch. Globbing stays off: these are
# git pathspecs, not paths to expand against the cwd.
set -f
REBUILD=""
for pat in $REBUILD_TRIGGER_PATHS; do
  git diff --quiet 'HEAD@{1}' HEAD -- "$pat" 2>/dev/null || { REBUILD="--rebuild"; break; }
done
set +f
[ -n "$REBUILD" ] && echo "Image-affecting path changed since the last task — rebuilding."
start-worktree $REBUILD
```

**4B — when `--fresh-db` was passed:** wipe the accumulated test data first,
then converge as usual. Run this INSTEAD of 4A.

```bash
# The [ -f ] guard is not optional: run from a worktree whose compose file is
# gone, Compose walks UP to the parent project and `down -v` can wipe the MAIN
# stack's volumes.
[ -f docker-compose.yml ] && docker compose down -v
start-worktree --rebuild
```

If `start-worktree` is not on PATH the kit is not installed — say so rather than
hand-rolling `docker compose`; the whole point is that this logic lives in one
place. If the project has no conf or no compose file, `start-worktree` reports
that and does nothing, which is the correct outcome — note it and move on.

### 5. Hand off — pick the entry point (do NOT auto-implement)

First re-read the repo's `CLAUDE.md` (if it has one) and follow its
conventions. Then, in priority order:

**5A — `--fresh` was passed:** do NOT proceed. A slash command cannot clear its
own context window; only the built-in `/clear` can. Stop and say, verbatim:

> Branch `feature/<slug>` is ready on a clean stack (worktree `$HERE`). For a
> fresh context, run `/clear` now, then describe the task — the branch is
> already set, no need to re-run `/next-task`.

Then wait.

**5B — `via=<skill>` was passed:** announce "Branch `feature/<slug>` ready —
routing to /`<VIA>`", then invoke that skill with `<DESC>` as its arguments and
continue with that skill's workflow.

**5C — default:** do NOT start implementing on your own. Announce that the
branch is ready and hold the task:

> Branch `feature/<slug>` is ready (worktree `$HERE`). Task: `<DESC>`. How do
> you want to tackle it? Reply **go** to implement it directly, or route it
> through one of: `<TASK_ENTRY_SKILLS, rendered as /name with a short gloss
> each>`. You can also just tell me the first step.

When `TASK_ENTRY_SKILLS` is empty, offer only **go** or "tell me the first
step" — never invent skill names to fill the menu. Then wait. On **go** or
direct instructions, implement in logical commits; on a skill name, invoke it
with the task. Finish with `/ship-land`.

## Rules

- **Only for the sequential, same-session flow.** Independent parallel tasks use
  `new-task`; long-lived workspaces come from `new-workspace`.
- **Never silently discards work:** refuses when the worktree is dirty or has
  commits not yet on the base.
- **Never reuses the merged branch** for new commits — always branches off the
  latest base.
- Keeps the same worktree directory and stack (ports unchanged); `--fresh-db`
  recreates the database, otherwise `start-worktree` just converges it.
- Deletes the previous (already-merged) branch — safe because step 1 verified it
  has no unshipped commits.
- **Never auto-dives into implementation.** After prepping it routes to `via=`,
  or presents the choice and waits.
