.PHONY: help status check-space sync update save install build test

help:
	@echo "Tinycast (mourato fork) — main = base + .mine/patches"
	@echo "make status       Where main stands vs Space and upstream"
	@echo "make check-space  Show new Space patches / upstream commits not in main"
	@echo "make sync         Rebuild main on Space's main (tested upstream + Space patches)"
	@echo "make update       Rebuild main on newest upstream + Space patches applied locally"
	@echo "make save         Export commits since mine-base to .mine/patches"
	@echo "make build        Signed Release build only (no install)"
	@echo "make install      Release build, replace /Applications/Tinycast.app, relaunch"
	@echo "make test         Upstream test harnesses"

status:
	@git fetch --quiet space; git fetch --quiet tinycast
	@echo "main base:   $$(git log -1 --format='%h %s' mine-base~1 2>/dev/null || echo 'no mine-base')"
	@echo "space/main:  $$(git log -1 --format='%h %s' space/main)"
	@echo "upstream:    $$(git log -1 --format='%h %s' tinycast/main)"
	@echo "my patches:  $$(git rev-list --count mine-base..HEAD -- . ':!.mine' ':!Makefile' 2>/dev/null || echo 0)"

check-space:
	@git fetch --quiet space; git fetch --quiet tinycast
	@echo "== Space patch changes since main's base =="
	@git diff --stat mine-base~1 space/main -- .space || true
	@echo "== Upstream commits not yet in Space =="
	@git log --oneline "$$(git show space/main:.space/UPSTREAM)"..tinycast/main || true

sync:
	@.mine/rebuild.sh space

update:
	@.mine/rebuild.sh upstream

save:
	@.mine/save-patches.sh

build:
	@.mine/build.sh

install:
	@.mine/install.sh

test:
	@./Scripts/run-tests.sh
