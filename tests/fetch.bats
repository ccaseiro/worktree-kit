#!/usr/bin/env bats
#
# Fetch semantics: never fetch a base that was never pushed, never swallow a
# real failure. The counts that decide whether work gets deleted depend on it.

load helpers/repo

setup() { wtk_new_tmp; wtk_mk_repo develop; }
teardown() { wtk_teardown; }

resolve_remote() { bash -c "source '$WTKIT_LIB/common.sh'; wtkit_resolve_remote '$REPO'"; }

@test "fetching a local-only base is a no-op, not a failure" {
  wtk_mk_integration feat/local
  run bash -c "set -euo pipefail; source '$WTKIT_LIB/common.sh'
               wtkit_fetch_base_ref '$REPO' 'feat/local' 2>&1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a failing fetch warns instead of passing silently" {
  # Point the remote at nothing so the fetch cannot succeed.
  git -C "$REPO" remote set-url origin "$TESTDIR/does-not-exist.git"
  run bash -c "set -euo pipefail; source '$WTKIT_LIB/common.sh'
               wtkit_fetch_base_ref '$REPO' 'origin/develop' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not fetch origin/develop"* ]]
  [[ "$output" == *"may be behind"* ]]
}

@test "remove-workspace reports a stale base rather than counting silently" {
  wtk_mk_workspace 1 origin/develop 1
  git -C "$REPO" remote set-url origin "$TESTDIR/does-not-exist.git"
  run remove-workspace 1 --yes
  [[ "$output" == *"could not fetch"* ]]
}

@test "the launcher does not claim a fetch it never made" {
  wtk_mk_integration feat/local
  wtk_set_base feat/local
  run new-workspace 1 --no-launch
  [ "$status" -eq 0 ]
  [[ "$output" == *"Creating workspace 1 from local feat/local"* ]]
  [[ "$output" != *"Fetching"* ]]
}

@test "the launcher still says it fetched when the base is on the remote" {
  run new-workspace 1 --no-launch
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fetching origin/develop"* ]]
}
