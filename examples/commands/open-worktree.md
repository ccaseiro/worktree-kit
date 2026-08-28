Start an existing git worktree's stack and give the user a URL to open in a
browser, without disturbing whatever is running on `main`.

Use it when the user wants to *see* a branch running — "let me test this",
"open it in the browser", "is the worktree up?". It does not run the test
suite; it brings up the app.

## Argument

`$ARGUMENTS` is a worktree name (`workspace-2`, `agent-a84686f1`), a path, or
empty. Empty means the worktree the session is standing in, falling back to the
most recently modified one.

Pass through, if the user asked for them:

- `--rebuild` — after a Dockerfile or dependency change.
- `--no-post-up` — skip migrations/seeding, just start the containers.

## Steps

```bash
start-worktree $ARGUMENTS
```

That is the whole command. It is idempotent: it writes the `.env` if there is
none, allocates ports, starts what is stopped, and does nothing but report when
the stack is already running. Print its summary back to the user, and lead with
the App URL.

If it exits non-zero, relay the error rather than working around it. The two
it raises on purpose:

- **Port in use by another process.** The worktree's `.env` is the source of
  truth for its ports, so they are never silently reallocated. The user frees
  the port or edits that file.
- **Worktree not found.** It lists the ones that exist; ask which was meant.

If `start-worktree` is not on PATH, the kit is not installed
(`~/Developer/worktree-kit/install.sh`). Say so instead of hand-rolling
`docker compose` — the whole point of this command is that the setup logic
lives in one place.

## Rules

- Never run `docker compose` from the main checkout in this flow. Mixing
  project names is what causes container collisions.
- Never apply migrations to main's database. `start-worktree` runs the conf's
  `post_up` against the worktree's own stack, which is a different compose
  project and a different database.
- Do not offer to tear the stack down unless asked; other sessions may be using
  their own worktrees, and stopping the wrong one is invisible until it bites.
