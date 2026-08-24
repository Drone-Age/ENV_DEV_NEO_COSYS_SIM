#!/usr/bin/env bash
set -uo pipefail

child_pid=""

stop_child() {
    trap - TERM INT HUP
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
        kill -TERM "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
    exit 0
}

trap stop_child TERM INT HUP

"$@" &
child_pid=$!
wait "$child_pid"
exit $?
