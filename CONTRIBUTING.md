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

### Bumping Elixir, OTP and Alpine

Dependabot can't do this for you. It skips `hexpm/elixir` (the image has too many tags to list) and only proposes Alpine patch updates for the runtime stage (see `.github/dependabot.yml`). Check for new versions by hand every month or two, and whenever an OTP or Alpine security release comes out.

**Keep OTP at 29.1 or newer on Alpine 3.24 or newer.** Alpine 3.24 ships musl 1.2.6, which rejects a signal stack smaller than the host's minimum. OTP before 29.1 gives the VM a fixed 8192-byte signal stack, so on Intel hosts with AMX (`amx_tile` in `/proc/cpuinfo`, where musl wants about 13 KB) the release aborts on every start. OTP 29.1 sizes the stack from the host's minimum ([erlang/otp#11376](https://github.com/erlang/otp/pull/11376)); the backport to OTP 27 ([erlang/otp#11810](https://github.com/erlang/otp/pull/11810)) hadn't been merged when we moved. The details are in [#38](https://github.com/vidurb/pux/issues/38). Until that move the image stayed on Alpine 3.23 and the `image` job in `server.yml` failed if either stage had musl 1.2.6 or newer. That check is gone now that the image's OTP has the fix, so nothing in CI stops a downgrade to an older OTP on a current Alpine: don't do it. Only about 1 GitHub runner in 10 exposes AMX, so a passing boot test doesn't prove the AMX case. The `image` job's "Host CPU" step prints whether the run landed on an AMX host; look for `host has AMX` when you need that proof.

To bump:

1. Find a `hexpm/elixir` tag for the Elixir and OTP you want on the current Alpine release. Tags look like `1.20.5-erlang-29.1.2-alpine-3.24.4`. Search the [tag list on Docker Hub](https://hub.docker.com/r/hexpm/elixir/tags) with a filter such as `1.20.5-erlang-29.1`, or ask the API, which filters by substring:

   ```bash
   curl -s 'https://hub.docker.com/v2/repositories/hexpm/elixir/tags?page_size=100&name=1.20.5-erlang-29.1' |
     jq -r '.results[].name' | grep -- '-alpine-3\.24\.' | sort -V | tail
   ```

2. Keep both Dockerfile stages on the same Alpine release. The runtime stage links against the build stage's libsodium, OpenSSL and ncurses, so `FROM hexpm/elixir:…-alpine-3.24.x` and `FROM alpine:3.24.y` move together (patch versions may differ).
3. Keep the versions aligned everywhere they're pinned:
   - `server/Dockerfile`: the `hexpm/elixir` tag (exact OTP patch, for example `29.1.2`).
   - `mise.toml`: `erlang` and `elixir` (for example `29.1.2` and `1.20.5-otp-29`).
   - `.github/workflows/server.yml`: `otp-version` and `elixir-version` for `erlef/setup-beam` in the `test` job.

   mise and CI may pin a shorter OTP version than the Dockerfile, but they must be on the same Elixir release and OTP major and minor version.
4. Open a PR (`fix(server): …`, since the image ships). The `image` job builds and smoke-tests the image on amd64 and arm64.

## Mobile

Flutter comes from mise (same stable line CI uses). Building for a platform also needs that platform's toolchain: Android SDK, and Xcode for iOS and macOS. Every iOS and macOS plugin is a Swift package, so neither build needs CocoaPods.

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

The `release` workflow checks that the tag matches both versions. It then publishes the server image as `ghcr.io/vidurb/pux-server:x.y.z`, builds a signed Android APK and AAB, a signed and notarized macOS disk image (setup in [mobile/macos/README.md](mobile/macos/README.md#one-time-setup)) and a Linux `.deb` and tarball ([mobile/linux/README.md](mobile/linux/README.md)), and creates a GitHub Release with the changelog section as notes. Running the workflow by hand builds everything without publishing, to check signing before a tag. Tags with a suffix such as `v0.2.0-rc.1` become pre-releases. The same tag also triggers the `testflight` workflow, which uploads an iOS build to TestFlight (setup in [mobile/ios/README.md](mobile/ios/README.md#testflight)).
