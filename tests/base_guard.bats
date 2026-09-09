#!/usr/bin/env bats
#
# The --base / resolved-base disagreement guard, and the fixture seatbelt.

load helpers/repo

setup() {
  wtk_new_tmp; wtk_mk_repo develop
  wtk_mk_integration feat/something
  wtk_set_base feat/something
}
teardown() { wtk_teardown; }

@test "a --base naming the same commit is allowed" {
  run new-workspace 1 --no-launch --base feat/something
  [ "$status" -eq 0 ]
}

@test "an equivalent ref spelling is allowed, not rejected as a string mismatch" {
  # feat/x and refs/heads/feat/x name the same commit. A string compare would
  # reject this while still missing a real divergence.
  run new-workspace 1 --no-launch --base refs/heads/feat/something
  [ "$status" -eq 0 ]
}

@test "a --base on a different commit is refused" {
  run new-workspace 1 --no-launch --base origin/develop
  [ "$status" -eq 2 ]
  [[ "$output" == *"disagrees with this repo's base"* ]]
}

@test "--base-override accepts the split deliberately" {
  run new-workspace 1 --no-launch --base origin/develop --base-override
  [ "$status" -eq 0 ]
}

@test "a --base that resolves to nothing is refused with its own message" {
  run new-workspace 1 --no-launch --base ghost
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not resolve to a commit"* ]]
}

@test "new-task enforces the same guard" {
  # --base means the same thing in both launchers, so guarding only one would
  # move the surprise rather than remove it.
  run new-task probe-slug --no-launch --base origin/develop
  [ "$status" -eq 2 ]
  [[ "$output" == *"disagrees with this repo's base"* ]]
}

@test "no --base at all is unaffected" {
  run new-workspace 1 --no-launch
  [ "$status" -eq 0 ]
}

@test "the fixture guard refuses to run outside the fixture" {
  # The seatbelt itself. Without it a test that forgets to cd points
  # remove-workspace, which force-deletes branches, at the kit's own checkout.
  cd "$KIT_ROOT"
  run wtk_assert_fixture
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to run a destructive command"* ]]
}
