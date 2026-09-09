#!/usr/bin/env bats
#
# wtkit_resolve_base_ref and wtkit_default_base — the resolution every other
# guard in the kit is measured against.

load helpers/repo

setup() { wtk_new_tmp; wtk_mk_repo develop; }
teardown() { wtk_teardown; }

resolve() {  # <branch> -> "<ref> <branch> <flag>", or exit 1
  bash -c "source '$WTKIT_LIB/common.sh'; wtkit_resolve_base_ref '$REPO' '$1'"
}
default_base() {  # honours BASE_BRANCH / git config, prints the triple
  bash -c "set -euo pipefail; source '$WTKIT_LIB/common.sh'; ${1:-}
           wtkit_default_base '$REPO'" 2>/dev/null
}

@test "resolves a branch that is on the remote" {
  run resolve develop
  [ "$status" -eq 0 ]
  [ "$output" = "origin/develop develop 1" ]
}

@test "resolves a branch that exists only locally" {
  wtk_mk_integration feat/local-only
  run resolve feat/local-only
  [ "$status" -eq 0 ]
  [ "$output" = "feat/local-only feat/local-only 0" ]
}

@test "prefers the remote when a name exists both ways" {
  # A local copy may be behind; branching new work off a stale one forks it.
  wtk_mk_integration shared
  wtk_push_branch shared
  run resolve shared
  [ "$output" = "origin/shared shared 1" ]
}

@test "fails, printing nothing, when the name matches neither" {
  run resolve ghost
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "fails on an empty branch name" {
  run resolve ""
  [ "$status" -eq 1 ]
}

@test "default base falls back to the remote's own default, not main" {
  # The whole point: this repo's default is develop. A hardcoded origin/main
  # would look fine on a repo whose default IS main.
  run default_base
  [ "$output" = "origin/develop develop 1" ]
}

@test "conf BASE_BRANCH is honoured" {
  wtk_mk_integration feat/x
  run default_base 'BASE_BRANCH=feat/x'
  [ "$output" = "feat/x feat/x 0" ]
}

@test "git config wtkit.baseBranch overrides the conf" {
  wtk_mk_integration feat/x
  wtk_set_base feat/x
  run default_base 'BASE_BRANCH=develop'
  [ "$output" = "feat/x feat/x 0" ]
}

@test "an unmatched base warns and falls through, rather than being used" {
  run bash -c "set -euo pipefail; source '$WTKIT_LIB/common.sh'
               BASE_BRANCH=ghost; wtkit_default_base '$REPO' 2>&1"
  [[ "$output" == *"matches no branch"* ]]
  [[ "$output" == *"origin/develop develop 1"* ]]
}

@test "the local-fallback warning goes to stderr, never stdout" {
  # wtkit_default_base is read through $(...); a warning on stdout would be
  # captured as part of the ref.
  wtk_mk_integration feat/x
  run default_base 'BASE_BRANCH=feat/x'
  [ "$output" = "feat/x feat/x 0" ]
}

@test "no remote at all still yields the historical fallback" {
  wtk_mk_repo_no_remote
  run default_base
  [ "$output" = "origin/main main 1" ]
}
