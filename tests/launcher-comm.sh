#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# launcher-comm.sh — check, inside an image built with i386-compat.sh, that a
# --launcher process is called NAME: /proc/PID/comm, `pgrep -x NAME` and
# `pidof NAME`, on x86 (plain exec) and under qemu-i386 alike. Run it in the
# example image, where NAME is hello-i386 (needs procps):
#
#   docker run --rm -i IMAGE bash -s < tests/launcher-comm.sh
#
# The launcher is a /bin/sh script named NAME, so comm is NAME even before it
# execs anything. The test therefore waits for the i386 program's own output
# and, where qemu-i386 is installed, also checks that the process is the
# emulator by then.
set -euo pipefail

name="${1:-hello-i386}"
qemu=/usr/local/bin/qemu-i386

fail() {
    echo "launcher-comm: FAIL: $*" >&2
    exit 1
}

out=$(mktemp)
"${name}" --sleep 30 > "${out}" 2>&1 &
pid=$!
trap 'kill "${pid}" 2>/dev/null || true; rm -f "${out}"' EXIT

# hello.c prints (and flushes) its cpuinfo line last, right before sleeping.
ready=0
for _ in $(seq 1 150); do
    if grep -q '^/proc/cpuinfo' "${out}"; then
        ready=1
        break
    fi
    kill -0 "${pid}" 2> /dev/null || break
    sleep 0.1
done
if [[ "${ready}" != "1" ]]; then
    cat "${out}" >&2
    fail "${name} --sleep printed no cpuinfo line (exited early or timed out)"
fi

comm=$(< "/proc/${pid}/comm")
exe=$(readlink "/proc/${pid}/exe")
echo "launcher-comm: pid ${pid} comm '${comm}' exe ${exe}"

# The kernel keeps 15 characters (TASK_COMM_LEN - 1).
[[ "${comm}" == "${name:0:15}" ]] || fail "comm is '${comm}', expected '${name:0:15}'"
if [[ -x "${qemu}" ]]; then
    [[ "${exe}" == "${qemu}" ]] || fail "exe is ${exe}, expected ${qemu} (emulated image)"
else
    [[ "${exe##*/}" != "sh" && "${exe##*/}" != "dash" && "${exe##*/}" != "bash" ]] ||
        fail "exe is still the launcher's shell (${exe})"
fi
if [[ "${#name}" -le 15 ]]; then
    pids=$(pgrep -x "${name}") || fail "pgrep -x ${name} found nothing"
    grep -qx "${pid}" <<< "${pids}" || fail "pgrep -x ${name} found ${pids//$'\n'/ }, not ${pid}"
    pids=$(pidof "${name}") || fail "pidof ${name} found nothing"
    [[ " ${pids} " == *" ${pid} "* ]] || fail "pidof ${name} found ${pids}, not ${pid}"
fi
echo "launcher-comm: ok"
