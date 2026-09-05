#!/usr/bin/env bash
# Builds the kroken binary into build/kroken.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
odin="${repository_root}/toolchain/odin/odin"

if [[ ! -x "${odin}" ]]; then
    echo "Odin toolchain missing; run scripts/setup-toolchain.sh first" >&2
    exit 1
fi

mkdir -p "${repository_root}/build"

"${odin}" build "${repository_root}/src/cli" \
    -collection:kroken="${repository_root}/src" \
    -out:"${repository_root}/build/kroken" \
    -o:speed \
    -vet -strict-style -warnings-as-errors

echo "built ${repository_root}/build/kroken"
