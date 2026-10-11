#!/usr/bin/env bash
# mint — mint brd14 ids. Shorthand for `brd mint`.
#
#   mint            one id in the default namespace (.brdrc `ns`)
#   mint 5          five ids, strictly increasing
#   mint ORD        one ORD id
#   mint ORD 5      five ORD ids          (any `brd` option works: --as json, --node 7, ...)
#
# Install both tools on PATH by symlink; this resolves the link to find brd.sh:
#   ln -s "$PWD/scripts/brd.sh" ~/.local/bin/brd && ln -s "$PWD/scripts/mint.sh" ~/.local/bin/mint
self=${BASH_SOURCE[0]}
while [[ -L $self ]]; do
  link=$(readlink "$self")
  [[ $link == /* ]] && self=$link || self=${self%/*}/$link
done
exec bash "${self%/*}/brd.sh" mint "$@"
