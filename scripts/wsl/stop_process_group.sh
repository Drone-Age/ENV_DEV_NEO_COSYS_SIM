#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 || ! $1 =~ ^[0-9]+$ || ! $2 =~ ^[0-9]+$ ]]; then
    echo "usage: stop_process_group.sh <pid> <grace-seconds>" >&2
    exit 64
fi

pid=$1
grace_seconds=$2
if ! kill -0 "$pid" 2>/dev/null; then
    exit 0
fi

pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
if [[ $pgid == "$pid" ]]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
else
    kill -TERM "$pid" 2>/dev/null || true
fi

for ((attempt = 0; attempt < grace_seconds * 10; attempt++)); do
    kill -0 "$pid" 2>/dev/null || exit 0
    sleep 0.1
done

if [[ $pgid == "$pid" ]]; then
    kill -KILL -- "-$pid" 2>/dev/null || true
else
    kill -KILL "$pid" 2>/dev/null || true
fi
