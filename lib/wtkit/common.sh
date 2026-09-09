#!/usr/bin/env bash
#
# wtkit/common.sh — shared helpers for new-workspace / new-task / remove-workspace.
# Sourced, never executed.
#
# Everything project-specific comes from the repo's .claude/workspace.conf.
# With no conf file the kit still works: it creates the worktree and launches
# Claude, and skips the .env / docker layer entirely.
#
# Hooks a conf may define:
#   write_env()   — echo the body of the per-worktree .env on stdout.
#                   PROJ, DBNAME, WEB_PORT, DB_PORT, WT_DIR, MAIN_ROOT are set.
#   post_up()     — run inside the worktree after `docker compose up`, retried
#                   until it succeeds (migrations, seeding, …).
#
# Flags a caller may set (all default to 0):
#   NO_DOCKER     — write the .env but never touch the stack.
#   NO_POST_UP    — bring the stack up but skip the post_up hook.
#   REBUILD       — pass --build to `docker compose up` (force an image rebuild).

# ---- small utilities --------------------------------------------------------
wtkit_hash() { printf '%s' "$1" | cksum | cut -d' ' -f1; }

wtkit_slugify() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '_' \
    | sed 's/__*/_/g; s/^_//; s/_$//'
}

# The first entry of `git worktree list` is the primary working tree. All
# worktrees live under <main>/.claude/worktrees/, and the main checkout is the
# only place the real .env (with API keys) lives.
wtkit_main_root() {
  local root
  root=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')
  [ -n "$root" ] || { echo "Not inside a git repository." >&2; return 1; }
  printf '%s' "$root"
}

# wtkit_resolve_remote <root>
#   Which remote this repo talks to. "origin" is a convention, not a rule, and
#   a repo cloned with `git clone -o upstream` — or an AWS CodeCommit / Gerrit
#   checkout set up by hand — has never had one.
#
#   Order: git config wtkit.remote, then REMOTE_NAME from the conf, then the
#   sole remote if there is exactly one and it is not called origin, then
#   origin. The sole-remote step cannot change behaviour for anyone who has an
#   origin; it only rescues the repo that would otherwise measure everything
#   against a remote that does not exist.
wtkit_resolve_remote() {
  local root="${1:-.}" want n real
  want=$(git -C "$root" config --get wtkit.remote 2>/dev/null) || want=""
  [ -n "$want" ] || want="${REMOTE_NAME:-}"
  if [ -n "$want" ]; then printf '%s' "$want"; return 0; fi
  # Presence is not existence. A global `remote.origin.<anything>` in a user's
  # ~/.gitconfig — `remote.origin.tagopt=--tags` is a common one — makes
  # `git remote` list origin in EVERY repository, with no URL behind it. Ask
  # for the URL instead, or the sole-remote rescue below never fires for the
  # people who need it.
  if ! git -C "$root" config --get remote.origin.url >/dev/null 2>&1; then
    real=$(git -C "$root" remote | while read -r r; do
             git -C "$root" config --get "remote.$r.url" >/dev/null 2>&1 && printf '%s\n' "$r"
           done)
    n=$(printf '%s' "$real" | grep -c . || true)
    if [ "$n" = "1" ]; then printf '%s' "$real" | head -1 | tr -d '\n'; return 0; fi
  fi
  printf 'origin'
}

# wtkit_resolve_base_ref <root> <branch>
#   The one place that answers "given this branch NAME, what ref do I actually
#   use, and is it on the remote?" Prints "<ref> <branch> <on_remote>", where
#   <on_remote> is 1 or 0. Returns 1 and prints nothing when the name matches
#   neither a remote-tracking ref nor a local branch.
#
#   The remote wins when a name exists both ways: the local copy may be behind,
#   and branching new work off a stale copy silently forks it. The local
#   fallback is for an integration branch that collects several tasks before
#   one PR and has not been pushed yet — handing git "origin/<unpushed>" fails
#   the launcher outright.
#
#   Callers must NOT rebuild "origin/$branch" themselves. That reconstruction
#   is the bug this function exists to delete: a local-only base resolved
#   correctly here and then failed in every consumer that pasted the prefix
#   back on, including the guard that force-deletes branches.
wtkit_resolve_base_ref() {
  local root="${1:-.}" branch="${2:-}" rem="${WTKIT_REMOTE:-origin}"
  [ -n "$branch" ] || return 1
  if git -C "$root" rev-parse --verify --quiet "refs/remotes/$rem/$branch" >/dev/null 2>&1; then
    printf '%s/%s %s 1' "$rem" "$branch" "$branch"; return 0
  fi
  if git -C "$root" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    printf '%s %s 0' "$branch" "$branch"; return 0
  fi
  return 1
}

# The base a new worktree branches from when no --base is given, printed in the
# same "<ref> <branch> <on_remote>" shape wtkit_resolve_base_ref returns.
# Hardcoding origin/main strands every repo whose default is develop/master/
# trunk: the worktree comes up on a branch that can be hundreds of commits
# stale, which reads as a broken checkout rather than a wrong base.
#
# Resolution order:
#   1. git config wtkit.baseBranch  — the run-local override
#   2. BASE_BRANCH from workspace.conf — the project's durable default
#   3. origin/HEAD — the remote's own answer to "what is the default branch"
#   4. origin/main — the historical fallback
#
# The git config override comes FIRST because the integration branch a
# multi-worktree fan-in collects into is a this-clone, this-week choice, not
# durable project config. Committing it to workspace.conf would put a branch
# name that dies next week into the PR and hand a fresh clone a base that no
# longer exists. git config lives in the shared common git dir, so every
# worktree of the repo reads the same value with nothing to keep in sync — the
# same property ship-lock relies on.
#
# BASE_BRANCH is consulted rather than a separate key because it is the SAME
# branch /ship-land merges into and /next-task resets off. A separate key could
# disagree with it, and a repo whose worktrees branch from develop while its
# PRs land on main is a trap.
wtkit_default_base() {
  local root="${1:-.}" want head pair rem="${WTKIT_REMOTE:-origin}"
  want=$(git -C "$root" config --get wtkit.baseBranch 2>/dev/null) || want=""
  [ -n "$want" ] || want="${BASE_BRANCH:-}"
  if [ -n "$want" ]; then
    if pair=$(wtkit_resolve_base_ref "$root" "$want"); then
      case "$pair" in
        *' 0') echo "!! base '$want' is not on $rem yet; using the local branch." >&2 ;;
      esac
      printf '%s' "$pair"; return
    fi
    echo "!! base '$want' matches no branch; falling back to the remote default." >&2
  fi
  head=$(git -C "$root" symbolic-ref --quiet --short "refs/remotes/$rem/HEAD" 2>/dev/null || echo "")
  # A --single-branch clone never gets the ref. Ask the remote once and cache
  # it, exactly as `git remote set-head <remote> -a` would; failure is fine, we
  # just fall through to the historical default.
  if [ -z "$head" ]; then
    git -C "$root" remote set-head "$rem" --auto >/dev/null 2>&1 || true
    head=$(git -C "$root" symbolic-ref --quiet --short "refs/remotes/$rem/HEAD" 2>/dev/null || echo "")
  fi
  # Route the remote's own answer back through the resolver rather than
  # trusting the prefix, so one code path decides what a ref is.
  if [ -n "$head" ] && pair=$(wtkit_resolve_base_ref "$root" "${head#"$rem"/}"); then
    printf '%s' "$pair"; return
  fi
  printf '%s/main main 1' "$rem"
}


# wtkit_assert_base_agrees <root> <explicit-base> <resolved-base>
#   Refuses when a caller's --base names a different commit from the base the
#   repo resolved. --base is read once and never persisted, so it steers only
#   worktree creation; every guard and reset afterwards reads the resolved base.
#   Letting the two disagree silently is what makes /next-task count the
#   integration branch's own commits as your unlanded work, and refuse forever.
#
#   Compared as COMMITS, not strings: "feat/x", "refs/heads/feat/x" and a
#   detached SHA can all name the same thing, and a string test would reject
#   the equivalents while still missing a genuine divergence. Two branches
#   sitting on the same commit are identical content, so they pass.
wtkit_assert_base_agrees() {
  local root="$1" want="$2" resolved="$3" a b
  a=$(git -C "$root" rev-parse --verify --quiet "$want^{commit}") || a=""
  if [ -z "$a" ]; then
    echo "--base '$want' does not resolve to a commit in this repo." >&2
    return 1
  fi
  b=$(git -C "$root" rev-parse --verify --quiet "$resolved^{commit}") || b=""
  [ -n "$b" ] || return 0   # nothing to disagree with
  [ "$a" = "$b" ] && return 0
  echo "" >&2
  echo "--base '$want' disagrees with this repo's base '$resolved'." >&2
  echo "" >&2
  echo "  --base steers the worktree you are creating RIGHT NOW and nothing" >&2
  echo "  else. /next-task, ship-classify and the teardown guard all read" >&2
  echo "  '$resolved' instead, so they would measure this worktree against a" >&2
  echo "  branch it was never cut from." >&2
  echo "" >&2
  echo "  Set the base for everything:  git config wtkit.baseBranch <branch>" >&2
  echo "  Or accept the split just here: --base-override" >&2
  return 1
}


# wtkit_fetch_base_ref <root> <ref>
#   Refresh <ref> from the remote when there is a remote copy to refresh from.
#   Silence is wrong in both directions here. Fetching a branch that was never
#   pushed fails noisily for no reason — that is the local integration branch
#   several worktrees fan into, and it is the normal case, not an error. And
#   swallowing a REAL failure leaves every later count measured against a stale
#   ref with nothing said, which is how a teardown guard ends up confidently
#   wrong about whether your work has landed.
#
#   Never fatal: a stale base is usable, the caller just has to know it is stale.
wtkit_fetch_base_ref() {
  local root="${1:-.}" ref="${2:-}" rem="${WTKIT_REMOTE:-origin}" branch
  case "$ref" in
    "$rem"/*) branch="${ref#"$rem"/}" ;;
    *) return 0 ;;   # a local branch: there is nothing upstream to fetch
  esac
  if ! git -C "$root" fetch "$rem" "$branch" >/dev/null 2>&1; then
    echo "!! could not fetch $rem/$branch — continuing from the local copy," >&2
    echo "!! which may be behind. Counts against it may be wrong." >&2
  fi
  return 0
}


# wtkit_landing_witness <root> [tip]
#   Is <tip> already contained somewhere other than the configured base?
#   Prints that ref and returns 0, or returns 1.
#
#   This exists so a refusal can tell the user whether --force is safe. The
#   configured base is a moving target: an integration branch gets deleted once
#   its PR lands, and from then on the teardown guard can no longer resolve it
#   and refuses forever — for work that IS safely landed, by a route the guard
#   cannot see. A user who hits that three times stops reading and starts
#   passing --force by reflex, which is precisely when it will cost them.
#
#   The witness is the remote's own default branch, not a guessed list of
#   main/master/develop. Guessing branch names is the habit this kit removed.
wtkit_landing_witness() {
  local root="${1:-.}" tip="${2:-HEAD}" rem="${WTKIT_REMOTE:-origin}" head
  head=$(git -C "$root" symbolic-ref --quiet --short "refs/remotes/$rem/HEAD" 2>/dev/null || echo "")
  [ -n "$head" ] || return 1
  git -C "$root" rev-parse --verify --quiet "$head" >/dev/null 2>&1 || return 1
  git -C "$root" merge-base --is-ancestor "$tip" "$head" 2>/dev/null || return 1
  printf '%s' "$head"
}

# ---- config -----------------------------------------------------------------
# Sets REPO, PROJECT_SLUG, USE_DOCKER, the four port bases, INHERIT_ENV_KEYS,
# WORKSPACE_INITIAL_PROMPT_FMT, FINISH_HINT, WTKIT_REMOTE, DEFAULT_BASE,
# DEFAULT_BASE_BRANCH, DEFAULT_BASE_ON_REMOTE — and sources the repo conf, which may override any of
# them and define the write_env / post_up hooks.
wtkit_load_conf() {
  MAIN_ROOT="$1"
  REPO=$(basename "$MAIN_ROOT")
  WTKIT_CONF="$MAIN_ROOT/.claude/workspace.conf"
  # Fall back to the CURRENT worktree's conf when the main checkout has none.
  # That is what makes a branch which adds or edits the conf take effect before
  # it lands, instead of silently running unconfigured.
  if [ ! -f "$WTKIT_CONF" ]; then
    local here
    here=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    [ -n "$here" ] && [ -f "$here/.claude/workspace.conf" ] && WTKIT_CONF="$here/.claude/workspace.conf"
  fi
  HAS_CONF=0
  if [ -f "$WTKIT_CONF" ]; then
    HAS_CONF=1
    # shellcheck disable=SC1090
    . "$WTKIT_CONF"
  fi

  # The remote is resolved FIRST: every base lookup below asks it what exists.
  WTKIT_REMOTE=$(wtkit_resolve_remote "$MAIN_ROOT")

  # Resolved after the conf is sourced so a BASE_BRANCH it sets is honoured.
  # A caller's --base still wins: the launchers only fall back to this.
  #
  # DEFAULT_BASE is the ref to hand git, DEFAULT_BASE_BRANCH the bare name a PR
  # targets, DEFAULT_BASE_ON_REMOTE whether fetching it or asking a forge about
  # it means anything. They are resolved together, from one lookup, so they can
  # never disagree about the same base.
  if [ -z "${DEFAULT_BASE:-}" ]; then
    read -r DEFAULT_BASE DEFAULT_BASE_BRANCH DEFAULT_BASE_ON_REMOTE \
      <<<"$(wtkit_default_base "$MAIN_ROOT")"
  else
    # A conf may pin DEFAULT_BASE outright. Classify what it pinned so the three
    # stay consistent; a pinned ref is already a ref, so the prefix is only
    # stripped when it actually names the remote.
    case "$DEFAULT_BASE" in
      "$WTKIT_REMOTE"/*) DEFAULT_BASE_BRANCH="${DEFAULT_BASE#"$WTKIT_REMOTE"/}"; DEFAULT_BASE_ON_REMOTE=1 ;;
      *)                 DEFAULT_BASE_BRANCH="$DEFAULT_BASE";                    DEFAULT_BASE_ON_REMOTE=0 ;;
    esac
  fi

  # Slugify whatever we end up with, not just the default: the slug becomes a
  # docker project name and a database identifier, and a conf is free to set
  # something with dots or capitals that neither accepts.
  : "${PROJECT_SLUG:=$REPO}"
  PROJECT_SLUG=$(wtkit_slugify "$PROJECT_SLUG")

  # Docker is opt-in: a conf must exist AND the repo must have a compose file.
  # Without a conf we cannot know how to write a usable .env, so we stay out of
  # the way rather than dropping a half-configured one into the worktree.
  if [ -z "${USE_DOCKER:-}" ]; then
    if [ "$HAS_CONF" -eq 1 ] && { [ -f "$MAIN_ROOT/docker-compose.yml" ] \
        || [ -f "$MAIN_ROOT/compose.yaml" ] || [ -f "$MAIN_ROOT/compose.yml" ]; }; then
      USE_DOCKER=1
    else
      USE_DOCKER=0
    fi
  fi

  # A per-repo window of 20 ports, derived from the repo name, so workspace-1
  # of two different projects never claim the same pair. Workspaces take the
  # low half of the window, throwaway task worktrees the high half. A conf can
  # pin these explicitly (do that if a project's ports are already documented).
  # Remember whether the conf pinned each band BEFORE we default it: a pinned
  # band owns its whole range (the historical 8100-8499 task band), while a
  # hash-derived one is only 20 wide and must not spill into the next repo's.
  local band ws_pinned=0 task_pinned=0
  [ -n "${WORKSPACE_WEB_BASE:-}" ] && ws_pinned=1
  [ -n "${TASK_WEB_BASE:-}" ] && task_pinned=1
  band=$(( $(wtkit_hash "$PROJECT_SLUG") % 50 ))
  : "${WORKSPACE_WEB_BASE:=$(( 8000 + band * 20 ))}"
  : "${WORKSPACE_DB_BASE:=$(( 5300 + band * 20 ))}"
  : "${TASK_WEB_BASE:=$(( WORKSPACE_WEB_BASE + 10 ))}"
  : "${TASK_DB_BASE:=$(( WORKSPACE_DB_BASE + 10 ))}"

  if [ "$task_pinned" -eq 1 ]; then : "${TASK_PORT_SPAN:=400}"; else : "${TASK_PORT_SPAN:=10}"; fi
  if [ "$ws_pinned" -eq 1 ]; then : "${WORKSPACE_PORT_SPAN:=200}"; else : "${WORKSPACE_PORT_SPAN:=10}"; fi

  : "${INHERIT_ENV_KEYS:=}"
  : "${WORKSPACE_INITIAL_PROMPT_FMT:=%s}"
  : "${FINISH_HINT:=}"

  export MAIN_ROOT REPO PROJECT_SLUG USE_DOCKER
}

# ---- ports ------------------------------------------------------------------
wtkit_port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# wtkit_alloc_ports <web_base> <db_base> <start_offset> <span> [wrap|linear]
# Sets WEB_PORT / DB_PORT to the first free pair, searching <span> offsets.
# The probe matters because the offset alone is deterministic: two repos, or a
# stopped stack, can otherwise hand the same pair out twice.
#   wrap   — walk the whole band modulo <span> (task worktrees: the offset is a
#            hash, so the search must cover the band, not just run off its end)
#   linear — count up from <start> (workspaces: the offset is the index n, which
#            may legitimately exceed the span, and must not alias onto n % span)
wtkit_alloc_ports() {
  local web_base="$1" db_base="$2" start="$3" span="${4:-20}" mode="${5:-linear}" i off
  for i in $(seq 0 "$span"); do
    if [ "$mode" = "wrap" ]; then off=$(( (start + i) % span )); else off=$(( start + i )); fi
    WEB_PORT=$(( web_base + off ))
    DB_PORT=$(( db_base + off ))
    if ! wtkit_port_busy "$WEB_PORT" && ! wtkit_port_busy "$DB_PORT"; then
      return 0
    fi
  done
  echo "Could not find a free port pair in ${web_base}-$(( web_base + span - 1 )) / ${db_base}-$(( db_base + span - 1 ))." >&2
  return 1
}

# ---- the per-worktree .env --------------------------------------------------
wtkit_default_env_body() {
  cat <<EOF
COMPOSE_PROJECT_NAME=$PROJ
WEB_PORT=$WEB_PORT
DB_PORT=$DB_PORT
EOF
}

# Copy inherited secrets from the main checkout's .env. Never writes back.
wtkit_inherit_env_keys() {
  local envfile="$1" key val tmp
  [ -n "${INHERIT_ENV_KEYS:-}" ] || return 0
  [ -f "$MAIN_ROOT/.env" ] || return 0
  for key in $INHERIT_ENV_KEYS; do
    # || true: grep exits 1 on a key the main .env does not carry, and every
    # bin/ caller runs with pipefail, so an absent key would abort the whole
    # worktree setup instead of being skipped by the -n test below.
    val=$(grep "^${key}=" "$MAIN_ROOT/.env" 2>/dev/null | head -1 | sed "s/^${key}=//") || true
    [ -n "$val" ] || continue
    if grep -q "^${key}=" "$envfile" 2>/dev/null; then
      # Not sed: an & in the value is replacement syntax there, so a key
      # containing one is silently corrupted into the whole matched line.
      # ENVIRON passes both strings through literally (awk -v would still
      # process backslash escapes).
      # cp -p seeds the temp with the original's mode, the redirect truncates
      # it without changing that mode, mv swaps it in atomically. A bare
      # "> $envfile" truncates first: an interrupted write would leave the
      # worktree with no COMPOSE_PROJECT_NAME or ports.
      tmp="$envfile.wtkit.$$"
      if cp -p "$envfile" "$tmp" &&
         k="$key" v="$val" awk '
           BEGIN { k = ENVIRON["k"]; v = ENVIRON["v"] }
           { n = index($0, "=")
             if (n > 0 && substr($0, 1, n - 1) == k) print k "=" v; else print }
         ' "$envfile" > "$tmp" && mv "$tmp" "$envfile"; then :; else
        rm -f "$tmp"
        echo "!! failed to write $key into $envfile" >&2
      fi
    else
      printf '%s=%s\n' "$key" "$val" >> "$envfile"
    fi
  done
}

# Read one KEY's value out of an env file. Deliberately the same shape as the
# reader in wtkit_inherit_env_keys.
wtkit_env_get() { grep "^$2=" "$1" 2>/dev/null | head -1 | sed "s/^$2=//" || true; }

# wtkit_read_env <wt_dir> — load PROJ / WEB_PORT / DB_PORT from an existing
# .env, and fail if there is none. Once a worktree has an .env, that file is the
# source of truth: re-deriving the ports would hand a running stack a second
# identity and orphan its volumes.
wtkit_read_env() {
  local envfile="$1/.env" v
  [ -f "$envfile" ] || return 1
  v=$(wtkit_env_get "$envfile" COMPOSE_PROJECT_NAME); [ -n "$v" ] && PROJ="$v"
  v=$(wtkit_env_get "$envfile" WEB_PORT);             [ -n "$v" ] && WEB_PORT="$v"
  v=$(wtkit_env_get "$envfile" DB_PORT);              [ -n "$v" ] && DB_PORT="$v"
  return 0
}

# wtkit_write_env <wt_dir> <generated-by>
wtkit_write_env() {
  local wt_dir="$1" by="$2" envfile="$1/.env"
  [ "${USE_DOCKER:-0}" -eq 1 ] || return 0
  export WT_DIR="$wt_dir" PROJ DBNAME WEB_PORT DB_PORT
  echo "==> Writing $envfile (COMPOSE_PROJECT_NAME=$PROJ WEB_PORT=$WEB_PORT DB_PORT=$DB_PORT)"
  {
    echo "# Auto-generated by $by — per-worktree docker isolation. Not committed."
    if declare -F write_env >/dev/null 2>&1; then write_env; else wtkit_default_env_body; fi
  } > "$envfile"
  wtkit_inherit_env_keys "$envfile"
}

# ---- the docker stack -------------------------------------------------------
wtkit_docker_up() {
  local wt_dir="$1" i
  [ "${USE_DOCKER:-0}" -eq 1 ] || return 0
  if [ "${NO_DOCKER:-0}" -eq 1 ]; then
    echo "==> Skipping docker stack (--no-docker). .env is written; start it with:  cd '$wt_dir' && docker compose up -d --build"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "!! docker not found — skipping stack." >&2
    USE_DOCKER=0
    return 0
  fi
  # --build only on request. The launchers ask for it (first run, image may not
  # exist yet); merely reopening a worktree should not pay a full rebuild.
  # `up -d` still builds on its own when the image is missing.
  if [ "${REBUILD:-0}" -eq 1 ]; then
    echo "==> Building + starting docker stack ($PROJ)"
    ( cd "$wt_dir" && docker compose up -d --build )
  else
    echo "==> Starting docker stack ($PROJ)"
    ( cd "$wt_dir" && docker compose up -d )
  fi
  [ "${NO_POST_UP:-0}" -eq 0 ] || { echo "==> Skipping post_up (--no-post-up)"; return 0; }
  declare -F post_up >/dev/null 2>&1 || return 0
  echo "==> Running post_up (retrying while the stack comes up)"
  for i in $(seq 1 10); do
    if ( cd "$wt_dir" && post_up ); then return 0; fi
    sleep 3
  done
  echo "!! post_up did not succeed; run it manually inside $wt_dir" >&2
}

# ---- converging a worktree's stack ------------------------------------------
# True when this worktree's compose project has at least one RUNNING container.
wtkit_stack_running() {
  local out
  command -v docker >/dev/null 2>&1 || return 1
  out=$( cd "$1" && docker compose ps --status running -q 2>/dev/null ) || return 1
  [ -n "$out" ]
}

# True when the project has containers at all, running or not.
wtkit_stack_exists() {
  local out
  command -v docker >/dev/null 2>&1 || return 1
  out=$( cd "$1" && docker compose ps -aq 2>/dev/null ) || return 1
  [ -n "$out" ]
}

# wtkit_ensure_stack <wt_dir> <generated-by>
#
# Idempotent: converges the worktree to "stack running" from ANY starting state
# — no .env, .env but never started, stopped, or already up. One code path
# serves both the launchers (always the first state) and start-worktree (any of
# them), which is what keeps a second, drifting implementation from existing.
#
# The caller owns PROJ / DBNAME / WEB_PORT / DB_PORT: either freshly allocated
# (launchers) or read back with wtkit_read_env (start-worktree).
#
# Reports what it found in WTKIT_STACK_WAS: absent | stopped | running.
wtkit_ensure_stack() {
  local wt_dir="$1" by="$2" p
  WTKIT_STACK_WAS=absent
  [ "${USE_DOCKER:-0}" -eq 1 ] || return 0

  [ -f "$wt_dir/.env" ] || wtkit_write_env "$wt_dir" "$by"

  if wtkit_stack_running "$wt_dir"; then
    WTKIT_STACK_WAS=running
  elif wtkit_stack_exists "$wt_dir"; then
    WTKIT_STACK_WAS=stopped
  fi

  # A port held by SOMETHING ELSE is a real clash; a port held by this
  # worktree's own running containers is not. Conflating the two makes the
  # check refuse precisely when everything is already fine, so the probe only
  # runs when our own stack is not the one listening.
  if [ "$WTKIT_STACK_WAS" != "running" ] && [ "${NO_DOCKER:-0}" -eq 0 ]; then
    for p in "${WEB_PORT:-}" "${DB_PORT:-}"; do
      [ -n "$p" ] || continue
      if wtkit_port_busy "$p"; then
        echo "!! Port $p is in use by another process." >&2
        echo "   $wt_dir/.env is the source of truth for this worktree's ports," >&2
        echo "   so they are not silently reallocated. Free the port or edit that file." >&2
        return 1
      fi
    done
  fi

  wtkit_docker_up "$wt_dir"
}

# ---- launching Claude -------------------------------------------------------
# wtkit_launch_claude <wt_dir> <window-name> <tmux-session> <claude args...>
# Reads NO_LAUNCH / USE_TMUX from the caller. Execs on the default path, so
# print your summary BEFORE calling this.
wtkit_launch_claude() {
  local wt_dir="$1" win="$2" sess="$3"; shift 3
  local args=("$@") pretty cmd
  pretty=$(printf '%q ' "${args[@]}")

  if [ "${NO_LAUNCH:-0}" -eq 1 ]; then
    echo ""; echo "Prepared only (--no-launch). Start Claude with:  cd '$wt_dir' && claude $pretty"
    return 0
  fi
  if ! command -v claude >/dev/null 2>&1; then
    echo ""; echo "!! 'claude' not on PATH. Start it manually:  cd '$wt_dir' && claude $pretty" >&2
    return 0
  fi
  if [ "${USE_TMUX:-0}" -eq 1 ]; then
    if ! command -v tmux >/dev/null 2>&1; then
      echo ""; echo "!! 'tmux' not found. Start manually:  cd '$wt_dir' && claude $pretty" >&2
      return 0
    fi
    cmd="claude $pretty; exec ${SHELL:-/bin/bash}"
    if [ -n "${TMUX:-}" ]; then
      tmux new-window -c "$wt_dir" -n "$win" "$cmd"
      echo ""; echo "==> Launched Claude in a new tmux window '$win'."
    else
      if tmux has-session -t "$sess" 2>/dev/null; then
        tmux new-window -t "$sess" -c "$wt_dir" -n "$win" "$cmd"
      else
        tmux new-session -d -s "$sess" -c "$wt_dir" -n "$win" "$cmd"
      fi
      echo ""; echo "==> Launched Claude in tmux session '$sess', window '$win'. Attach: tmux attach -t $sess"
    fi
    return 0
  fi

  # Current pane: this shell becomes the Claude session.
  echo ""; echo "==> Starting Claude in this pane…"
  cd "$wt_dir" && exec claude "${args[@]}"
}
