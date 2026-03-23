FROM haskell:9.6.7 AS build
WORKDIR /app
ENV STACK_ROOT=/root/.stack

COPY server/stack.yaml server/stack.yaml.lock server/package.yaml server/aisopsflow-plugin-catalog-server.cabal /app/
RUN mkdir -p /app/app /app/src /app/config
RUN --mount=type=cache,target=/root/.stack \
    --mount=type=cache,target=/app/.stack-work \
    stack build --only-dependencies --no-haddock

COPY server/app /app/app
COPY server/src /app/src
COPY server/config /app/config
RUN --mount=type=cache,target=/root/.stack \
    --mount=type=cache,target=/app/.stack-work \
    stack build --copy-bins --local-bin-path /app/bin --no-haddock

FROM debian:bullseye-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libgmp10 \
    libsqlite3-0 \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/bin/aisopsflow-plugin-catalog-server /usr/local/bin/aisopsflow-plugin-catalog-server
EXPOSE 3100
CMD ["aisopsflow-plugin-catalog-server"]
