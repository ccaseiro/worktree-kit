#!/usr/bin/env bats
#
# The argument parsers. These exist as scripts, not markdown, precisely so
# these assertions can run: Claude Code splices the user's raw text into the
# slash command before any shell sees it, and one of these flags drives rm -rf.

load helpers/repo

setup() { wtk_new_tmp; wtk_mk_repo develop; }
teardown() { wtk_teardown; }

nta() { printf '%s' "$1" | next-task-args; }
sla() { printf '%s' "$1" | ship-land-args; }

# ---- next-task-args --------------------------------------------------------

@test "flags and a description are separated" {
  run nta "add CSV export --fresh"
  [[ "$output" == *"FRESH=yes"* ]]
  [[ "$output" == *"DESC=add\\ CSV\\ export"* ]]
}

@test "shell metacharacters in a description are never executed" {
  # The whole reason the raw string arrives on stdin.
  run nta 'fix $(touch '"$TESTDIR"'/PWNED) and `rm -rf /` bug'
  [ "$status" -eq 0 ]
  [ ! -e "$TESTDIR/PWNED" ]
  [[ "$output" == *'PWNED'* ]]   # kept as literal text
}

@test "a description survives eval as one string" {
  run bash -c "eval \"\$(printf '%s' 'corrigir o 500 (criar & guardar)' | next-task-args)\"; printf '%s' \"\$DESC\""
  [ "$status" -eq 0 ]
  [ "$output" = "corrigir o 500 (criar & guardar)" ]
}

@test "a glob in a description stays literal" {
  run bash -c "eval \"\$(printf '%s' 'clean /opt/*' | next-task-args)\"; printf '%s' \"\$DESC\""
  [ "$output" = "clean /opt/*" ]
}

@test "slug= is extracted" {
  run nta "slug=my-task some words"
  [[ "$output" == *"SLUG=my-task"* ]]
}

@test "a bare /skill does NOT route when the project listed none" {
  # Empty TASK_ENTRY_SKILLS is the default, and it must mean "never route".
  run nta "/investigate the login bug"
  [[ "$output" == *"VIA=''"* ]]
  [[ "$output" == *"investigate"* ]]   # it stays part of the description
}

@test "a bare /skill routes only to a name the project listed" {
  wtk_conf 'TASK_ENTRY_SKILLS="investigate qa"'
  run nta "/investigate"
  [[ "$output" == *"VIA=investigate"* ]]
}

@test "a bare /skill not on the allowlist stays description text" {
  wtk_conf 'TASK_ENTRY_SKILLS="investigate"'
  run nta "/deploy"
  [[ "$output" == *"VIA=''"* ]]
}

@test "a /skill name with unexpected characters never routes" {
  wtk_conf 'TASK_ENTRY_SKILLS="investigate"'
  run nta '/investigate;rm'
  [[ "$output" == *"VIA=''"* ]]
}

@test "an explicit via= wins over a bare shorthand, in any order" {
  wtk_conf 'TASK_ENTRY_SKILLS="investigate qa"'
  run nta "/investigate via=qa"
  [[ "$output" == *"VIA=qa"* ]]
  run nta "via=qa /investigate"
  [[ "$output" == *"VIA=qa"* ]]
}

@test "a bare via= suppresses the shorthand rather than reading as absent" {
  wtk_conf 'TASK_ENTRY_SKILLS="investigate"'
  run nta "/investigate via="
  [[ "$output" == *"VIA=''"* ]]
}

@test "the shorthand does not route once a description has started" {
  wtk_conf 'TASK_ENTRY_SKILLS="investigate"'
  run nta "the login bug /investigate"
  [[ "$output" == *"VIA=''"* ]]
}

@test "refuses input passed as argv instead of stdin" {
  run next-task-args "some args"
  [ "$status" -eq 2 ]
  [[ "$output" == *"stdin"* ]]
}

# ---- ship-land-args --------------------------------------------------------

@test "--steal alone arms the steal" {
  run sla "--steal"
  [[ "$output" == *"STEAL=--steal"* ]]
}

@test "--steal beside an unrecognized token is DISARMED" {
  # "/ship-land don't --steal" must never reach an rm -rf.
  run sla "don't --steal"
  [[ "$output" == *"STEAL=''"* ]]
  [[ "$output" == *"IGNORED"* ]]
}

@test "a typo next to --steal disarms it too" {
  run sla "--steal --forse"
  [[ "$output" == *"STEAL=''"* ]]
}

@test "skip-tests beside an unrecognized token is DISARMED" {
  run sla "skip-tests please"
  [[ "$output" == *"SKIP_TESTS=no"* ]]
  [[ "$output" == *"IGNORED"* ]]
}

@test "recognized flags together do not disarm each other" {
  run sla "--steal skip-tests no-merge"
  [[ "$output" == *"STEAL=--steal"* ]]
  [[ "$output" == *"SKIP_TESTS=yes"* ]]
  [[ "$output" == *"NO_MERGE=yes"* ]]
}

@test "pr-only is an alias for no-merge" {
  run sla "pr-only"
  [[ "$output" == *"NO_MERGE=yes"* ]]
}

@test "unknown tokens are reported back" {
  run sla "banana"
  [[ "$output" == *"UNKNOWN_TOKENS=banana"* ]]
}

@test "shell metacharacters are not executed here either" {
  run sla '$(touch '"$TESTDIR"'/PWNED2)'
  [ ! -e "$TESTDIR/PWNED2" ]
}

@test "an empty argument string is not an error" {
  run sla ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"STEAL=''"* ]]
}
