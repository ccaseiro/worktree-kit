#!/usr/bin/env bats
#
# remove-workspace — the guard standing between an agent's commits and
# `git branch -D`. Two REGRESSION tests here pin a real data-loss bug.

load helpers/repo

setup() { wtk_new_tmp; wtk_mk_repo develop; }
teardown() { wtk_teardown; }

@test "REGRESSION: refuses when work is unlanded on a LOCAL base" {
  # The old guard asked origin/main..HEAD and swallowed the failure with
  # `|| echo 0`. Two real commits reported as zero, the confirm prompt dropped
  # its DISCARD warning because it reads the same counter, and branch -D then
  # force-deleted past git's own not-fully-merged check.
  wtk_mk_integration feat/something
  wtk_set_base feat/something
  wtk_mk_workspace 1 feat/something 2
  run remove-workspace 1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"unshipped (2)"* ]]
  wtk_has_branch workspace/1
}

@test "REGRESSION: refuses when the base cannot be resolved at all" {
  # "cannot tell" must never read as "nothing to lose". No remote here, so even
  # the historical origin/main fallback fails to resolve.
  wtk_mk_repo_no_remote
  wtk_mk_workspace 1 HEAD 1
  run remove-workspace 1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNKNOWN"* ]]
  wtk_has_branch workspace/1
}

@test "removes cleanly once the work is landed" {
  wtk_mk_integration feat/something
  wtk_set_base feat/something
  wtk_mk_workspace 1 feat/something 2
  git -C "$REPO" merge -q --no-ff -m "land ws/1" workspace/1
  run remove-workspace 1 --yes
  [ "$status" -eq 0 ]
  run wtk_has_branch workspace/1
  [ "$status" -ne 0 ]
}

@test "refuses on an uncommitted change even when everything is landed" {
  wtk_mk_integration feat/something
  wtk_set_base feat/something
  wtk_mk_workspace 1 feat/something 0
  echo dirt > "$WS/dirty.txt"
  run remove-workspace 1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"uncommitted (1)"* ]]
}

@test "measures against the repo's base, not a hardcoded origin/main" {
  # This repo's default is develop and it has no main at all. The old guard
  # silently measured against a ref that never existed here.
  wtk_mk_workspace 1 origin/develop 3
  run remove-workspace 1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"unshipped (3)"* ]]
  [[ "$output" == *"Base:      origin/develop"* ]]
}

@test "--force overrides a refusal" {
  wtk_mk_integration feat/something
  wtk_set_base feat/something
  wtk_mk_workspace 1 feat/something 2
  run remove-workspace 1 --force --yes
  [ "$status" -eq 0 ]
  run wtk_has_branch workspace/1
  [ "$status" -ne 0 ]
}

@test "--force past an unresolvable base still warns, and does not crash" {
  # UNSHIPPED is empty on that path; an unguarded integer test on it would
  # abort the script under set -e before it could warn.
  wtk_mk_repo_no_remote
  wtk_mk_workspace 1 HEAD 1
  run remove-workspace 1 --force --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNKNOWN"* ]]
}
