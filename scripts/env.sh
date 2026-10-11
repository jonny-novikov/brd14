# env.sh — source me: puts the pinned toolchains first on PATH.
#   . scripts/env.sh
# Written to $CLAUDE_ENV_FILE by the SessionStart hook; safe to source twice.
_brd14_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$_brd14_root/scripts/versions.env"
export GOTOOLCHAIN="go${GO_VERSION}"
case ":$PATH:" in *":/opt/node24/bin:"*) ;; *) export PATH="/opt/node24/bin:$HOME/.cargo/bin:$PATH" ;; esac
unset _brd14_root
