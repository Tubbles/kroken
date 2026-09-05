#!/usr/bin/env bash
# Installs the pinned Odin toolchain into toolchain/odin (git ignored).
# The version is pinned deliberately: Odin is pre-1.0 and its monthly
# releases ship breaking changes. Linux amd64 only for now.
set -euo pipefail

odin_release_tag="dev-2026-09"
archive_name="odin-linux-amd64-${odin_release_tag}.tar.gz"
download_url="https://github.com/odin-lang/Odin/releases/download/${odin_release_tag}/${archive_name}"
expected_sha256="167c3e1d7056419dad2e04bb3bd98715b7ff286d4c125f3c5a5ee337c6254283"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_directory="${repository_root}/toolchain/odin"
archive_path="${repository_root}/tmp/${archive_name}"

if [[ -x "${install_directory}/odin" ]]; then
    echo "Odin already installed at ${install_directory}"
    "${install_directory}/odin" version
    exit 0
fi

mkdir -p "${repository_root}/tmp"

if [[ ! -f "${archive_path}" ]]; then
    echo "Downloading ${download_url}"
    curl -fSL -o "${archive_path}" "${download_url}"
fi

echo "${expected_sha256}  ${archive_path}" | sha256sum --check --quiet

mkdir -p "${install_directory}"
tar xzf "${archive_path}" --strip-components=1 -C "${install_directory}"
chmod +x "${install_directory}/odin"

"${install_directory}/odin" version
