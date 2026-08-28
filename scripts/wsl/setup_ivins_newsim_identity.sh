#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $(id -u) -ne 0 ]]; then
    echo "NewSIM IVINS identity setup must run as root" >&2
    exit 1
fi

source /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 || $(dpkg --print-architecture) != amd64 ]]; then
    echo "NewSIM IVINS identity requires Ubuntu 24.04 AMD64" >&2
    exit 1
fi

identity_root=/etc/ivins
platform_file="$identity_root/newsim-platform"
instance_file="$identity_root/newsim-instance-id"
install -d -m 0755 -o root -g root "$identity_root"

if [[ -e $platform_file ]] && [[ $(tr -d '\r\n' < "$platform_file") != newsim-cosys ]]; then
    echo "refusing to replace an incompatible IVINS platform marker" >&2
    exit 1
fi
printf '%s\n' newsim-cosys | install -m 0444 -o root -g root /dev/stdin "$platform_file"

if [[ -e $instance_file ]]; then
    instance_id=$(tr -d '\r\n' < "$instance_file")
else
    instance_id="newsim-$(cat /proc/sys/kernel/random/uuid)"
    printf '%s\n' "$instance_id" | install -m 0444 -o root -g root /dev/stdin "$instance_file"
fi

if [[ ! $instance_id =~ ^[A-Za-z0-9._-]{8,128}$ ]]; then
    echo "existing NewSIM IVINS instance identity is invalid" >&2
    exit 1
fi
if [[ $(stat -c '%U:%G:%a' "$platform_file") != root:root:444 ]] ||
   [[ $(stat -c '%U:%G:%a' "$instance_file") != root:root:444 ]]; then
    echo "NewSIM IVINS identity files have unsafe ownership or mode" >&2
    exit 1
fi

printf 'NewSIM IVINS identity ready: %s\n' "$instance_id"
