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

It symlinks `bin/*` into `~/.local/bin` and `lib/wtkit` into `~/.local/lib`,
so `git pull` here updates every project at once. Make sure `~/.local/bin` is
on your `PATH`. Undo with `./install.sh --uninstall`.

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

## Flags

```
new-workspace <n> ["first task"]   --no-docker --no-launch --tmux --no-rc --base <ref>
new-task <slug> ["prompt"]         --no-docker --no-launch --tmux --base <ref> --prefix <p>
start-worktree [name|path]         --rebuild --no-post-up --no-docker
remove-workspace <n>               --force --yes --tmux --delete-remote
```

Both launchers hand the **current pane** to Claude by default; `--tmux` opens
a new window instead. `--no-rc` skips Remote Control, which needs a claude.ai
login rather than an API key.

## Requirements

macOS or Linux, bash, git, the `claude` CLI, and `lsof` for the port probe.
Docker only if a project's conf uses it. `tmux` only for `--tmux`.
