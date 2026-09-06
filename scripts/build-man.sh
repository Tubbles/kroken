#!/usr/bin/env bash
# Assembles build/kroken.1 from doc/man/kroken.md plus the documents under
# doc/, so the man page and `kroken help` share one source. Needs the built
# binary (for the --help output it embeds) and go-md2man; without the
# converter it prints a note and exits 0 so scripts/install.sh carries on.
#
#   go install github.com/cpuguy83/go-md2man/v2@latest
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="${repository_root}/build/kroken"
output="${repository_root}/build/kroken.1"
assembled="${repository_root}/build/kroken.1.md"

if [[ ! -x "${binary}" ]]; then
    echo "build/kroken missing; run scripts/build.sh first" >&2
    exit 1
fi

converter=""
for candidate in go-md2man "${HOME}/go/bin/go-md2man"; do
    if command -v "${candidate}" >/dev/null 2>&1; then
        converter="${candidate}"
        break
    fi
done
if [[ -z "${converter}" ]]; then
    echo "note: go-md2man not found, skipping the man page (go install github.com/cpuguy83/go-md2man/v2@latest)" >&2
    exit 0
fi

version="$("${binary}" version | awk '{print $2}')"
date="$(date +'%B %Y')"

# The --help texts are captured with a neutral home so no machine path
# ends up in a page that is installed on other machines.
complete_help="$(env -i PATH="${PATH}" HOME=/home/user "${binary}" complete --help)"
config_help="$(env -i PATH="${PATH}" HOME=/home/user "${binary}" config --help)"

{
    while IFS= read -r line; do
        case "${line}" in
            '@COMPLETE_HELP@')
                printf '```\n%s\n```\n' "${complete_help}"
                ;;
            '@CONFIG_HELP@')
                printf '```\n%s\n```\n' "${config_help}"
                ;;
            *)
                printf '%s\n' "${line}" | sed -e "s/@VERSION@/${version}/g" -e "s/@DATE@/${date}/g"
                ;;
        esac
    done < "${repository_root}/doc/man/kroken.md"
    for document in doc/configuration.md doc/editor-integration.md; do
        printf '\n'
        sed -e 's/^#/##/' "${repository_root}/${document}"
    done
    printf '\n## SEE ALSO\n\nclaude(1), codex(1), and `kroken help` for the same text in the terminal. Source and issues: https://github.com/Tubbles/kroken\n'
} > "${assembled}"

"${converter}" -in "${assembled}" -out "${output}"
echo "built ${output}"
