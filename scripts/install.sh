#!/usr/bin/env bash
# Builds kroken and copies the binary to <prefix>/bin/kroken and, when
# go-md2man is available, the man page to <prefix>/share/man/man1. The
# prefix is the first argument, else $PREFIX, else ~/.local.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${1:-${PREFIX:-${HOME}/.local}}"
destination="${prefix}/bin/kroken"

"${repository_root}/scripts/build.sh"
mkdir -p "${prefix}/bin"
install -m 755 "${repository_root}/build/kroken" "${destination}"
echo "installed ${destination}"

"${repository_root}/scripts/build-man.sh"
if [[ -f "${repository_root}/build/kroken.1" ]]; then
    mkdir -p "${prefix}/share/man/man1"
    install -m 644 "${repository_root}/build/kroken.1" "${prefix}/share/man/man1/kroken.1"
    echo "installed ${prefix}/share/man/man1/kroken.1"
fi

case ":${PATH}:" in
    *":${prefix}/bin:"*) ;;
    *) echo "note: ${prefix}/bin is not on your PATH" >&2 ;;
esac
