#!/usr/bin/env bash
# The quality gate entry point: tests every Odin package under src/ and
# then builds the release binary. A fresh clone runs
# scripts/setup-toolchain.sh once, then this.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
odin="${repository_root}/toolchain/odin/odin"

if [[ ! -x "${odin}" ]]; then
    echo "Odin toolchain missing; run scripts/setup-toolchain.sh first" >&2
    exit 1
fi

mkdir -p "${repository_root}/tmp"

vet_flags=(-vet -strict-style -warnings-as-errors)

exit_status=0
while IFS= read -r package_directory; do
    echo "== ${package_directory}"
    "${odin}" test "${package_directory}" \
        -collection:kroken="${repository_root}/src" \
        -out:"${repository_root}/tmp/test_binary" \
        "${vet_flags[@]}" || exit_status=1
done < <(find "${repository_root}/src" -name '*.odin' -printf '%h\n' | sort -u)

echo "== build"
"${repository_root}/scripts/build.sh" || exit_status=1

exit "${exit_status}"
