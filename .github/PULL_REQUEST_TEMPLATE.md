## What changed

<!-- Recipe files (Makefile, .mine/, docs, .vscode), or saved patches under .mine/patches/ and the lock. -->

## Source and lock

- [ ] `.mine/sources.lock.json` unchanged, or the change is an intentional `make update` / `make sync`
- [ ] Patches changed only through `make save`

## Validation

<!-- Commands run and their exact result. Paste the shortest decisive line, not the full log. -->

- [ ] `make recipe-test`
- [ ] `make prepare` on a clean clone, then `make build-debug` (only when patches or lock changed)
- [ ] Other:
