#!/usr/bin/env bats
#
# wtconf — the three base keys every slash command reads.

load helpers/repo

setup() { wtk_new_tmp; wtk_mk_repo develop; }
teardown() { wtk_teardown; }

agent() { ( cd "${1:-$REPO}" && wtconf --agent 2>/dev/null ); }

@test "exports the ref, the bare name, and the on-remote flag" {
  run agent
  [[ "$output" == *"BASE_REF=origin/develop"* ]]
  [[ "$output" == *"BASE_BRANCH=develop"* ]]
  [[ "$output" == *"BASE_ON_REMOTE=1"* ]]
}

@test "a local-only base reports on_remote=0 and an unprefixed ref" {
  wtk_mk_integration feat/x
  wtk_set_base feat/x
  run agent
  [[ "$output" == *"BASE_REF=feat/x"* ]]
  [[ "$output" == *"BASE_ON_REMOTE=0"* ]]
}

@test "BASE_BRANCH follows the override instead of going stale" {
  # The keys are assigned, not defaulted with :=. With := a BASE_BRANCH the
  # conf also set would survive while BASE_REF moved — the two-sources split
  # this key set exists to remove, reintroduced from the other side.
  wtk_mk_integration feat/x
  wtk_set_base feat/x
  wtk_conf 'BASE_BRANCH="develop"'
  run agent
  [[ "$output" == *"BASE_BRANCH=feat/x"* ]]
  [[ "$output" != *"BASE_BRANCH=develop"* ]]
}

@test "the override is visible from inside a worktree, with no extra setup" {
  # git config lives in the shared common git dir, which is the same property
  # ship-lock relies on.
  wtk_mk_integration feat/x
  wtk_set_base feat/x
  wtk_mk_workspace 1 feat/x 1
  run agent "$WS"
  [[ "$output" == *"BASE_REF=feat/x"* ]]
}

@test "--agent output is eval-safe" {
  run bash -c "cd '$REPO' && set -euo pipefail && eval \"\$(wtconf --agent 2>/dev/null)\" && echo \"\$BASE_REF|\$BASE_ON_REMOTE\""
  [ "$status" -eq 0 ]
  [ "$output" = "origin/develop|1" ]
}

@test "--keys lists the three base keys first" {
  run bash -c "cd '$REPO' && wtconf --keys 2>/dev/null | head -3 | tr '\n' ' '"
  [ "$output" = "BASE_REF BASE_BRANCH BASE_ON_REMOTE " ]
}

@test "a single key can be read by name" {
  run bash -c "cd '$REPO' && wtconf BASE_REF 2>/dev/null"
  [ "$output" = "origin/develop" ]
}
