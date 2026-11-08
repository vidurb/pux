# Agent setup

After cloning, install toolchains with [mise](https://mise.jdx.dev):

```bash
mise install
mise run setup
```

Versions live in [`mise.toml`](mise.toml). PostgreSQL must be running for server tests (`DATABASE_URL`, default `postgres://postgres:postgres@localhost/pux_test`).

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
