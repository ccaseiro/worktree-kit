#!/usr/bin/env bats
#
# land-local — the fan-in. Concurrent code whose failure mode is a corrupted
# integration branch or an agent's work landed untested, so the failure paths
# matter at least as much as the happy one.

load helpers/repo

setup() {
  wtk_new_tmp; wtk_mk_repo develop
  wtk_mk_integration feat/something
  wtk_set_base feat/something
  wtk_conf 'TEST_CMD="true"'
}
teardown() { wtk_teardown; }

# A TEST_CMD that runs $REPO/hook.sh, so a test can make the world move
# underneath land-local while its suite is running.
use_hook() { wtk_conf "TEST_CMD=\"$REPO/hook.sh\""; }
write_hook() { printf '%s\n' '#!/usr/bin/env bash' "$@" 'exit 0' > "$REPO/hook.sh"; chmod +x "$REPO/hook.sh"; }

@test "lands one agent's work onto the integration branch" {
  wtk_mk_workspace 1 feat/something 1
  cd "$WS"
  run land-local
  [ "$status" -eq 0 ]
  [[ "$output" == *"Landed"* ]]
  [ "$(wtk_count feat/something)" -gt 1 ]
  git -C "$REPO" log --oneline feat/something | grep -q "agent 1 work 1"
}

@test "three agents fan in and every commit survives" {
  for n in 1 2 3; do
    wtk_mk_workspace "$n" feat/something 1
    ( cd "$WS" && land-local >/dev/null 2>&1 )
  done
  for n in 1 2 3; do
    git -C "$REPO" log --oneline feat/something | grep -q "agent $n work 1"
  done
}

@test "advances the integration branch while it is checked out in the main worktree" {
  # git refuses `branch -f` on a checked-out branch, and update-ref would leave
  # that worktree's index pointing at a commit it never checked out.
  git -C "$REPO" switch -q feat/something
  wtk_mk_workspace 1 feat/something 1
  cd "$WS"
  run land-local
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]
}

@test "a red suite leaves the integration branch untouched" {
  wtk_conf 'TEST_CMD="false"'
  wtk_mk_workspace 1 feat/something 1
  local before; before=$(wtk_tip feat/something)
  cd "$WS"
  run land-local
  [ "$status" -eq 1 ]
  [[ "$output" == *"was not touched"* ]]
  [ "$(wtk_tip feat/something)" = "$before" ]
}

@test "a merge conflict stops, leaves the branch alone, and leaves the merge to resolve" {
  wtk_mk_workspace 1 feat/something 0
  echo "side A" > "$WS/clash.txt"
  ( cd "$WS" && git add clash.txt && git commit -qm "ws clash" )
  git -C "$REPO" switch -q feat/something
  echo "side B" > "$REPO/clash.txt"
  git -C "$REPO" add clash.txt && git -C "$REPO" commit -qm "integration clash"
  local before; before=$(wtk_tip feat/something)
  cd "$WS"
  run land-local
  [ "$status" -eq 1 ]
  [[ "$output" == *"Merge conflict"* ]]
  [ "$(wtk_tip feat/something)" = "$before" ]
  git -C "$WS" rev-parse -q --verify MERGE_HEAD >/dev/null
}

@test "a rival landing mid-test is detected, retried, and both land" {
  wtk_mk_workspace 1 feat/something 1
  use_hook
  write_hook \
    "[ -f '$REPO/.rival' ] && exit 0" \
    "touch '$REPO/.rival'" \
    "git -C '$REPO' switch -q feat/something" \
    "git -C '$REPO' commit -q --allow-empty -m 'rival landed'"
  cd "$WS"
  run land-local
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved while testing; retrying"* ]]
  git -C "$REPO" log --oneline feat/something | grep -q "agent 1 work 1"
  git -C "$REPO" log --oneline feat/something | grep -q "rival landed"
}

@test "REGRESSION: a commit made during the test run does not ride in untested" {
  # Verifying only that the BASE has not moved is not enough: anything that
  # commits in this worktree while TEST_CMD runs would otherwise land on the
  # back of a green result for a different tree.
  wtk_mk_workspace 1 feat/something 1
  use_hook
  write_hook \
    "[ -f '$REPO/.sneak' ] && exit 0" \
    "touch '$REPO/.sneak'" \
    "git -C '$WS' commit -q --allow-empty -m 'snuck in after the test started'"
  cd "$WS"
  run land-local
  [[ "$output" == *"retrying"* ]]
}

@test "retries exhausted falls back to landing under the lock" {
  wtk_mk_workspace 1 feat/something 1
  use_hook
  write_hook \
    "N=\$(cat '$REPO/.n' 2>/dev/null || echo 0); N=\$((N+1)); echo \$N > '$REPO/.n'" \
    "if [ \"\$N\" -le 2 ]; then git -C '$REPO' switch -q feat/something; git -C '$REPO' commit -q --allow-empty -m \"rival \$N\"; fi"
  cd "$WS"
  run land-local --retries 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"lost the race; landing under the lock"* ]]
  git -C "$REPO" log --oneline feat/something | grep -q "agent 1 work 1"
}

@test "the lock is free again after every outcome" {
  wtk_mk_workspace 1 feat/something 1
  cd "$WS"
  run land-local
  run ship-lock status
  [[ "$output" == *"LOCK_FREE"* ]]

  wtk_conf 'TEST_CMD="false"'
  wtk_mk_workspace 2 feat/something 1
  cd "$WS"
  run land-local
  run ship-lock status
  [[ "$output" == *"LOCK_FREE"* ]]
}

@test "--no-test lands without a TEST_CMD" {
  wtk_conf ''
  wtk_mk_workspace 1 feat/something 1
  cd "$WS"
  run land-local --no-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tests skipped"* ]]
}

@test "refuses without a TEST_CMD when tests were not waived" {
  wtk_conf ''
  wtk_mk_workspace 1 feat/something 1
  cd "$WS"
  run land-local
  [ "$status" -eq 2 ]
  [[ "$output" == *"No TEST_CMD"* ]]
}

@test "refuses when run on the integration branch itself" {
  git -C "$REPO" switch -q feat/something
  run land-local
  [ "$status" -eq 2 ]
  [[ "$output" == *"ON the integration branch"* ]]
}

@test "refuses with uncommitted changes" {
  wtk_mk_workspace 1 feat/something 1
  echo dirt > "$WS/dirty.txt"
  cd "$WS"
  run land-local
  [ "$status" -eq 2 ]
  [[ "$output" == *"Uncommitted changes"* ]]
}

@test "refuses when the base has no local branch to advance" {
  wtk_set_base develop
  git -C "$REPO" switch -q feat/something
  git -C "$REPO" branch -D develop >/dev/null 2>&1 || true
  wtk_mk_workspace 1 feat/something 1
  cd "$WS"
  run land-local
  [ "$status" -eq 2 ]
  [[ "$output" == *"No local branch"* ]]
}

@test "says so, and does nothing, when there is nothing to land" {
  wtk_mk_workspace 1 feat/something 0
  cd "$WS"
  run land-local
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to land"* ]]
}

@test "rejects a non-numeric --retries" {
  wtk_mk_workspace 1 feat/something 1
  cd "$WS"
  run land-local --retries banana
  [ "$status" -eq 2 ]
}
