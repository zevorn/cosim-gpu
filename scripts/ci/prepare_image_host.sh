#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if [ "${GITHUB_ACTIONS:-}" != true ] ||
    [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then
    echo "This recipe only prepares disposable GitHub-hosted runners" >&2
    exit 1
fi
test "$(uname -m)" = x86_64
test -c /dev/kvm
sudo chmod a+rw /dev/kvm

# Remove unused toolchains from the dedicated image-build VM.
sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc \
    /usr/local/.ghcup /usr/share/swift /usr/local/share/boost
if [ "${RUNNER_TOOL_CACHE:-}" = /opt/hostedtoolcache ]; then
    sudo find "$RUNNER_TOOL_CACHE" -mindepth 1 -maxdepth 1 \
        ! -iname '*just*' -exec rm -rf -- {} +
fi
sudo apt-get clean
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    binutils build-essential python3-venv scons pkg-config \
    qemu-system-x86 qemu-utils xorriso curl unzip perl libdigest-sha-perl gh
df -h "$GITHUB_WORKSPACE"
