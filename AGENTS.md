# Tinycast recipe

This repository builds Tinycast from locked inputs. It does not hold product source. The product
source is materialized into `.build/source`, a separate Git repository, which is git-ignored here.

## Commands

The root `Makefile` is the command authority. Run its targets from the repository root, for example
`make build-debug`. Run `make help` for the list. Do not call `.mine/recipe.py` directly except where a
doc names it.

## Where a change goes

| Change | Where | How |
| --- | --- | --- |
| Recipe tooling, docs, editor config, `Makefile`, `.github/` | Root | Ordinary root commit on the task branch. |
| Pins, patches, `.mine/sources.lock.json` | Root, written by commands | Never edit by hand. `make save` writes patches; `make update` and `make sync` write the lock. |
| Product Swift, tests, product docs | `.build/source` | Run `make prepare`, then read `.build/source/AGENTS.md`. Edit and commit in `.build/source`, then run `make save` at root. |

Product invariants live in `.build/source/AGENTS.md` and its `docs/`. This file does not restate them.

## Read first

- [docs/agents/project-workflow.md](docs/agents/project-workflow.md): lifecycle, artifacts, validation.
- [CODING_STANDARDS.md](CODING_STANDARDS.md): review rules for recipe changes.
- [.mine/README.md](.mine/README.md): command reference and recovery.

## Owners

Each concept has one owner. Do not add a second.

- **Pins:** `.mine/sources.lock.json`. `load_lock` in `.mine/recipe.py` reads it. It names the upstream,
  the Space snapshot and the expected source fingerprint.
- **Source fingerprint:** `source_fingerprint` in `.mine/recipe.py`. It hashes the tracked source tree,
  excluding `.mine/` and `Makefile`. Lock and receipt must agree on it.
- **Prepare receipt:** `tinycast-recipe-receipt.json` in the source's `.git` directory, written by
  `receipt_bytes` and checked by `validate_receipt`.
- **Operation lock:** `RecipeLock` on `.build/.recipe.lock`. Prepare, build, test, lint, install, save,
  sync, update and check-space take it. `status` tries it without blocking and reports a busy operation.
- **Save:** `save` in `.mine/recipe.py` is the only path from `.build/source` to `.mine/patches/` and the
  lock.

Tests that enforce these owners: `.mine/test-recipe.py`, run with `make recipe-test`.
