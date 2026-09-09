#!/usr/bin/env bats
#
# wtkit_inherit_env_keys — copies secrets from the main checkout's .env into a
# worktree's. Two of these are REGRESSION tests: the behaviour they pin was
# broken, shipped, and fixed, and nothing else would notice it breaking again.

load helpers/repo

setup() {
  wtk_new_tmp; wtk_mk_repo develop
  MAIN_ENV="$REPO/.env"; WT_ENV="$TESTDIR/wt.env"
}
teardown() { wtk_teardown; }

inherit() {  # <INHERIT_ENV_KEYS>
  bash -c "set -euo pipefail; source '$WTKIT_LIB/common.sh'
           MAIN_ROOT='$REPO'; INHERIT_ENV_KEYS='$1'
           wtkit_inherit_env_keys '$WT_ENV'"
}

@test "REGRESSION: an existing key is replaced and the file keeps its mode" {
  # .env holds inherited secrets. The rewrite used to create its temp with the
  # default umask, so a 600 file came back 644.
  printf 'SECRET=from-main\n' > "$MAIN_ENV"
  printf 'COMPOSE_PROJECT_NAME=p\nSECRET=old\n' > "$WT_ENV"
  chmod 600 "$WT_ENV"
  run inherit SECRET
  [ "$status" -eq 0 ]
  grep -q '^SECRET=from-main$' "$WT_ENV"
  grep -q '^COMPOSE_PROJECT_NAME=p$' "$WT_ENV"
  [ "$(stat -f '%Lp' "$WT_ENV" 2>/dev/null || stat -c '%a' "$WT_ENV")" = "600" ]
}

@test "REGRESSION: a key absent from the main .env is skipped, not fatal" {
  # grep exits 1 on no match and every bin/ caller runs `set -euo pipefail`, so
  # this used to abort the whole worktree setup — but only when the missing key
  # was LAST, which is why it survived so long.
  printf 'SECRET=from-main\n' > "$MAIN_ENV"
  printf 'SECRET=old\n' > "$WT_ENV"
  run inherit "SECRET MISSING_KEY"
  [ "$status" -eq 0 ]
  grep -q '^SECRET=from-main$' "$WT_ENV"
}

@test "REGRESSION: a missing key as the ONLY key is not fatal either" {
  printf 'SECRET=x\n' > "$MAIN_ENV"
  printf 'A=1\n' > "$WT_ENV"
  run inherit MISSING_ONLY
  [ "$status" -eq 0 ]
}

@test "a value containing & and backslashes is written literally" {
  # Not sed: & is replacement syntax there, and awk -v would eat the escapes.
  printf 'SECRET=a&b\\nc\n' > "$MAIN_ENV"
  printf 'SECRET=old\n' > "$WT_ENV"
  run inherit SECRET
  [ "$status" -eq 0 ]
  [ "$(grep '^SECRET=' "$WT_ENV")" = 'SECRET=a&b\nc' ]
}

@test "a key not yet in the worktree .env is appended" {
  printf 'NEWKEY=v\n' > "$MAIN_ENV"
  printf 'A=1\n' > "$WT_ENV"
  run inherit NEWKEY
  [ "$status" -eq 0 ]
  grep -q '^NEWKEY=v$' "$WT_ENV"
  grep -q '^A=1$' "$WT_ENV"
}

@test "no temp files are left behind" {
  printf 'SECRET=x\n' > "$MAIN_ENV"
  printf 'SECRET=old\n' > "$WT_ENV"
  run inherit SECRET
  run bash -c "ls '$TESTDIR'/wt.env.wtkit* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "does nothing when INHERIT_ENV_KEYS is unset" {
  printf 'SECRET=x\n' > "$MAIN_ENV"
  printf 'A=1\n' > "$WT_ENV"
  run bash -c "set -euo pipefail; source '$WTKIT_LIB/common.sh'
               MAIN_ROOT='$REPO'; wtkit_inherit_env_keys '$WT_ENV'"
  [ "$status" -eq 0 ]
  [ "$(cat "$WT_ENV")" = "A=1" ]
}
