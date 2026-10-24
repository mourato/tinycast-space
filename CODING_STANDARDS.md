# Coding standards: recipe

Review rules for changes to this repository. They add to the shared standards at
`${AGENT_CONFIG_HOME:-$HOME/.agents}/core/standards/CODING_STANDARDS.md`. Product Swift rules live in
`.build/source/docs/standards.md`, after `make prepare`.

## Review rules

- **The Makefile is the command authority.** Docs and editor tasks call `make` targets. They do not
  duplicate a script's steps.
- **One owner per fact.** Pins live in the lock. Command behaviour lives in `recipe.py`. Do not
  restate either in other files. Link to them.
- **Document only what the code does.** Each path, target and name in a doc must exist. Check it before
  you commit.
- **No generated file is edited by hand.** That covers the lock, `.mine/patches/` and anything under
  `.build/`.
- **Keep data safe.** Do not add a command or instruction that deletes `.build/source`, a
  `.source-backup-*` directory or a save journal. Such removal needs an explicit decision.
- **Config is strict JSON.** No comments and no trailing commas in `.vscode/` or other JSON files.
- **Keep the diff small.** One concern per commit. Unrelated cleanup goes in a separate commit.

## Shell and Python

- Shell scripts use `set -euo pipefail` and quote every expansion.
- Python in `.mine/` stays standard library only. Keep it compatible with the Python 3 that macOS
  provides.
- Errors name the path or command that failed. Stop on the first error. Do not swallow it.
