# worktree-kit

Three commands for running several Claude Code sessions at once, each in its
own isolated git worktree and docker stack.

| Command | What it makes |
|---|---|
| `new-workspace <n>` | A **long-lived** workspace you feed many tasks through, keeping one session's context. Named, Remote-Control-enabled Claude session `<repo>-<n>`. |
| `new-task <slug>` | A **throwaway** worktree plus a fresh session, for one independent task. |
| `start-worktree [name]` | Brings an **existing** worktree's stack up and prints its URL. Idempotent — configures, starts, or just reports, depending on what it finds. |
| `remove-workspace <n>` | Tears a workspace down safely: stack `down -v` → worktree → branch. Refuses if there is uncommitted or unshipped work. |
| `land-local` | Merges the current worktree's branch into the repo's **local** integration branch: merge, test, then fast-forward under a lock. No PR, no `gh`, no VERSION bump. |

Worktrees live under `<repo>/.claude/worktrees/<name>`, each with its own
`COMPOSE_PROJECT_NAME`, database and collision-checked ports, so parallel
stacks never touch each other.

## Install

```bash
git clone https://github.com/ccaseiro/worktree-kit ~/Developer/worktree-kit
~/Developer/worktree-kit/install.sh
```

It symlinks `bin/*` into `~/.local/bin`, `lib/wtkit` into `~/.local/lib`, and
`examples/commands/*.md` into `~/.claude/commands` (user scope, so they work in
every project), so `git pull` here updates everything at once. Make sure
`~/.local/bin` is on your `PATH`. Skip the slash commands with
`./install.sh --no-commands`; undo everything with `./install.sh --uninstall`.

A slash command that is already a *real file* in `~/.claude/commands` is never
clobbered — the installer says it skipped it and leaves your version alone.

## Per-project setup

The commands are generic. Everything project-specific lives in
`<repo>/.claude/workspace.conf`, sourced as bash:

```bash
PROJECT_SLUG="my_app"            # docker project + database name prefix
WORKSPACE_WEB_BASE=8500          # workspace <n> -> web 8500+n
WORKSPACE_DB_BASE=5900
TASK_WEB_BASE=8100               # task worktrees
TASK_DB_BASE=5500
TASK_PORT_SPAN=400               # width of the task band (default 400 when pinned)
WORKSPACE_PORT_SPAN=200
BASE_BRANCH="develop"            # branch worktrees fork from and PRs land on
INHERIT_ENV_KEYS="OPENAI_API_KEY ANTHROPIC_API_KEY"
WORKSPACE_INITIAL_PROMPT_FMT="/next-task %s"
FINISH_HINT="Finish with /ship-land or /ship-worktree."

write_env() {                    # body of each worktree's .env
  cat <<INNER
COMPOSE_PROJECT_NAME=$PROJ
WEB_PORT=$WEB_PORT
DB_PORT=$DB_PORT
POSTGRES_DB=$DBNAME
INNER
}

post_up() {                      # run after `docker compose up`, retried
  docker compose exec -T web python manage.py migrate
}
```

`examples/workspace.conf.django` is a working Django + Postgres config.

Every key is optional:

- **No `workspace.conf` at all** — you still get the worktree and a launched
  Claude session; the `.env` and docker layer is skipped.
- **No port bases** — a 20-port window is derived from a hash of the repo
  name, workspaces in the low half and task worktrees in the high half, so
  workspace 1 of two different projects never claims the same pair. Pin them
  explicitly when a project's ports are already documented elsewhere.
- **No spans** — a band you pin owns a wide range (400 ports for tasks, 200 for
  workspaces); a hash-derived window is only as wide as the window. A task's
  offset is `hash(slug) % TASK_PORT_SPAN`, so the span sets how often two
  concurrent task worktrees want the same pair. The host probe resolves an
  actual clash either way; the span decides how often it has to.
- **No hooks** — `write_env` defaults to compose project name plus ports, and
  nothing runs after `up`.

Secrets never travel in the repo: `INHERIT_ENV_KEYS` names keys copied from
each developer's own main-checkout `.env` into the worktree's.

The conf is read from the main checkout, falling back to the current worktree
when the main checkout has none — so a branch that adds or edits it takes
effect before it lands.

### Where configuration lives

Two places, deliberately:

- **`<repo>/.claude/workspace.conf`** — the project's durable settings: slug,
  port bands, inherited env keys, the default base. Commit it if your team uses
  the kit. Nothing requires you to: the launchers read it off disk in the main
  checkout, never through git, so it works fine gitignored — which is what you
  want if you would rather not advertise the toolchain. The slash commands are
  installed at user scope, so they keep working either way.
- **`git config wtkit.baseBranch`** — the base for *right now*. An integration
  branch that several worktrees fan into is a this-clone, this-week choice, not
  a project setting; committing its name would put a branch that dies next week
  into a PR and hand a fresh clone a base that no longer exists. It lives in the
  shared common git dir, so every worktree of the repo reads the same value.

```bash
git config wtkit.baseBranch feat/something   # start a fan-in
git config --unset wtkit.baseBranch          # back to the project default
```

When you set it explicitly the kit stays quiet about the base not being on the
remote — that is the whole point of the key. A `BASE_BRANCH` in the conf that
the remote does not have still warns, because that one is usually a typo.

`git config wtkit.remote` overrides the remote name the same way, for a repo
whose remote is not called `origin`.

## Reopening a worktree

`new-workspace` and `new-task` create a worktree and start it. `start-worktree`
is for one that already exists — you came back the next day, or an agent left a
worktree behind that was never configured at all:

```bash
start-worktree              # the one you are standing in
start-worktree workspace-2  # or by name / path
```

It converges to "running" from whatever state it finds, so there is only one
command to remember rather than one per case:

| Found | Does |
|---|---|
| no `.env` | allocates ports, writes `.env`, builds, starts |
| `.env`, never started | starts (compose builds the image if it is missing) |
| stopped | starts |
| already running | nothing — prints the URL |

A worktree with no `.env` gets the same identity its launcher would have given
it, derived from the directory name: `workspace-<n>` lands in the workspace
band, anything else in the task band. Once an `.env` exists it is the source of
truth and the ports are never silently reallocated — a port held by a *foreign*
process is reported, not routed around.

`post_up` runs on every start, not just the first, which is what picks up
migrations after the branch moves.

`examples/commands/open-worktree.md` is a matching Claude Code slash command —
a thin wrapper, so the logic stays in one place instead of being restated in
prose that drifts.

## Slash commands

Four Claude Code commands ship with the kit, installed at user scope so they
work in any repo. They are the same shape as everything else here: the logic
lives in scripts, and the project's facts live in `workspace.conf`.

| Command | Does |
|---|---|
| `/next-task <desc>` | Resets the **current** worktree to a fresh branch off the base and hands off — keeping the session's context. Use it after landing, which leaves the worktree behind. |
| `/land` | Merges this worktree's branch into the repo's **local** integration branch: merge, test, then fast-forward under the lock. No PR, no `gh`, no VERSION bump. |
| `/ship-land` | Runs the project's ship skill on the current branch, then merges the PR. Serializes itself across worktrees so two runs cannot collide on `VERSION`/`CHANGELOG.md`. |
| `/open-worktree` | Brings an existing worktree's stack up and prints its URL. |

**`/land` or `/ship-land`?** They are two ends of the same feature.
`/land` merges one agent's work into an integration branch that lives only on
this machine — no version bump, no PR, because those belong to the feature as a
whole rather than to each agent's slice of it. `/ship-land` takes that whole
branch to the remote through the project's ship skill. Reaching for
`/ship-land` while the base is local stops early and points you at `/land`,
rather than failing minutes later inside `gh`.

They lean on three helpers you can also run by hand:

- **`wtconf`** reads one `workspace.conf` key with the defaults the commands
  expect. `wtconf --agent` prints the whole agent-facing key set, shell-quoted
  for `eval`.
- **`ship-lock`** is the cross-worktree advisory lock. It lives in the repo's
  *common* git dir, so every worktree of that repo sees the same lock and no
  other project is affected. `ship-lock --help` documents the sentinels and the
  accepted failure modes; `ship-lock status` shows the current holder and age.
- **`ship-classify`** decides whether a branch's diff is provably inert to the
  app, i.e. whether the test suite can be skipped. It is an allowlist driven by
  `INERT_PATHS` and it fails closed: no `INERT_PATHS`, an unresolvable base, an
  empty diff, or one unrecognized path all mean "run the suite".

### Keys the commands read

Every one is optional, and every default fails safe.

| Key | Default | Used by |
|---|---|---|
| `BASE_BRANCH` | `origin/HEAD`, else `main` | both, **and both launchers** — `new-workspace`/`new-task` branch new worktrees from `origin/<BASE_BRANCH>` |
| `MERGE_METHOD` | `--merge` | `/ship-land` |
| `SHIP_SKILL` | `/ship` | `/ship-land` — empty makes it refuse rather than guess |
| `INERT_PATHS` | *(none)* | `/ship-land` — none means the suite always runs |
| `VERSION_BUMP_FLOOR` | *(none)* | `/ship-land` — lowest segment a normal ship may bump |
| `RESERVED_VERSION_SEGMENT` | *(none)* | `/ship-land` — a segment it must never land (hotfix lane) |
| `TASK_ENTRY_SKILLS` | *(none)* | `/next-task` — the entry menu, and the only `/skill` shorthands it will route |
| `REBUILD_TRIGGER_PATHS` | *(none)* | `/next-task` — paths whose change means rebuild, not just restart |
| `DELETE_REMOTE_ON_RESET` | `0` | `/next-task` — also delete `<remote>/<old-branch>` on reset, once proven landed |

**`DELETE_REMOTE_ON_RESET` deletes a second ref, so it proves a second thing.**
The preflight counts `base..HEAD`: it establishes that the branch you are
standing on has landed, and nothing about the remote branch of the same name,
which can carry commits this worktree never fetched — a review fix committed in
the web UI, a push from another machine. So the remote ref is fetched and
checked on its own, and the delete carries the tip it checked as a lease. It
fails closed on the branch and open on the command: unlanded, unfetchable,
already gone or rejected all print a line and leave the branch standing, and
none of them fails the reset that has already happened. `next-task-reset --delete-remote` / `--keep-remote` override the key for
one run.

Enabling it is not the same as the forge deleting merged branches for you
(GitHub's *Automatically delete head branches*). That fires at merge and covers
every route in — a PR merged in the browser, `/ship-land no-merge`, a worktree
torn down with `remove-workspace` instead of reused. This key covers the
`/ship-land` → `/next-task` loop only. They compose: with the forge setting on,
the branch is already gone and this reports exactly that.

### Does this need gstack?

`/next-task` does not: it is git plus the conf, and works in any repo.

`/ship-land` needs *a* ship skill, named by `SHIP_SKILL`. The default `/ship`
is [gstack](https://github.com/gstack)'s, which is language-agnostic — it
detects the test command and accepts either a 4-digit or a plain-semver
`VERSION` — but it does require the repo to adopt `VERSION`, `CHANGELOG.md` and
a `gh` PR flow. A project that has not adopted a ship workflow should leave
`SHIP_SKILL` empty; `/ship-land` then stops and says so instead of invoking a
command that is not there.

The lock and the classifier have no such dependency — they are useful under any
ship workflow, including a hand-rolled one.

### The commands are thin wrappers

`/next-task` and `/ship-land` used to carry their argument parsing and their
safety guards as shell embedded in markdown. That shell could not be tested,
and it was re-read and re-interpreted on every invocation — for logic that
decides whether a `git branch -D` runs, and whether `--steal` reaches an
`rm -rf`. Both now call scripts:

| Script | What it owns |
|---|---|
| `next-task-args` | parses `/next-task`'s argument string (stdin, never argv) |
| `next-task-preflight` | the four stop conditions before a worktree is reset |
| `next-task-reset` | the reset itself — re-runs the preflight before acting |
| `ship-land-args` | parses `/ship-land`'s arguments, fail-closed around `--steal` |

The heredoc that captures `$ARGUMENTS` stays in the markdown, because Claude
Code splices the user's text in before any shell sees it and a quoted delimiter
is what makes those bytes inert. Everything after that is a script, and
`make test` covers it.

## Flags

```
new-workspace <n> ["first task"]   --no-docker --no-launch --tmux --no-rc --base <ref>
new-task <slug> ["prompt"]         --no-docker --no-launch --base <ref> --prefix <p>
start-worktree [name|path]         --rebuild --no-post-up --no-docker
remove-workspace <n>               --force --yes --tmux --delete-remote

wtconf <KEY> [default] | --agent | --keys
ship-lock acquire [--steal] | status | release --token <t>
ship-classify [--base <ref>]
```

Both launchers hand the **current pane** to Claude; `new-workspace --tmux`
opens a new window instead (`new-task` always uses the current pane).
`--no-rc` skips Remote Control, which needs a claude.ai login rather than an
API key.

`--base` defaults to `origin/<BASE_BRANCH>` when the conf sets one, else to the
remote's own default branch (`origin/HEAD`), else to `origin/main`. Setting
`BASE_BRANCH` is the fix for a repo whose default is not `main`: without it a
worktree silently forks from a stale `origin/main`, and the same key already
tells `/ship-land` where to merge, so the two cannot drift apart.

## Tests

```bash
make bootstrap   # once — clones bats-core into tests/vendor/ (gitignored)
make test
```

`make bootstrap` is a no-op if you already have `bats` on your `PATH`; nothing
is vendored into the repo and nothing needs root. Every test builds a real
throwaway repo — a bare remote, a clone whose default branch is *not* `main`,
local-only branches, worktrees — because every bug this suite pins was a wrong
answer from real `git` against a ref that did or did not exist.

Two safety rails, both learned the hard way while writing it. The fixture
builders `cd` into the fixture and assert they got there, because the `bin/`
commands resolve their target from the current directory and `bats` runs from
this checkout — a test that forgot to `cd` would point `remove-workspace`, which
force-deletes branches, at your own repo. And `tests/helpers/stub/claude`
shadows the real CLI for the whole suite, so no test can spawn a session.

Tests named `REGRESSION:` pin behaviour that was broken, shipped, and fixed.
Check they still bite: reintroduce the bug and confirm those tests, and only
those, go red.

## Requirements

macOS or Linux, bash, git, the `claude` CLI, and `lsof` for the port probe.
Docker only if a project's conf uses it. `tmux` only for `--tmux`. `gh` only
for `/ship-land`.
