# Contributing

This repository is a personal build recipe for Tinycast. It holds pins, patches and build commands.
It has no product source of its own, no CI and no release process.

## Recipe changes

1. Read [`AGENTS.md`](AGENTS.md), then [`docs/agents/project-workflow.md`](docs/agents/project-workflow.md)
   and [`CODING_STANDARDS.md`](CODING_STANDARDS.md).
2. Commit on a task branch. Match the subject style of `git log`, for example
   `fix(recipe): keep save journal on failure`.
3. Run the gate for your change from the table in
   [`docs/agents/project-workflow.md`](docs/agents/project-workflow.md#validation-by-change). Report the
   exact result in the pull request.
4. Fill in [the pull request template](.github/PULL_REQUEST_TEMPLATE.md).

## Product changes

Tinycast's product code is not edited in this repository. Make changes in `.build/source`, commit them
there, and export them with `make save`. See [`.mine/README.md`](.mine/README.md#editing-the-product-source).

Bugs and feature requests for Tinycast itself belong upstream, at
[abue-ammar/tinycast](https://github.com/abue-ammar/tinycast/issues). Follow that project's rules.

## Security

See [`SECURITY.md`](SECURITY.md).

## License

[AGPL-3.0](LICENSE). Third-party material is listed in [NOTICE.md](NOTICE.md).
