#!/usr/bin/env bats
#
# "origin" is a convention, not a rule. A repo cloned with -o upstream, or set
# up by hand against a non-GitHub forge, has never had one.

load helpers/repo

setup() { wtk_new_tmp; wtk_mk_repo develop; }
teardown() { wtk_teardown; }

resolve_remote() { bash -c "source '$WTKIT_LIB/common.sh'; wtkit_resolve_remote '$REPO'"; }

@test "defaults to origin" {
  run resolve_remote
  [ "$output" = "origin" ]
}

@test "git config wtkit.remote wins" {
  git -C "$REPO" remote add upstream "$REMOTE"
  git -C "$REPO" config wtkit.remote upstream
  run resolve_remote
  [ "$output" = "upstream" ]
}

@test "REMOTE_NAME from the conf is honoured" {
  git -C "$REPO" remote add upstream "$REMOTE"
  run bash -c "source '$WTKIT_LIB/common.sh'; REMOTE_NAME=upstream wtkit_resolve_remote '$REPO'"
  [ "$output" = "upstream" ]
}

@test "a sole remote not called origin is detected without configuration" {
  # `git clone -o upstream` has never had an origin. Before this the whole kit
  # measured everything against a remote that does not exist.
  git -C "$REPO" remote rename origin upstream
  run resolve_remote
  [ "$output" = "upstream" ]
}

@test "the sole-remote rule never overrides an existing origin" {
  git -C "$REPO" remote add upstream "$REMOTE"
  run resolve_remote
  [ "$output" = "origin" ]
}

@test "a bare remote.origin.* in the user's global config does not mask a real remote" {
  # remote.origin.tagopt=--tags in ~/.gitconfig makes `git remote` list origin
  # in every repo, with no URL behind it. Checking presence rather than a URL
  # meant the sole-remote rescue never fired on such a machine.
  git -C "$REPO" remote rename origin upstream
  git -C "$REPO" config remote.origin.tagopt --tags   # listed, but no URL
  run bash -c "git -C '$REPO' remote | tr '\n' ' '"
  [[ "$output" == *"origin"* ]]                        # git does list it
  run resolve_remote
  [ "$output" = "upstream" ]                           # and we see through it
}

@test "a repo with no remotes at all still answers origin" {
  wtk_mk_repo_no_remote
  run resolve_remote
  [ "$output" = "origin" ]
}

@test "base resolution follows the renamed remote end to end" {
  git -C "$REPO" remote rename origin upstream
  git -C "$REPO" remote set-head upstream --auto >/dev/null 2>&1
  run bash -c "cd '$REPO' && wtconf --agent 2>/dev/null"
  [[ "$output" == *"REMOTE_NAME=upstream"* ]]
  [[ "$output" == *"BASE_REF=upstream/develop"* ]]
  [[ "$output" == *"BASE_ON_REMOTE=1"* ]]
}

