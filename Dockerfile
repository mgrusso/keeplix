# Elixir/Phoenix multi-stage build. Runtime needs:
#   DATABASE_PATH, SECRET_KEY_BASE, ACCESS_KEY_ENCRYPTION_KEY, PHX_HOST
# Optional: PORT (4000), DATA_DIR, OIDC_*, MAX_OBJECT_BYTES,
#   SESSION_ABSOLUTE_SECONDS, SESSION_IDLE_SECONDS, POOL_SIZE.
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.1
ARG DEBIAN_VERSION=trixie-20260918-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS builder

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config config
COPY priv priv
COPY assets assets
COPY lib lib

RUN mix deps.compile
RUN mix assets.deploy
RUN mix compile
RUN mix release

FROM debian:${DEBIAN_VERSION} AS runner

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses6 locales \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/keeplix ./

ENV PHX_SERVER=true
EXPOSE 4000

# Mount volumes for DATABASE_PATH and DATA_DIR; migrations run on boot.
CMD ["/app/bin/keeplix", "start"]
