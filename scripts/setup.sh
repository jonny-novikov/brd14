#!/usr/bin/env bash
# setup.sh — idempotent provisioning of the brd14 toolchains.
#
#   scripts/setup.sh [core|ci|full]
#
# core: Go, Python 3.14 + 3.14t, Node LTS, Bun, Rust (+wasm32), Erlang/OTP + Elixir,
#       then per-directory dependencies for whichever manifests exist.
# ci:   core + Go floor toolchain, Rust nightly (Miri), libFuzzer runtime — everything
#       scripts/ci.sh runs (the fly/Dockerfile image).
# full: ci + PostgreSQL 16 server (the storage probe, tools/storage_probe/).
#
# Every step checks the pinned version first and skips when it is present, so a
# warm container finishes in seconds. Sources are the ones the cloud egress
# proxy allows: proxy.golang.org (GOTOOLCHAIN), deadsnakes PPA, nodejs.org,
# registry.npmjs.org (bun), static.rust-lang.org. GitHub release downloads are
# blocked there, which is why uv-managed Python and bun.sh/install are not used.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/versions.env"
TIER="${1:-core}"
log() { printf '[setup] %s\n' "$*" >&2; }
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
APT_UPDATED=0
apt_install() {
  if [ "$APT_UPDATED" -eq 0 ]; then $SUDO apt-get update -qq; APT_UPDATED=1; fi
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --no-install-recommends "$@" >/dev/null
}

ensure_go() {
  if GOTOOLCHAIN="go${GO_VERSION}" go version 2>/dev/null | grep -q "go${GO_VERSION} "; then
    log "go ${GO_VERSION} ok"
  else
    log "go: fetching go${GO_VERSION} via GOTOOLCHAIN"; GOTOOLCHAIN="go${GO_VERSION}" go version >/dev/null
  fi
  if [ "$TIER" != core ]; then GOTOOLCHAIN="go${GO_FLOOR_VERSION}" go version >/dev/null && log "go floor ${GO_FLOOR_VERSION} ok"; fi
}

ensure_python() {
  local want=(python3.14 python3.14-venv python3.14-dev python3.14-nogil)
  if command -v python3.14 >/dev/null && command -v python3.14t >/dev/null; then
    log "$(python3.14 -VV | head -1) ok; 3.14t ok"; return
  fi
  if [ ! -f /etc/apt/sources.list.d/deadsnakes.list ]; then
    [ -f /etc/apt/keyrings/deadsnakes.asc ] || curl -fsSL \
      'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF23C5A6CF475977595C89F51BA6932366A755776' \
      | $SUDO tee /etc/apt/keyrings/deadsnakes.asc >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/deadsnakes.asc] https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu $(. /etc/os-release; echo "$VERSION_CODENAME") main" \
      | $SUDO tee /etc/apt/sources.list.d/deadsnakes.list >/dev/null
    APT_UPDATED=0
  fi
  log "python: installing ${want[*]}"; apt_install "${want[@]}"
}

ensure_node() {
  if [ -x /opt/node24/bin/node ] && [ "$(/opt/node24/bin/node --version)" = "v${NODE_VERSION}" ]; then
    log "node ${NODE_VERSION} ok"; return
  fi
  log "node: installing v${NODE_VERSION}"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o "$tmp/node.tar.xz"
  $SUDO rm -rf /opt/node24 && $SUDO mkdir -p /opt/node24
  $SUDO tar -xJf "$tmp/node.tar.xz" -C /opt/node24 --strip-components=1
  rm -rf "$tmp"
}

ensure_bun() {
  if [ -x /opt/node24/bin/bun ] && [ "$(/opt/node24/bin/bun --version)" = "${BUN_VERSION}" ]; then
    log "bun ${BUN_VERSION} ok"; return
  fi
  log "bun: installing ${BUN_VERSION} from npm"
  PATH="/opt/node24/bin:$PATH" npm install -g --silent "bun@${BUN_VERSION}" >/dev/null
}

ensure_rust() {
  if rustup toolchain list 2>/dev/null | grep -q "^${RUST_VERSION}-" \
     && rustup target list --installed --toolchain "${RUST_VERSION}" 2>/dev/null | grep -q wasm32-unknown-unknown; then
    log "rust ${RUST_VERSION} + wasm32 ok"
  else
    log "rust: installing ${RUST_VERSION} + wasm32-unknown-unknown"
    rustup toolchain install "${RUST_VERSION}" --profile minimal -c rustfmt -c clippy -t wasm32-unknown-unknown >/dev/null
  fi
  if [ "$TIER" != core ]; then
    rustup toolchain install nightly --profile minimal -c miri -c rust-src >/dev/null && log "rust nightly + miri ok"
  fi
}

ensure_beam() {
  # Ubuntu's own packages: OTP 25.3 + Elixir 1.14, the floor ex/echo_data is held to.
  if command -v elixir >/dev/null 2>&1 && elixir --version 2>/dev/null | grep -q "Elixir ${ELIXIR_VERSION} " \
     && erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null | grep -q "^${OTP_VERSION%%.*}$"; then
    log "beam: OTP ${OTP_VERSION%%.*} + Elixir ${ELIXIR_VERSION} ok"; return 0
  fi
  log "apt: erlang-nox erlang-dev erlang-src elixir"
  apt_install erlang-nox erlang-dev erlang-src elixir
}

ensure_full_extras() {
  [ "$TIER" != core ] || return 0
  local pkgs=()
  dpkg -s libclang-rt-18-dev >/dev/null 2>&1 || pkgs+=(libclang-rt-18-dev)
  if [ "$TIER" = full ]; then dpkg -s postgresql-16 >/dev/null 2>&1 || pkgs+=(postgresql-16); fi
  if [ "${#pkgs[@]}" -gt 0 ]; then log "apt: ${pkgs[*]}"; apt_install "${pkgs[@]}"; else log "libFuzzer runtime ok (tier ${TIER})"; fi
}

ensure_deps() {
  . "$ROOT/scripts/env.sh"
  if [ -f "$ROOT/ts/package.json" ]; then log "ts: npm install"; (cd "$ROOT/ts" && npm install --no-audit --no-fund --silent); fi
  if [ -f "$ROOT/python/Makefile" ]; then log "python: venvs"; make -s -C "$ROOT/python" venv; fi
  if [ -f "$ROOT/native/rust/Cargo.toml" ]; then log "rust: cargo fetch"; (cd "$ROOT/native/rust" && cargo fetch -q); fi
  if [ -f "$ROOT/go/go.mod" ]; then (cd "$ROOT/go" && go mod download); fi
  if [ -f "$ROOT/ex/echo_data/mix.exs" ] && command -v mix >/dev/null 2>&1; then
    log "ex: hex + deps"
    mix local.hex --force --if-missing >/dev/null
    (cd "$ROOT/ex/echo_data" && TMPDIR=/tmp mix deps.get >/dev/null)
  fi
}

ensure_go
ensure_python
ensure_node
ensure_bun
ensure_rust
ensure_beam
ensure_full_extras
ensure_deps
log "done (${TIER})"
