.PHONY: help status check-space sync update save install build build-debug test lint finish-task prune-derived prepare recipe-test

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RECIPE := $(ROOT)/.mine/recipe.py

help:
	@echo "Tinycast (mourato fork) — main = base + .mine/patches"
	@echo "make status       Recipe and .build/source state, from the locked inputs (no fetching)"
	@echo "make prepare      Materialize or validate .build/source from the locked inputs"
	@echo "make recipe-test  Test the recipe and its command surface"
	@echo "make build        Signed Release build from .build/source (no install)"
	@echo "make build-debug  Unsigned Debug build from .build/source (Tinycast Dev)"
	@echo "make install      Release build, replace /Applications/Tinycast.app, relaunch"
	@echo "make test         Run every standalone harness from .build/source (ARGS=<harness>)"
	@echo "make lint         Lint .build/source (ARGS=--fix auto-corrects the mechanical subset)"
	@echo "make check-space  Show new Space patches / upstream commits not in main"
	@echo "make sync         Rebuild main on Space's main (tested upstream + Space patches)"
	@echo "make update       Preflight and rebuild main on newest upstream + Space patches"
	@echo "make save         Export committed .build/source edits to .mine/patches"
	@echo "make finish-task  Merge this task worktree into main, push origin/main, then clean up"
	@echo "make prune-derived  List Xcode DerivedData of deleted worktrees (ARGS=--apply removes)"

status:
	@python3 "$(RECIPE)" status

check-space:
	@git fetch --quiet space && git fetch --quiet tinycast
	@echo "== Space patch changes since main's base =="
	@git diff --stat mine-base~1 space/main -- .space || true
	@echo "== Upstream commits not yet in Space =="
	@git log --oneline "$$(git show space/main:.space/UPSTREAM)"..tinycast/main || true

sync:
	@.mine/rebuild.sh space

update:
	@.mine/rebuild.sh upstream

save:
	@python3 "$(RECIPE)" save

build:
	@python3 "$(RECIPE)" command build

build-debug:
	@python3 "$(RECIPE)" command build-debug

install:
	@python3 "$(RECIPE)" command install

test:
	@python3 "$(RECIPE)" command test $(ARGS)

lint:
	@python3 "$(RECIPE)" command lint $(ARGS)

prepare:
	@python3 "$(RECIPE)" prepare

recipe-test:
	@python3 "$(ROOT)/.mine/test-recipe.py"

finish-task:
	@./.mine/finish-task.sh

prune-derived:
	@.mine/prune-derived.sh $(ARGS)
