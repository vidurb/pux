# Not Alpine 3.24: OTP 27.3.4.19 and earlier give the VM a fixed 8192-byte signal stack,
# which musl 1.2.6 rejects on Intel AMX hosts (it wants 12976), so the VM aborts on every
# start there. Stay on musl 1.2.5 until OTP has erlang/otp#11810. CI checks this.
FROM hexpm/elixir:1.18.4-erlang-27.3.4.16-alpine-3.23.5 AS build

RUN apk add --no-cache build-base git libsodium-dev

WORKDIR /app

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get --only prod
RUN mkdir config

COPY config/config.exs config/prod.exs config/runtime.exs config/
COPY lib lib
COPY priv priv
RUN mix deps.compile
RUN mix release

# Same Alpine release as the build stage: the release links against its libsodium,
# OpenSSL and ncurses. Move the two stages together.
FROM alpine:3.23.8

RUN apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates libsodium

WORKDIR /app

ENV MIX_ENV=prod \
    PHX_SERVER=true \
    HOME=/tmp \
    RELEASE_TMP=/tmp

COPY --from=build /app/_build/prod/rel/pux ./

# nobody; SMTP listens on 2525 so no privileged ports are needed and the
# root filesystem can be mounted read-only with an emptyDir at /tmp.
USER 65534:65534

EXPOSE 4000 2525

CMD ["/bin/sh", "-c", "bin/pux eval 'Pux.Release.migrate' && exec bin/pux start"]
