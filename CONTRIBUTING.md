# Contributing to pux

Thanks for helping! Bug reports, bank OTP formats that don't parse, and pull requests are all welcome.

- **Security issues:** don't open an issue. Follow [SECURITY.md](SECURITY.md).
- **Conduct:** this project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
- **Licence:** pux is AGPL-3.0. By contributing you agree your contribution is licensed under the same terms.

## Before you start

For anything bigger than a small fix, open an issue first so we can agree on the approach. Changes
that touch the security model (keys, the record credential, what the server stores or logs, sender
verification) need a design discussion before code.

## Repository layout

| Path | What |
|------|------|
| `server/` | Phoenix/Elixir service: inbound SMTP, OTP parsing, DKIM, HTTP API, push |
| `mobile/` | Flutter app for Android, iOS, macOS and Linux, plus the iOS notification service extension |
| `deploy/` | Docker Compose setup for self-hosting |
| `brand/` | Logo sources and identity guide; `scripts/render-brand.sh` renders the PNGs from them |
| `.github/` | CI, release workflow, Dependabot |

## Toolchains

From the repo root, [mise](https://mise.jdx.dev) installs pinned Erlang/OTP, Elixir, Flutter, and JDK 17:

```bash
mise install
mise run setup
```

See [`mise.toml`](mise.toml). `mise run setup` installs hk git hooks (Elixir/Dart format checks and `jactionlint` on workflows). Use `hk check` before pushing; full `mix test` / `flutter test` remain CI and manual.

You still need PostgreSQL, libsodium, and per-platform mobile SDKs.

## Server

```bash
cd server
mix deps.get
mix test
```

- Tests read `DATABASE_URL` (default `postgres://postgres:postgres@localhost/pux_test`).
- They start a real HTTP endpoint on port 4002 and an SMTP listener on 2526. Override these with `PUX_TEST_HTTP_PORT` and `PUX_TEST_SMTP_PORT` if those ports are taken.
- On macOS with Homebrew, enacl needs to find libsodium: `export CFLAGS=-I/opt/homebrew/include LDFLAGS=-L/opt/homebrew/lib`.
- Tests never touch the network: DKIM key lookups go through `Pux.DKIMTestResolver`, and FCM is disabled.

CI runs these checks, so run them before pushing:

```bash
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
mix test
mix deps.audit
mix sobelow --exit medium
```

### Adding a bank

OTP parsing lives in `server/lib/pux/otp_parser.ex`. To label a new bank, add its sending domains to `@senders`. Only add domains the bank actually sends from, since the label is only shown when DKIM verifies.

A test with a representative (anonymised) email body is the most useful part of such a PR. Remove names, account numbers and real codes before committing any sample.

## Mobile

Flutter comes from mise (same stable line CI uses). Building for a platform also needs that platform's toolchain: Android SDK, Xcode for iOS and macOS, and CocoaPods for macOS.

```bash
cd mobile
flutter pub get
flutter analyze
flutter test
```

Point the app at a local server with `--dart-define=PUX_SERVER_URL=http://10.0.2.2:4000` (Android emulator) or `http://localhost:4000`. Firebase setup and iOS push are described in the [README](README.md#mobile).

If you change the iOS notification service extension's target or build settings, edit `mobile/ios/scripts/add_notification_service.rb` and re-run it rather than editing `project.pbxproj` by hand.

## Pull requests

- Keep each PR focused, with tests for every behaviour change.
- Use [Conventional Commits](https://www.conventionalcommits.org/) with a scope, as in the existing history: `fix(smtp): …`, `feat(mobile): …`, `docs: …`, `chore(ci): …`.
- Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for anything user-visible.
- Never commit secrets, real OTP emails, keystores or `key.properties`. Firebase client config (`google-services.json`, `GoogleService-Info.plist`) is not secret and is committed on purpose.

## Releases (maintainers)

1. Move the **Unreleased** entries in `CHANGELOG.md` under a new `## [x.y.z] - YYYY-MM-DD` heading.
2. Set the same version in `server/mix.exs` (`version:`) and `mobile/pubspec.yaml` (`version: x.y.z+<build>`, with the build number incremented).
3. Commit, then tag and push: `git tag -s vx.y.z -m vx.y.z && git push origin vx.y.z`.

The `release` workflow checks that the tag matches both versions. It then publishes the server image as `ghcr.io/vidurb/pux-server:x.y.z`, builds a signed Android APK and AAB plus macOS and Linux bundles, and creates a GitHub Release with the changelog section as notes. Tags with a suffix such as `v0.2.0-rc.1` become pre-releases. The same tag also triggers the `testflight` workflow, which uploads an iOS build to TestFlight (setup in [mobile/ios/README.md](mobile/ios/README.md#testflight)).
