#!/usr/bin/env bats
#
# The preflight and the reset. The reset force-deletes the branch you are
# standing on, so these are the assertions that matter most in this file.

load helpers/repo

setup() {
  wtk_new_tmp; wtk_mk_repo develop
  wtk_mk_integration feat/something
  wtk_set_base feat/something
}
teardown() { wtk_teardown; }

# A worktree whose branch is fully landed: safe to reset.
landed_ws() {
  wtk_mk_workspace 1 feat/something "${1:-1}"
  git -C "$REPO" switch -q feat/something
  git -C "$REPO" merge -q --no-ff -m "land ws/1" workspace/1
  cd "$WS"
}

@test "preflight passes on a landed worktree" {
  landed_ws
  run next-task-preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"safe to reset"* ]]
}

@test "preflight refuses in the main checkout" {
  cd "$REPO"
  run next-task-preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"not the main checkout"* ]]
}

@test "preflight refuses on uncommitted changes, and shows them" {
  landed_ws
  echo dirt > "$WS/dirty.txt"
  run next-task-preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"uncommitted change(s)"* ]]
  [[ "$output" == *"dirty.txt"* ]]
}

@test "preflight refuses on unlanded commits, and shows them" {
  wtk_mk_workspace 1 feat/something 2
  cd "$WS"
  run next-task-preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 commit(s) not on feat/something"* ]]
  [[ "$output" == *"agent 1 work 1"* ]]
}

@test "preflight refuses when the base cannot be resolved" {
  # Unknown is not zero, and the reset force-deletes this branch.
  wtk_mk_workspace 1 feat/something 0
  wtk_conf 'DEFAULT_BASE="ref-that-does-not-exist"'
  cd "$WS"
  run next-task-preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNKNOWN"* ]]
}

@test "reset moves onto a fresh branch and deletes the old one" {
  landed_ws
  run next-task-reset my-new-task
  [ "$status" -eq 0 ]
  [ "$(git -C "$WS" branch --show-current)" = "feature/my-new-task" ]
  run wtk_has_branch workspace/1
  [ "$status" -ne 0 ]
}

@test "reset branches off the resolved base, carrying earlier landings" {
  landed_ws
  git -C "$REPO" switch -q feat/something
  git -C "$REPO" commit -q --allow-empty -m "another agent landed"
  cd "$WS"
  run next-task-reset my-new-task
  [ "$status" -eq 0 ]
  git -C "$WS" log --oneline | grep -q "another agent landed"
}

@test "REGRESSION: reset re-runs the guard itself and refuses unlanded work" {
  # The check and the force-delete must not be separable. A caller that skips
  # the preflight must not be able to reach the branch -D.
  wtk_mk_workspace 1 feat/something 2
  cd "$WS"
  run next-task-reset my-new-task
  [ "$status" -eq 1 ]
  [[ "$output" == *"not on feat/something"* ]]
  wtk_has_branch workspace/1
  [ "$(git -C "$WS" branch --show-current)" = "workspace/1" ]
}

@test "reset rejects a slug that is not kebab-case" {
  landed_ws
  run next-task-reset "Bad Slug"
  [ "$status" -eq 2 ]
  [[ "$output" == *"kebab-case"* ]]
}

@test "reset refuses a branch name that already exists" {
  landed_ws
  git -C "$REPO" branch feature/taken feat/something
  run next-task-reset taken
  [ "$status" -eq 2 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(git -C "$WS" branch --show-current)" = "workspace/1" ]
}

@test "reset honours --prefix" {
  landed_ws
  run next-task-reset my-task --prefix hotfix
  [ "$status" -eq 0 ]
  [ "$(git -C "$WS" branch --show-current)" = "hotfix/my-task" ]
}

@test "reset requires a slug" {
  landed_ws
  run next-task-reset
  [ "$status" -eq 2 ]
}
