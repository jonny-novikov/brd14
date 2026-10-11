# syntax=docker/dockerfile:1
# fly/Dockerfile — the brd-build image: every pinned toolchain (scripts/versions.env, installed by
# scripts/setup.sh ci) and this tree with its dependencies fetched. fly.toml runs scripts/ci.sh in
# it as the deploy's release_command; docs/ci.md has the whole picture.
#
# Behind a TLS-intercepting proxy (a sandbox, a corporate network) pass its CA as a build secret,
# `--secret id=proxy_ca,src=<bundle.crt>`, plus the usual HTTP(S)_PROXY build args. Fly's builders
# need neither, and without the secret nothing is installed.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC \
    PATH=/opt/node24/bin:/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
    CARGO_NET_GIT_FETCH_WITH_CLI=true

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      ca-certificates curl git make gcc g++ libc6-dev pkg-config xz-utils gnupg \
      golang-go python3 python3-venv clang \
 && rm -rf /var/lib/apt/lists/*

RUN --mount=type=secret,id=proxy_ca,required=false \
    if [ -s /run/secrets/proxy_ca ]; then \
      cp /run/secrets/proxy_ca /usr/local/share/ca-certificates/proxy_ca.crt && update-ca-certificates; \
    fi

# rustup itself; setup.sh installs the pinned toolchain (and nightly + Miri for the ci tier).
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none --no-modify-path

WORKDIR /brd14

# Toolchains first, from the pins alone, so this layer is rebuilt only when a pin moves.
COPY scripts/versions.env scripts/setup.sh scripts/env.sh scripts/
RUN mkdir -p /etc/apt/keyrings \
 && scripts/setup.sh ci \
 && . scripts/versions.env && rustup default "${RUST_VERSION}" \
 && apt-get install -y -qq --no-install-recommends python3.13 python3.13-venv \
 && rm -rf /var/lib/apt/lists/* /root/.cache/pip

# The tree, then its dependencies (npm, the Python venvs, cargo fetch, go mod download, hex deps).
COPY . .
RUN scripts/setup.sh ci && scripts/ci.sh --versions

EXPOSE 8080
CMD ["fly/status.sh"]
