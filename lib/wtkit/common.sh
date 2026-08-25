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

# ---- config -----------------------------------------------------------------
# Sets REPO, PROJECT_SLUG, USE_DOCKER, the four port bases, INHERIT_ENV_KEYS,
# WORKSPACE_INITIAL_PROMPT_FMT, FINISH_HINT — and sources the repo conf, which
# may override any of them and define the write_env / post_up hooks.
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

  : "${PROJECT_SLUG:=$(wtkit_slugify "$REPO")}"

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
  local band
  band=$(( $(wtkit_hash "$PROJECT_SLUG") % 50 ))
  : "${WORKSPACE_WEB_BASE:=$(( 8000 + band * 20 ))}"
  : "${WORKSPACE_DB_BASE:=$(( 5300 + band * 20 ))}"
  : "${TASK_WEB_BASE:=$(( WORKSPACE_WEB_BASE + 10 ))}"
  : "${TASK_DB_BASE:=$(( WORKSPACE_DB_BASE + 10 ))}"

  : "${INHERIT_ENV_KEYS:=}"
  : "${WORKSPACE_INITIAL_PROMPT_FMT:=%s}"
  : "${FINISH_HINT:=}"

  export MAIN_ROOT REPO PROJECT_SLUG USE_DOCKER
}

# ---- ports ------------------------------------------------------------------
wtkit_port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# wtkit_alloc_ports <web_base> <db_base> <start_offset>
# Sets WEB_PORT / DB_PORT to the first free pair at or after the start offset.
# The probe matters because the offset alone is deterministic: two repos, or a
# stopped stack, can otherwise hand the same pair out twice.
wtkit_alloc_ports() {
  local web_base="$1" db_base="$2" start="$3" i off
  for i in $(seq 0 60); do
    off=$(( start + i ))
    WEB_PORT=$(( web_base + off ))
    DB_PORT=$(( db_base + off ))
    if ! wtkit_port_busy "$WEB_PORT" && ! wtkit_port_busy "$DB_PORT"; then
      return 0
    fi
  done
  echo "Could not find a free port pair near ${web_base}+${start} / ${db_base}+${start}." >&2
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
  local envfile="$1" key val
  [ -n "${INHERIT_ENV_KEYS:-}" ] || return 0
  [ -f "$MAIN_ROOT/.env" ] || return 0
  for key in $INHERIT_ENV_KEYS; do
    val=$(grep "^${key}=" "$MAIN_ROOT/.env" 2>/dev/null | head -1 | sed "s/^${key}=//")
    [ -n "$val" ] || continue
    if grep -q "^${key}=" "$envfile" 2>/dev/null; then
      # BSD/macOS sed needs the empty backup arg; GNU sed does not accept it.
      sed -i '' "s|^${key}=.*|${key}=${val}|" "$envfile" 2>/dev/null \
        || sed -i "s|^${key}=.*|${key}=${val}|" "$envfile"
    else
      printf '%s=%s\n' "$key" "$val" >> "$envfile"
    fi
  done
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
  echo "==> Building + starting docker stack ($PROJ)"
  ( cd "$wt_dir" && docker compose up -d --build )
  declare -F post_up >/dev/null 2>&1 || return 0
  echo "==> Running post_up (retrying while the stack comes up)"
  for i in $(seq 1 10); do
    if ( cd "$wt_dir" && post_up ); then return 0; fi
    sleep 3
  done
  echo "!! post_up did not succeed; run it manually inside $wt_dir" >&2
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
