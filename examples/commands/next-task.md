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

```bash
eval "$(wtconf --agent)"   # BASE_BRANCH, TASK_ENTRY_SKILLS, REBUILD_TRIGGER_PATHS, …

# The bare-/skill shorthand may route ONLY to a name the project listed in
# TASK_ENTRY_SKILLS. Empty (the default) means the shorthand never routes, so
# an unconfigured repo can never fire a command that does not exist. Keep
# destructive names (deploy, rollback, push, ship*) OUT of that key: a bug
# report often starts with one ("/deploy fails on staging").
VIA_OK=" $TASK_ENTRY_SKILLS "

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

FRESH=no; FRESH_DB=no; SLUG=""; VIA=""; DESC=""
set -f   # no globbing: "/opt/*" in a description must stay literal

# Pre-scan for an explicit via= FIRST, so the shorthand's "no explicit via= was
# given" rule holds regardless of token order. VIA_SEEN is tracked separately
# from the value: a bare "via=" must still suppress the shorthand, or an empty
# value would read as "no via= given".
VIA_SEEN=no; VIA_EXPLICIT=""
for tok in $ARGS; do
  case "$tok" in via=*) VIA_SEEN=yes; VIA_EXPLICIT="${tok#via=}"; VIA_EXPLICIT="${VIA_EXPLICIT#/}" ;; esac
done

for tok in $ARGS; do
  case "$tok" in
    --fresh) FRESH=yes ;;
    --fresh-db) FRESH_DB=yes ;;
    slug=*) SLUG="${tok#slug=}" ;;
    via=*) ;;                          # already captured by the pre-scan
    /*) _c="${tok#/}"; _ok=no
        case "$_c" in
          *[!a-z0-9-]*) ;;             # defense in depth: bare skill names only
          *) case "$VIA_OK" in
               *" $_c "*) [ -z "$DESC" ] && [ "$VIA_SEEN" = no ] && _ok=yes ;;
             esac ;;
        esac
        if [ "$_ok" = yes ]; then VIA="$_c"; else DESC="$DESC $tok"; fi ;;
    *) DESC="$DESC $tok" ;;
  esac
done
[ -n "$VIA_EXPLICIT" ] && VIA="$VIA_EXPLICIT"   # explicit always wins
set +f
DESC="${DESC# }"

MAIN_ROOT=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
HERE=$(git rev-parse --show-toplevel)
OLD_BR=$(git branch --show-current)
DIRTY=$(git status --porcelain | wc -l | tr -d ' ')
git fetch origin "$BASE_BRANCH" 2>&1 | tail -1
UNSHIPPED=$(git rev-list --count "origin/$BASE_BRANCH..HEAD" 2>/dev/null || echo 0)
echo "Worktree: $HERE"
echo "Base:     origin/$BASE_BRANCH"
echo "Branch:   $OLD_BR | dirty: $DIRTY | unshipped: $UNSHIPPED | fresh: $FRESH | fresh-db: $FRESH_DB"
echo "Entry:    ${TASK_ENTRY_SKILLS:-(none configured)}"
```

- `HERE` == `MAIN_ROOT` → **stop**: "Run this from inside a task worktree, not the main checkout."
- `DIRTY` > 0 → **stop**: "You have uncommitted changes. Commit, stash, or discard them first." (Never silently discard work.)
- `UNSHIPPED` > 0 → **stop**: "This branch has `$UNSHIPPED` commit(s) not on `origin/$BASE_BRANCH`. Ship it first (`/ship-land`) or you'll lose them." This is the key guard: only reset once the previous task is actually landed.

### 2. Derive the new slug and branch

- Use `SLUG` if `slug=` set it; otherwise derive a short kebab-case slug from
  `DESC` (e.g. "add CSV export to the report list" → `report-list-csv-export`).
- Validate it against `^[a-z0-9]+(-[a-z0-9]+)*$`. The new branch is `feature/<slug>`.
- If `feature/<slug>` already exists (`git show-ref --verify --quiet refs/heads/feature/<slug>`), pick another slug or ask.

### 3. Reset to a fresh branch off the latest base

```bash
git switch -c "feature/$SLUG" "origin/$BASE_BRANCH"
# The previous branch is already merged (UNSHIPPED == 0) — delete it to keep
# the worktree tidy.
git branch -D "$OLD_BR" 2>/dev/null || true
git branch --show-current
```

**Verify the switch actually landed.** If `git switch` reports an error (a
tracking-config failure is the one seen in the wild), the branch ref can be
created and the index updated while HEAD stays behind — the worktree then looks
dirty with the base's own changes staged. Re-run `git switch feature/<slug>` to
complete it, and confirm `git status --porcelain` is empty before continuing.
Do NOT discard anything to "clean up" that state.

The worktree directory keeps its name (in a workspace it stays
`workspace-<n>`) — cosmetic, and deliberately so: the compose project name,
ports and stack are unchanged, so nothing needs rebuilding.

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
