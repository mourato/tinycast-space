# Tinycast recipe

This repository is a build recipe for a personal variant of [Tinycast](https://github.com/abue-ammar/tinycast),
a native macOS menu-bar launcher by Abue Ammar. It holds the pins, the local patches and the commands
that build them. It does not hold Tinycast's source.

## How the source is built

The source comes from three inputs, applied in order:

1. **Upstream.** Tinycast at a pinned commit and release tag.
2. **Space.** A pinned snapshot of the Space pipeline: its `.space/` tools and its workflow files. Its
   transforms run against the upstream tree.
3. **Local patches.** Saved patches in `.mine/patches/`, applied with `git am`.

`make prepare` materializes the result in `.build/source`, a separate Git repository that is
git-ignored here. Build, test and lint run from there. Exact pins and the expected source fingerprint are
in [`.mine/sources.lock.json`](.mine/sources.lock.json).

## Prerequisites

- macOS 26 or later, with the Xcode version the pinned source requires.
- Git, Python 3, Node with `npx`, and XcodeGen.
- Network access for `make prepare`.
- For `make build` and `make install` only: a code-signing identity that matches `TINYCAST_SIGN_IDENTITY`
  (default `Apple Development`). `make build-debug` is unsigned.

## Quick start

```sh
make prepare       # materialize .build/source from the locked inputs
make build-debug   # unsigned Debug build: .build/DerivedData/Build/Products/Debug/Tinycast Dev.app
make test          # every harness in .build/source
make lint          # lint .build/source
```

Run `make help` for every target. [`.mine/README.md`](.mine/README.md) is the full reference.

## Where changes go

- **Product changes** (Swift, product tests, product docs) are edited and committed in `.build/source`.
  Then run `make save` here. It exports those commits to `.mine/patches/` and updates the lock.
  See [`AGENTS.md`](AGENTS.md) for the routing rules.
- **Recipe changes** (`Makefile`, `.mine/`, these docs, `.vscode/`, `.github/`) are ordinary commits in
  this repository.

## Updating the pins

Updates are intentional. Nothing updates on its own.

- `make check-space` reports the current and available pins. It changes nothing.
- `make update` selects the latest official Tinycast `main` and Space's maintained snapshot.
- `make sync` selects Space's maintained snapshot and the upstream release it records.

Both validate a complete candidate before they change anything. Each changes only
`.mine/sources.lock.json`. Review that diff and commit it. The existing `.build/source` stays as it was
until you run `make prepare` again.

## Legal

Tinycast is licensed under the [GNU AGPL v3](LICENSE). Third-party material is listed in
[NOTICE.md](NOTICE.md). The patches in `.mine/patches/` modify Tinycast; the terms in those two files apply.
