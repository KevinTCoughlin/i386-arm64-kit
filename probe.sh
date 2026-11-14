#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# probe.sh — will this image's binaries run under Apple `container` on Apple
# silicon, and how?
#
#   probe.sh [--platform os/arch] IMAGE [BINARY...]
#
# Reports the ELF class and machine of each BINARY (absolute, or looked up in
# the image's PATH; symlinks resolved inside the image), or of the image's
# entrypoint (Entrypoint[0], else Cmd[0]) when none are given:
#
#   x86_64   Rosetta OK           Rosetta for Linux runs it (linux/amd64 image)
#   i386     needs qemu-i386 kit  Rosetta can't; build for arm64 with this kit
#   aarch64  native               nothing to do
#
# How: the image's first variant matching --platform (default: arm64, else
# amd64) is started with a static arm64 busybox mounted in as the entrypoint,
# so it works on images without a shell and on amd64-only images. That
# busybox is fetched once via an Alpine container into
# ~/Library/Caches/i386-arm64-kit.
# get() is a predicate (absent key = non-zero) used in conditions.
# shellcheck disable=SC2310
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
HELPER_IMAGE="${PROBE_HELPER_IMAGE:-alpine:3.24}"
CACHE="${XDG_CACHE_HOME:-${HOME}/Library/Caches}/i386-arm64-kit"

die() {
    echo "probe.sh: $*" >&2
    exit 1
}
usage() {
    sed -n '5,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

platform=""
if [[ "${1:-}" == "--platform" ]]; then
    [[ "$#" -ge 2 ]] || usage
    platform="$2"
    shift 2
fi
[[ "$#" -ge 1 && "$1" != -* ]] || usage
image="$1"
shift
command -v container >/dev/null 2>&1 || die "Apple 'container' not found"

if ! container image inspect "${image}" >/dev/null 2>&1; then
    container image pull ${platform:+--platform "${platform}"} "${image}" >&2
fi

# --- pick the image variant and read its config ----------------------------

tmp=$(mktemp -d "${TMPDIR:-/tmp}/probe.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

get() { # get KEYPATH -> value on stdout, or non-zero if absent
    plutil -extract "$1" raw -o - "${tmp}/inspect.json" 2>/dev/null
}

# Sets chosen to the index of the variant to probe (inspect only lists the
# variants pulled so far).
select_variant() {
    container image inspect "${image}" > "${tmp}/inspect.json"
    chosen=""
    local fallback="" i=0 arch os
    while arch=$(get "0.variants.${i}.config.architecture"); do
        os=$(get "0.variants.${i}.config.os" || echo linux)
        if [[ "${os}" == "linux" && "${arch}" != "unknown" ]]; then
            if [[ -n "${want_arch}" ]]; then
                [[ "${arch}" == "${want_arch}" ]] && chosen="${i}"
            elif [[ "${arch}" == "arm64" ]]; then
                chosen="${i}"
            elif [[ "${arch}" == "amd64" || -z "${fallback}" ]]; then
                fallback="${i}"
            fi
        fi
        [[ -n "${chosen}" ]] && break
        i=$((i + 1))
    done
    chosen="${chosen:-${fallback}}"
}

want_arch="${platform##*/}"
select_variant
if [[ -z "${chosen}" && -n "${platform}" ]]; then
    container image pull --platform "${platform}" "${image}" >&2
    select_variant
fi
[[ -n "${chosen}" ]] || die "${image}: no linux variant${want_arch:+ for ${want_arch}}"
cfg="0.variants.${chosen}.config"
arch=$(get "${cfg}.architecture")

path_var="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
j=0
while env_kv=$(get "${cfg}.config.Env.${j}"); do
    [[ "${env_kv}" == PATH=* ]] && path_var="${env_kv#PATH=}"
    j=$((j + 1))
done

binaries=("$@")
if [[ "${#binaries[@]}" -eq 0 ]]; then
    entry=$(get "${cfg}.config.Entrypoint.0" || get "${cfg}.config.Cmd.0" || true)
    [[ -n "${entry}" ]] || die "${image}: no Entrypoint or Cmd; name the binaries to probe"
    binaries=("${entry}")
fi

# --- static busybox to run inside the image ---------------------------------

if [[ ! -x "${CACHE}/busybox" ]]; then
    mkdir -p "${CACHE}"
    echo "probe.sh: fetching a static arm64 busybox via ${HELPER_IMAGE} (once)" >&2
    container run --rm --platform linux/arm64 -v "${CACHE}:/out" "${HELPER_IMAGE}" \
        sh -c 'apk add --no-cache busybox-static >/dev/null && cp /bin/busybox.static /out/busybox.new' >&2
    mv "${CACHE}/busybox.new" "${CACHE}/busybox"
fi
cp "${CACHE}/busybox" "${tmp}/busybox"

# Runs inside the image under the mounted busybox's sh; prints one line per
# binary: WANT|RESOLVED|KIND[|DETAIL...]
cat > "${tmp}/inner.sh" <<'INNER'
B=/probe/busybox
path_var=$1
shift
for want in "$@"; do
    p=$want
    case $p in
        */*) ;;
        *)
            old_ifs=$IFS
            IFS=:
            for d in $path_var; do
                if [ -e "$d/$p" ]; then p=$d/$p; break; fi
            done
            IFS=$old_ifs
            ;;
    esac
    r=$($B readlink -f "$p" 2>/dev/null) || r=$p
    if [ ! -f "$r" ]; then echo "$want|$r|missing"; continue; fi
    # shellcheck disable=SC2046
    set -- $($B od -An -tu1 -N20 "$r")
    if [ "${1:-} ${2:-}" = "35 33" ]; then
        echo "$want|$r|script|$($B head -n 1 "$r")"
    elif [ "$#" -lt 20 ] || [ "$1 $2 $3 $4" != "127 69 76 70" ]; then
        echo "$want|$r|other"
    else
        echo "$want|$r|elf|$5|$(( ${19} + ${20} * 256 ))"
    fi
done
INNER

results=$(container run --rm --platform "linux/${arch}" --user 0 --memory 256M \
    -v "${tmp}:/probe" --entrypoint /probe/busybox "${image}" \
    sh /probe/inner.sh "${path_var}" "${binaries[@]}" 2>/dev/null) ||
    die "could not start ${image} (linux/${arch}) to inspect it"

# --- report -----------------------------------------------------------------

printf 'image: %s (linux/%s)\n' "${image}" "${arch}"
needs_kit=0
while IFS='|' read -r want resolved kind a b; do
    shown="${want}"
    [[ "${resolved}" != "${want}" ]] && shown="${want} -> ${resolved}"
    case "${kind}" in
        missing) printf '  %-40s not found in image\n' "${shown}" ;;
        other) printf '  %-40s not an ELF binary or script\n' "${shown}" ;;
        script) printf '  %-40s script (%s): name the binary it runs\n' "${shown}" "${a}" ;;
        elf)
            bits=$((a == 1 ? 32 : 64))
            case "${b}" in
                62) verdict="x86_64   Rosetta OK" ;;
                3)
                    verdict="i386     needs qemu-i386 kit"
                    needs_kit=1
                    ;;
                183) verdict="aarch64  native" ;;
                40) verdict="arm      32-bit ARM: needs qemu-arm (not covered by this kit)" ;;
                *) verdict="e_machine ${b}: unknown" ;;
            esac
            printf '  %-40s ELF%s %s\n' "${shown}" "${bits}" "${verdict}"
            ;;
        *) printf '  %-40s %s\n' "${shown}" "${kind}" ;;
    esac
done <<< "${results}"
if [[ "${needs_kit}" == "1" ]]; then
    echo "-> i386 found: build linux/arm64 with i386-compat.sh (Rosetta runs x86_64 only)."
fi
