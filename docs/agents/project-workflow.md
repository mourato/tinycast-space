# Project workflow

For agents and contributors changing this recipe. The command reference is
[`.mine/README.md`](../../.mine/README.md). This page covers what to change, what to keep, and what to
run.

## Constraints

- The `Makefile` is the only command surface. Add no wrapper scripts. Change a target only when the
  change is the target's purpose.
- `.mine/recipe.py` is the only writer of the lock, the patches and the source receipt. Edit it only
  with a recipe change, and run `make recipe-test` after.
- Do not hand-edit `.mine/sources.lock.json` or `.mine/patches/`. Use `make update` or `make save`.
- Edit product code in `.build/source` directly. Commit product changes there, then export them with
  `make save`. A dirty source is not exportable.
- Product behaviour is owned by `.build/source`: its tests, lint rules and invariants live there. Exported
  product patches are part of this repository's purpose. Recipe changes (`Makefile`, `.mine/`, docs) are
  root commits and stay separate from those patches.

## Ownership and save lifecycle

1. `prepare` materializes `.build/source` from the lock: the upstream commit, then the patches.
   It writes a receipt into the source's `.git` directory.
2. A product edit is a commit in `.build/source`. A dirty tree is not exportable.
3. `save` checks the committed work against the receipt, replays it independently, and publishes the
   patches, lock and receipt as one transaction.
4. `save` commits `.mine/patches/` and `.mine/sources.lock.json` only, when they changed.
5. Root tooling and docs are ordinary commits. They never become patches.

## Artifacts to keep

These hold data that may not exist anywhere else. Keep them until the work is saved or copied out.

- `.build/source/`, including ignored files and its local Git metadata.
- `.build/source/.git/tinycast-recipe-receipt.json`, the record `save` uses.
- `.build/.source-backup-*`, the predecessors of replaced sources.
- `.build/.source-save-journal.json` and any `.build/.source-*` directories, which hold an interrupted save.

Logs in `.build/logs/` and the DerivedData in `.build/DerivedData/` are rebuilt. Keep them only as
evidence for a failed run.

## Validation by change

Run the smallest gate that covers the change. Report every result, including failures.

| Change | Gate |
| --- | --- |
| Docs, `.vscode/`, `.github/`, `Makefile` help text | Read the links and paths. Parse each JSON file. `git diff --check`. |
| `Makefile` targets or `.mine/recipe.py`, `test-recipe.py` | `make recipe-test` |
| Lock or patches | `make prepare` on a clean clone, then `make build-debug`. |
| Product source (`.build/source`) | `make test` and `make lint`, then `make build-debug`. |

`make status` reports the receipt state. It does not validate. A stale receipt after a lock change is
expected until `make prepare` runs.

## Editor setup

The root `.vscode/` configures the recipe workspace: tasks call `make -C` on the root, and the launch
configuration runs the Debug product in `.build/`. SourceKit-LSP needs a workspace that contains the
Swift sources. Open `.build/source` for that, and follow its `.vscode/` and `docs/development.md`.
