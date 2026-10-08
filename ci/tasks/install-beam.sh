#!/usr/bin/env bash
set -euo pipefail

versions="${1:-.tool-versions}"
otp="$(awk '$1 == "erlang" { print $2 }' "$versions")"
elixir="$(awk '$1 == "elixir" { print $2 }' "$versions")"
[ -n "$otp" ] && [ -n "$elixir" ] || { echo "install-beam: $versions must name erlang and elixir" >&2; exit 1; }
case "$(dpkg --print-architecture)" in
    amd64 | arm64) arch="$(dpkg --print-architecture)" ;;
    *) echo "install-beam: unsupported architecture $(dpkg --print-architecture)" >&2; exit 1 ;;
esac

if [ "$(cat /opt/ci/otp/.installed 2>/dev/null)" != "$otp" ]; then
    rm -rf /opt/ci/otp
    mkdir -p /opt/ci/otp
    curl -fsSL "https://builds.hex.pm/builds/otp/$arch/ubuntu-24.04/OTP-$otp.tar.gz" \
        | tar -xz -C /opt/ci/otp --strip-components 1
    (cd /opt/ci/otp && ./Install -minimal /opt/ci/otp > /dev/null)
    printf '%s\n' "$otp" > /opt/ci/otp/.installed
fi

if [ "$(cat /opt/ci/elixir/.installed 2>/dev/null)" != "$elixir" ]; then
    rm -rf /opt/ci/elixir
    mkdir -p /opt/ci/elixir
    archive="$(mktemp)"
    curl -fsSL -o "$archive" "https://builds.hex.pm/builds/elixir/v$elixir.zip"
    unzip -q "$archive" -d /opt/ci/elixir
    rm -f "$archive"
    printf '%s\n' "$elixir" > /opt/ci/elixir/.installed
fi

printf "export PATH=/opt/ci/elixir/bin:/opt/ci/otp/bin:\$PATH\n" | sudo tee /etc/profile.d/beam.sh > /dev/null
export PATH="/opt/ci/elixir/bin:/opt/ci/otp/bin:$PATH"
mix local.hex --force --if-missing > /dev/null
mix local.rebar --force --if-missing > /dev/null
echo "otp $(cat /opt/ci/otp/.installed), $(elixir --version | tail -1)"
