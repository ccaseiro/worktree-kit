# worktree-kit — test entry point.
#
# The suite is bats-core. It is NOT vendored into the repo: `make bootstrap`
# clones it into tests/vendor/ (gitignored), so a fresh checkout needs no brew,
# no npm, no root, and no submodule ceremony. A system bats on PATH wins if you
# have one.

BATS_VENDOR := tests/vendor/bats-core/bin/bats
BATS := $(shell command -v bats 2>/dev/null || echo $(BATS_VENDOR))

.PHONY: test bootstrap clean-vendor

test:
	@if [ ! -x "$(BATS)" ] && ! command -v bats >/dev/null 2>&1; then \
	  echo "bats not found. Run 'make bootstrap' (clones bats-core into"; \
	  echo "tests/vendor/), or install it yourself: brew install bats-core"; \
	  exit 1; \
	fi
	@$(BATS) --print-output-on-failure tests/

bootstrap:
	@if command -v bats >/dev/null 2>&1; then \
	  echo "bats is already on PATH ($$(command -v bats)) — nothing to do."; \
	else \
	  mkdir -p tests/vendor; \
	  if [ -d tests/vendor/bats-core ]; then \
	    echo "tests/vendor/bats-core already present."; \
	  else \
	    git clone --depth 1 https://github.com/bats-core/bats-core.git tests/vendor/bats-core; \
	  fi; \
	  echo "Bootstrapped. Run 'make test'."; \
	fi

clean-vendor:
	rm -rf tests/vendor
