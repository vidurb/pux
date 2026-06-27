FROM hexpm/elixir:1.18.4-erlang-27.3.4-alpine-3.21.3 AS build

RUN apk add --no-cache build-base git

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

FROM alpine:3.21.3

RUN apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates

WORKDIR /app

ENV MIX_ENV=prod
ENV PHX_SERVER=true

COPY --from=build /app/_build/prod/rel/pux ./

EXPOSE 4000 25

CMD ["/bin/sh", "-c", "bin/pux eval 'Pux.Release.migrate' && exec bin/pux start"]
