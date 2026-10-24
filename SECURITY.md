# Security policy

This repository holds build inputs and commands. It has no product code of its own and runs no service.
It is not a supported distribution of Tinycast, and it makes no response or support commitment.

## Reporting

- **Tinycast itself**, the app and its upstream code: report to the upstream project,
  [abue-ammar/tinycast](https://github.com/abue-ammar/tinycast), through its own security policy. After
  `make prepare`, that policy is in `.build/source/SECURITY.md`.
- **This recipe**: the pins, the patches, `Makefile` and `.mine/`. Do not open a public issue or pull
  request. If this repository offers private vulnerability reporting, use it. Otherwise, arrange a private
  channel with the repository owner before you share details. Include the affected file, the command and
  the impact.

## Scope

A patch in `.mine/patches/` can change how upstream behaves, including code that handles the clipboard,
accessibility permissions or network access. Treat such a patch as product code when you assess it.
