.PHONY: help status check-space update save install build build-debug test lint finish-task prune-derived prepare recipe-test

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RECIPE := $(ROOT)/.mine/recipe.py

help:
	@echo "Tinycast recipe — builds .build/source from the locked upstream and .mine/patches inputs"
	@echo "make status       Recipe and .build/source state, from the locked inputs (no fetching)"
	@echo "make prepare      Materialize or validate .build/source from the locked inputs"
	@echo "make recipe-test  Test the recipe and its command surface"
	@echo "make build        Signed Release build from .build/source (no install)"
	@echo "make build-debug  Unsigned Debug build from .build/source (Tinycast Dev)"
	@echo "make install      Release build, replace /Applications/Tinycast.app, relaunch"
	@echo "make test         Run every standalone harness from .build/source (ARGS=<harness>)"
	@echo "make lint         Lint .build/source (ARGS=--fix auto-corrects the mechanical subset)"
	@echo "make check-space  Show the Space radar URL and adopted commit"
	@echo "make update       Select official Tinycast main and its reachable release tag"
	@echo "make save         Export committed .build/source edits to .mine/patches"
	@echo "make finish-task  Merge this task worktree into main, push origin/main, then clean up"
	@echo "make prune-derived  List Xcode DerivedData of deleted worktrees (ARGS=--apply removes)"

status:
	@python3 "$(RECIPE)" status

check-space:
	@python3 "$(RECIPE)" check-space

update:
	@python3 "$(RECIPE)" update

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
