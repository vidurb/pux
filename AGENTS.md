# Agent setup

After cloning, install toolchains with [mise](https://mise.jdx.dev):

```bash
mise install
mise run setup
```

Versions live in [`mise.toml`](mise.toml). `mise run setup` installs hk hooks from [`hk.pkl`](hk.pkl). Fast local checks: `hk check` (or rely on pre-commit). Workflow lint uses `jactionlint --profile correctness` (pedantic policy rules are a CI follow-up).

PostgreSQL must be running for server tests (`DATABASE_URL`, default `postgres://postgres:postgres@localhost/pux_test`).

**Server checks** (from `server/`):

```bash
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
mix test
```

**Native checks:** see [native/README.md](native/README.md) and the platform READMEs.

CI workflows (`.github/workflows/server.yml`, `native.yml`) still install their own toolchains; switching them to `jdx/mise-action` is optional follow-up.

# Commit messages and PR titles

[release-please](release-please-config.json) reads commit messages on `main` to choose the next version and write `CHANGELOG.md`, so every commit message and PR title must be a [Conventional Commit](https://www.conventionalcommits.org/):

```text
type(scope): summary
```

- **Type** decides the release. Before 1.0, `feat` raises the minor version, and `fix` and `perf` raise the patch. `revert` is accepted too. `docs`, `refactor`, `test`, `build`, `ci`, `chore` and `style` don't release and stay out of the changelog. Pick by effect on users: a security fix is `fix`, a CI-only change is `ci`, and dependency updates that ship are `fix(deps)`.
- **Scope** is optional but expected. Use one already in the history: `server`, `mobile`, `ios`, `android`, `macos`, `linux`, `smtp`, `api`, `push`, `web`, `ci` or `deps`.
- **Summary** is lowercase, imperative and has no trailing period. It becomes the changelog line, so describe the change for users rather than the files: `fix(mobile): keep held codes after a restart`, not `fix: update home_screen.dart`.
- **Breaking changes:** add `!` after the type and a `BREAKING CHANGE: …` footer explaining the migration, for example an API, enrollment or payload change that older apps or servers can't handle.
- **Body** (optional) explains why. Wrap it at 72 characters.

Keep the PR title in the same format, because PRs are squash-merged with the title as the commit message. A one-commit PR is squashed with its commit message instead, so that message must match the title exactly. The `pr-title` workflow checks both.

Don't edit `CHANGELOG.md`, the `version:` in `server/mix.exs`, or `.release-please-manifest.json` by hand; the release PR does that. The exception is cutting v0.1.0 (CONTRIBUTING.md).

The hk `commit-msg` hook rejects messages that don't parse. `mise run setup` installs it; in an existing checkout run `hk install --mise` once. If a commit is rejected, fix the message and commit again. Don't bypass the hook with `--no-verify` or `HK=0`.
