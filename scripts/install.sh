#!/usr/bin/env bash
# Builds kroken and copies the binary to <prefix>/bin/kroken. The prefix
# is the first argument, else $PREFIX, else ~/.local.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${1:-${PREFIX:-${HOME}/.local}}"
destination="${prefix}/bin/kroken"

"${repository_root}/scripts/build.sh"
mkdir -p "${prefix}/bin"
install -m 755 "${repository_root}/build/kroken" "${destination}"
echo "installed ${destination}"

case ":${PATH}:" in
    *":${prefix}/bin:"*) ;;
    *) echo "note: ${prefix}/bin is not on your PATH" >&2 ;;
esac
