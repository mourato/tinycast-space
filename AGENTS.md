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
| Pins, patches, `.mine/sources.lock.json` | Root, written by commands | Never edit by hand. `make save` writes patches; `make update` writes the lock. The one exception is `.mine/space-radar.json`, edited by hand; see `.mine/README.md`. |
| Product Swift, tests, product docs | `.build/source` | Run `make prepare`, then read `.build/source/AGENTS.md`. Edit and commit in `.build/source`, then run `make save` at root. |

Product invariants live in `.build/source/AGENTS.md` and its `docs/`. This file does not restate them.

## Read first

- Before a change to lifecycle, artifacts, or validation, read
  [docs/agents/project-workflow.md](docs/agents/project-workflow.md).
- Before a review of recipe changes, read [CODING_STANDARDS.md](CODING_STANDARDS.md).
- Before a command, a pin update, or a save recovery, read [.mine/README.md](.mine/README.md).

## Canonical abstractions

Each invariant has one owner. Do not add a second. Run `make recipe-test` after any change to these
owners.

- Pins: `load_lock` in `.mine/recipe.py`; use instead of parsing `.mine/sources.lock.json` directly;
  enforced by `test_malformed_lock_and_symlink_are_rejected` in `.mine/test-recipe.py`.
- Source fingerprint: `source_fingerprint` in `.mine/recipe.py`; use instead of hashing the source tree
  by hand; enforced by `test_prepare_materializes_new_pin_then_save_preserves_fingerprint`.
- Prepare receipt: `receipt_bytes` writes and `validate_receipt` checks `tinycast-recipe-receipt.json`
  in the source's `.git` directory; use instead of editing it; enforced by
  `test_missing_receipt_and_non_descendant_source_are_rejected`.
- Operation lock: `RecipeLock` on `.build/.recipe.lock`; use instead of running an operation without it;
  enforced by `test_install_holds_lock_until_worker_finishes` and
  `test_command_reuses_dirty_source_and_holds_lock_during_tool`.
- Save: `save` in `.mine/recipe.py`; use instead of exporting patches or copying files into
  `.mine/patches/` by hand; enforced by `test_save_exports_committed_source_and_preserves_unrelated_index`
  and `test_save_rejects_dirty_source_and_stale_authoritative_inputs`.
