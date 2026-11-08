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

**Mobile checks** (from `mobile/`):

```bash
flutter analyze
flutter test
```

CI workflows (`.github/workflows/server.yml`, `mobile.yml`) still install their own toolchains; switching them to `jdx/mise-action` is optional follow-up.
