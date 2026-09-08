# worktree-kit

Three commands for running several Claude Code sessions at once, each in its
own isolated git worktree and docker stack.

| Command | What it makes |
|---|---|
| `new-workspace <n>` | A **long-lived** workspace you feed many tasks through, keeping one session's context. Named, Remote-Control-enabled Claude session `<repo>-<n>`. |
| `new-task <slug>` | A **throwaway** worktree plus a fresh session, for one independent task. |
| `start-worktree [name]` | Brings an **existing** worktree's stack up and prints its URL. Idempotent — configures, starts, or just reports, depending on what it finds. |
| `remove-workspace <n>` | Tears a workspace down safely: stack `down -v` → worktree → branch. Refuses if there is uncommitted or unshipped work. |

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

The commands are generic. Everything project-specific lives in one committed
file, `<repo>/.claude/workspace.conf`, sourced as bash:

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

Two Claude Code commands ship with the kit, installed at user scope so they
work in any repo. They are the same shape as everything else here: the logic
lives in scripts, and the project's facts live in `workspace.conf`.

| Command | Does |
|---|---|
| `/next-task <desc>` | Resets the **current** worktree to a fresh branch off the base and hands off — keeping the session's context. Use it after `/ship-land`, which leaves the worktree behind. |
| `/ship-land` | Runs the project's ship skill on the current branch, then merges the PR. Serializes itself across worktrees so two runs cannot collide on `VERSION`/`CHANGELOG.md`. |

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

## Flags

```
new-workspace <n> ["first task"]   --no-docker --no-launch --tmux --no-rc --base <ref>
new-task <slug> ["prompt"]         --no-docker --no-launch --tmux --base <ref> --prefix <p>
start-worktree [name|path]         --rebuild --no-post-up --no-docker
remove-workspace <n>               --force --yes --tmux --delete-remote

wtconf <KEY> [default] | --agent | --keys
ship-lock acquire [--steal] | status | release --token <t>
ship-classify [--base <ref>]
```

Both launchers hand the **current pane** to Claude by default; `--tmux` opens
a new window instead. `--no-rc` skips Remote Control, which needs a claude.ai
login rather than an API key.

`--base` defaults to `origin/<BASE_BRANCH>` when the conf sets one, else to the
remote's own default branch (`origin/HEAD`), else to `origin/main`. Setting
`BASE_BRANCH` is the fix for a repo whose default is not `main`: without it a
worktree silently forks from a stale `origin/main`, and the same key already
tells `/ship-land` where to merge, so the two cannot drift apart.

## Requirements

macOS or Linux, bash, git, the `claude` CLI, and `lsof` for the port probe.
Docker only if a project's conf uses it. `tmux` only for `--tmux`. `gh` only
for `/ship-land`.
