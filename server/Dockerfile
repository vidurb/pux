FROM hexpm/elixir:1.18.4-erlang-27.3.4-alpine-3.21.3 AS build

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
RUN mix phx.digest
RUN mix release

FROM alpine:3.21.3

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
