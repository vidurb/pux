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
| `deploy/` | Docker Compose setup for self-hosting |
| `brand/` | Logo sources and identity guide; `scripts/render-brand.sh` renders the PNGs from them |
| `.github/` | CI, release workflow, Dependabot |

## Toolchains

From the repo root, [mise](https://mise.jdx.dev) installs pinned Erlang/OTP, Elixir and JDK 21:

```bash
mise install
mise run setup
```

See [`mise.toml`](mise.toml). `mise run setup` installs hk git hooks (Elixir format checks and `jactionlint` on workflows). Use `hk check` before pushing; full server and native tests remain CI and manual.

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

## Native clients

See [native/README.md](native/README.md) and the platform READMEs for build and test instructions.

## Pull requests

- Keep each PR focused, with tests for every behaviour change.
- PRs are squash-merged, and the PR title becomes the commit message on `main`. It must be a [Conventional Commit](https://www.conventionalcommits.org/), ideally with a scope: `fix(smtp): …`, `feat(mobile): …`, `docs: …`, `ci: …`. The `pr-title` check enforces this. In a one-commit PR, the commit message must match the title.
- The title is the changelog entry, so write it for users: `feat(macos): ship a signed, notarized disk image`, not `feat: sign_app.sh changes`. The type decides the release:
  - `feat` is a minor release and appears under **Added**.
  - `fix` and `perf` are a patch release, under **Fixed** and **Performance**. Use `fix` for security fixes too.
  - `!` after the type, or a `BREAKING CHANGE:` footer, is a minor release before 1.0.0 and a major one after. Use it for API or enrollment changes that older apps or servers can't handle.
  - `docs`, `refactor`, `test`, `build`, `ci`, `chore` and `style` don't cut a release and don't appear in the changelog.
- Don't edit [CHANGELOG.md](CHANGELOG.md) in a PR; release-please writes it. (Until v0.1.0 is cut, user-visible changes still go under **Unreleased**.)
- Never commit secrets, real OTP emails, keystores or `key.properties`. Firebase client config (`google-services.json`, `GoogleService-Info.plist`) is not secret and is committed on purpose.

## Releases (maintainers)

Releases are cut by [release-please](https://github.com/googleapis/release-please), configured in [`release-please-config.json`](release-please-config.json), with the current version in [`.release-please-manifest.json`](.release-please-manifest.json). The server and apps share one version.

1. Every push to `main` updates an open **chore: release x.y.z** PR. It bumps `server/mix.exs` and the release manifest, and adds a `CHANGELOG.md` section written from the commits since the last release. Before 1.0.0, a `feat` raises the minor version, and anything else releasable raises the patch.
2. To release, review the PR and merge it. The changelog in the PR can be edited just before merging. A later push to `main` regenerates the PR and discards the edits.
3. On merge, release-please tags `vx.y.z`, creates a draft GitHub Release and starts the `release` and `testflight` workflows on the tag.

The `release` workflow checks that the tag matches both versions. It then publishes the server image as `ghcr.io/vidurb/pux-server:x.y.z` (and `x.y`). It builds a signed Android APK and AAB, a signed and notarized macOS disk image (setup in [native/macos/README.md](native/macos/README.md#release-signing-setup)), and a Linux `.deb` and tarball ([native/linux/README.md](native/linux/README.md)). It attaches all of these and `SHA256SUMS` to the draft, then publishes it with the changelog section as notes. If any build fails, the release stays a draft and nothing is announced. Re-run the failed jobs. If the failure needs a code fix, merge it as a `fix:`, release the next patch version, and delete the unpublished draft. The `testflight` workflow uploads an iOS build to TestFlight (setup in [native/ios/README.md](native/ios/README.md#testflight-setup)). Android and macOS build numbers come from the `release` workflow's run number, and iOS build numbers from the `testflight` workflow's.

Other cases:

- **Choosing a version:** add a `Release-As: x.y.z` footer to a commit on `main` (an empty `chore: release x.y.z` commit works).
- **Trying the builds:** run the `release` workflow by hand on a branch. It builds and signs everything without publishing.

### First release (v0.1.0)

release-please waits until the repository has a release, so v0.1.0 is published from the curated notes ([#37](https://github.com/vidurb/pux/issues/37)):

1. Rename `## [Unreleased]` in `CHANGELOG.md` to `## [0.1.0] - YYYY-MM-DD` and merge that change.
2. `git tag -s v0.1.0 -m v0.1.0 && git push origin v0.1.0`.

After that, release-please opens the next release PR.

### Optional setup

- **CI on release PRs:** a PR opened with `GITHUB_TOKEN` gets no workflow runs. That matters once `main` requires checks ([#45](https://github.com/vidurb/pux/issues/45)). To fix it, create a GitHub App owned by your account with *Contents*, *Pull requests* and *Issues* set to read and write, and install it on this repository. Then store its client ID as the `RELEASE_APP_CLIENT_ID` repository variable and a private key as the `RELEASE_APP_PRIVATE_KEY` secret.
- **Google Play:** create the app in Play Console and upload the first AAB by hand, since Google rejects API uploads until then. Then create a service account with release permissions for the app, and store its JSON key as the `PLAY_SERVICE_ACCOUNT_JSON` secret. Each release then uploads the AAB to the internal track as a draft. The `PLAY_TRACK` and `PLAY_RELEASE_STATUS` variables override this, for example `PLAY_RELEASE_STATUS=completed` once the app has passed review.
- **Merge settings:** allow only squash merges, and set the default squash commit message to the PR title (*Settings → General → Pull Requests*). The `pr-title` check assumes this.
