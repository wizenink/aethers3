# Multi-stage: build the release in an Elixir image, ship it on a slim runtime
# (the release bundles erts, so the runtime image needs no Erlang/Elixir).
ARG ELIXIR_IMAGE=elixir:1.20-otp-27-slim
ARG RUNTIME_IMAGE=debian:bookworm-slim

# ---- build ----
FROM ${ELIXIR_IMAGE} AS build
ENV MIX_ENV=prod
WORKDIR /src
# slim images ship no CA certs -> HTTPS to hex.pm fails ("no_cacerts_found")
RUN apt-get update -y && apt-get install -y --no-install-recommends ca-certificates git \
  && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config config
COPY rel rel
COPY lib lib
# `mix rel` = compile + patch horus's :erts bug + assemble (see mix.exs aliases)
RUN mix rel

# ---- runtime ----
FROM ${RUNTIME_IMAGE} AS runtime
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libssl3 libncurses6 ca-certificates iproute2 \
  && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
WORKDIR /app
COPY --from=build /src/_build/prod/rel/aether_s3 ./
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
# 9000 S3 API, 9001 admin (health/readiness/metrics).
EXPOSE 9000 9001
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["start"]
