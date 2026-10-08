#!/usr/bin/env bash
set -euo pipefail

spec="$(tr -d 'v \r\n' < "${1:-.nvmrc}")"
case "$spec" in
    *.*.*) dir="v$spec" ;;
    *) dir="latest-v${spec%%.*}.x" ;;
esac
case "$(dpkg --print-architecture)" in
    amd64) arch=x64 ;;
    arm64) arch=arm64 ;;
    *) echo "install-node: unsupported architecture $(dpkg --print-architecture)" >&2; exit 1 ;;
esac

file="$(curl -fsSL "https://nodejs.org/dist/$dir/SHASUMS256.txt" \
    | awk -v want="-linux-$arch.tar.xz" 'index($2, want) && $2 ~ /^node-v/ { print $2; exit }')"
[ -n "$file" ] || { echo "install-node: no linux-$arch build of Node $spec" >&2; exit 1; }

installed="$(/opt/ci/node/bin/node -v 2>/dev/null || true)"
if [ "node-$installed-linux-$arch.tar.xz" != "$file" ]; then
    rm -rf /opt/ci/node
    mkdir -p /opt/ci/node
    curl -fsSL "https://nodejs.org/dist/$dir/$file" | tar -xJ -C /opt/ci/node --strip-components 1
    printf "export PATH=/opt/ci/node/bin:\$PATH\n" | sudo tee /etc/profile.d/node.sh > /dev/null
fi

export PATH="/opt/ci/node/bin:$PATH"
echo "node $(node -v), npm $(npm -v)"
