Land this worktree's branch into the repo's **local** integration branch: merge
the base in, run the tests, then fast-forward the integration branch under a
lock. No PR, no `gh`, no VERSION bump, no forge of any kind.

**When to use:** you are running several agents at once, each in its own
worktree off a shared integration branch, and this one has finished. `/land`
advances that branch so the next `/next-task` in any other worktree starts from
the accumulated result.

**When NOT to use:** when the branch you are merging into lives on a remote and
the project ships through pull requests. That is `/ship-land`, which runs the
review and version machinery `/land` deliberately skips. `/land` is for the
integration branch *between* those two things — the one that collects several
agents' work before any of it becomes a single PR.

VERSION and CHANGELOG are untouched on purpose. They belong to the one PR the
integration branch eventually becomes, not to each agent's slice of it.

## Argument

`$ARGUMENTS` is empty, or any of:

- `--no-test` — skip `TEST_CMD`. For a project that gates elsewhere. It is not
  a way to land red code.
- `--retries N` — optimistic attempts before falling back to a locked
  merge+test+land (default 3).
- `--wait SECONDS` — how long to wait for the lock (default 1800).

## Steps

```bash
land-local $ARGUMENTS
```

That is the whole command. Print its summary back to the user.

The ordering inside it matters, and is worth knowing when you read its output:
it merges the integration branch into this one FIRST, so a conflict happens
here, in this worktree, where it can be resolved. It then tests unlocked, so
parallel agents test in parallel, and only takes the lock to check that neither
the integration branch nor the tested commit moved before fast-forwarding. The
integration branch is never touched until tests against that exact tree came
back green.

If it exits non-zero, relay the message rather than working around it. Each one
means something different:

- **Merge conflict.** It stopped and left the merge in place for you to resolve.
  Fix the conflict, commit, re-run `/land`. The integration branch was not
  touched.
- **`TEST_CMD` failed.** The integration branch was not touched. The merge is
  kept, so fix forward from the merged state rather than starting over.
- **`$INTEG` moved while testing.** Not an error — it retries, and says so.
- **Lock still held.** Another worktree is landing. It waits. Only if a session
  actually died should anyone `ship-lock acquire --steal`, and that is the
  user's call to make, never yours.
- **No local branch to land into.** The repo's base is a remote-tracking ref
  with no local counterpart. Either this should be `/ship-land`, or the base is
  pointed at the wrong place (`git config wtkit.baseBranch <branch>`).
- **No `TEST_CMD`.** The project has not said what "green" means. Ask the user
  to set it in `.claude/workspace.conf`, or to pass `--no-test` knowingly.

If `land-local` is not on PATH, the kit is not installed or is out of date
(`~/Developer/worktree-kit/install.sh`). Say so rather than hand-rolling the
merge — the lock and the ordering are the entire point of this command.

## Rules

- Never merge into the integration branch by hand as a workaround. The lock is
  what stops two agents landing at once, and a manual `git merge` does not take
  it.
- Never `--steal` the lock on the user's behalf. There is no liveness signal
  behind it; a steal that loses a race becomes a repeat stealer.
- Do not bump VERSION or write a CHANGELOG entry here, even if the project
  usually does. One bump belongs to the eventual PR, not to each agent.
- Do not push the integration branch. The user pushes it when the whole feature
  is done — that is the point at which `/ship-land`, or a manual PR, takes over.
