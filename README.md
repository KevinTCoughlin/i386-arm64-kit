# i386-arm64-kit

Run 32-bit x86 (i386) Linux game servers and tools — HLDS, SteamCMD, old
`*_linux` dedicated servers, AMX Mod X's `amxxpc` — in containers on Apple
silicon, from the same Containerfile that builds for x86. Plus a launchd
wrapper that runs any Apple [`container`](https://github.com/apple/container)
service as a macOS login agent.

Extracted from [cs-server](https://github.com/KevinTCoughlin/cs-server)'s
Apple silicon support, where it runs a Counter-Strike 1.6 (ReHLDS) server at
~250 server FPS with Steam authentication working.

## Do you need it?

Rosetta for Linux translates **x86_64 only**. A 32-bit x86 binary in a
`linux/amd64` image fails with `Exec format error` under Apple `container`,
whatever `--platform`/`--rosetta` you pass. Ask the image:

```bash
./probe.sh ghcr.io/you/your-server:latest               # the entrypoint
./probe.sh your-image /opt/server/srcds_linux steamcmd   # specific binaries
```

```
image: localhost/cs-server:latest (linux/arm64)
  /hlds/hlds_linux                         ELF32 i386     needs qemu-i386 kit
  qemu-i386 -> /usr/local/bin/qemu-i386    ELF64 aarch64  native
```

| Binary  | Verdict              | What to do                                   |
|---------|----------------------|----------------------------------------------|
| x86_64  | Rosetta OK           | run the `linux/amd64` image as is            |
| i386    | needs qemu-i386 kit  | build `linux/arm64` with `i386-compat.sh`    |
| aarch64 | native               | nothing                                      |

`probe.sh` mounts a static arm64 busybox into the image and runs that, so it
also works on shell-less and amd64-only images. It fetches the busybox once
via `alpine:3.24` into `~/Library/Caches/i386-arm64-kit` (under
`$XDG_CACHE_HOME` instead, if that is set).

## Quick start

Copy `image/` into your repo and add one `RUN` to a Debian-based
Containerfile. On amd64 it installs the i386 libraries and nothing else; on
arm64 it adds a static `qemu-i386` and the Steam shim.

```dockerfile
FROM debian:trixie-slim
RUN --mount=type=bind,source=image,target=/usr/local/src/i386-kit \
    bash /usr/local/src/i386-kit/i386-compat.sh install \
        --i386-pkg libcurl4t64 \
        --launcher srcds_linux=/srv/game/srcds_linux \
        curl procps
# Build-time i386 tools:
RUN run-i386 ./amxxpc plugin.sma
CMD ["srcds_linux", "-game", "..."]
HEALTHCHECK CMD pgrep -x srcds_linux
```

(`procps` is there for the health check's `pgrep`; `debian:*-slim` has none.)

```bash
container build --platform linux/arm64 -t my-server .
```

[`examples/Containerfile`](examples/Containerfile) is a complete,
buildable SteamCMD image with an i386 smoke test:

```bash
container build --platform linux/arm64 -t steam-example -f examples/Containerfile .
container run --rm steam-example
# hello from a 32-bit x86 binary (kernel reports i686)
# get_robust_list: ok (len 12)
# /proc/cpuinfo x86 flags: ok
```

## `image/i386-compat.sh`

```
i386-compat.sh install [--i386-pkg PKG]... [--launcher NAME=PATH]... [--keep-apt-lists] [--] [extra-pkg...]
i386-compat.sh packages     # i386 library packages for this arch
i386-compat.sh emulated     # exit 0 if this arch runs i386 under qemu
```

`install` runs `apt-get update` and installs, in one go:

- the extra native packages you list (curl, procps, …) and `ca-certificates`;
- the base i386 runtime `libc6 libgcc-s1 libstdc++6 zlib1g` as multiarch
  `:i386` packages (native names on an i386 image);
- every `--i386-pkg PKG` (and `$I386_EXTRA_PACKAGES`) the same way — the hook
  for whatever else your server links against (`ldd` it on an x86 box, or
  read the `error while loading shared libraries` line);
- on non-x86 only: `/usr/local/bin/qemu-i386` (copied out of Debian's
  `qemu-user`, which bundles every target at ~460 MB; the static i386
  emulator alone is 14 MB, and the package is purged again),
  `/usr/local/lib/i386-qemu-shim.so` (built with a cross compiler that is also
  purged) and a fake x86 `/proc/cpuinfo`. Before the purge it checks that
  `qemu-i386` really is statically linked and stops the build if not (a
  dynamic one, as in `qemu-user` before trixie, would lose its libraries).
  QEMU's copyright file and a note of the Debian source version are kept in
  `/usr/local/share/i386-kit/` (see [License](#license));
- `/usr/local/bin/run-i386` and one `/usr/local/bin/NAME` per `--launcher`.

It then removes `/var/lib/apt/lists` unless `--keep-apt-lists`.

### `run-i386` and launchers

|                         | amd64 / i386         | arm64 (and other non-x86)                    |
|-------------------------|----------------------|----------------------------------------------|
| `run-i386 PROG ARGS…`   | `exec "$@"`          | `qemu-i386` + shim, `PROG` looked up in PATH |
| `NAME` (`--launcher`)   | `exec PATH "$@"`     | `qemu-i386` + shim via a symlink named NAME  |

`run-i386` is for build steps and wrappers that take a "debugger" or runner
command. `PROG` must be an ELF binary: qemu can't run a shell script, so
point it at the binary the script would exec.

A launcher runs `qemu-i386` through a symlink called `NAME`
(`/usr/local/libexec/i386-kit/emu/NAME`). The kernel names the process after
that symlink, so `/proc/PID/comm`, `pgrep -x NAME`, `pidof` and existing
health checks see `NAME` instead of `qemu-i386`. Pick `NAME` = the binary's
basename and they behave the same on every architecture. The binary doesn't
need to exist when the launcher is created (SteamCMD can fetch it later).
Keep `NAME` to 15 characters: that is all the kernel stores in `comm`, so a
longer name is cut off and `pgrep -x NAME` stops matching (`install` warns).
`tests/launcher-comm.sh` checks all of this in the example image, and CI runs
it on both architectures.

Both preload the shim ahead of any `LD_PRELOAD` you set for the guest, and
pass `I386_FAKE_CPUINFO`. The shim takes itself out of `LD_PRELOAD` once it
is loaded, so native (arm64) programs the i386 process starts don't inherit
an i386 preload and make `ld.so` complain about `wrong ELF class: ELFCLASS32`.
An i386 child has to go through `run-i386` or a launcher anyway, and gets the
shim again there. `I386_SHIM_INHERIT=1` turns that off.

The generated wrappers single-quote their paths, so a launcher target or
SteamCMD directory with spaces works.

## `image/i386-qemu-shim.c`: why it exists

Valve's 32-bit libraries trip over two places where qemu-user is not a real
x86 kernel. The shim is an `LD_PRELOAD` library, loaded only by `run-i386` and
the launchers; x86 images never contain it.

1. **`get_robust_list`.** qemu-user doesn't implement
   `set_robust_list`/`get_robust_list` (they return `ENOSYS`).
   `steamclient.so` reads the list back as a sanity check and aborts with
   `futex robust_list not initialized by pthreads`. The shim wraps
   `syscall()` and answers `SYS_get_robust_list` with a per-thread list head
   shaped like glibc's own (an empty circular list with glibc's
   `futex_offset`), or the head the thread registered through
   `SYS_set_robust_list`. Nothing walks it under emulation; it only has to
   pass the check. Without it: no `steamclient.so`, so no Steam-authenticated
   (VAC/secure) server.
2. **`/proc/cpuinfo`.** Under qemu-user it still describes the host ARM CPU,
   and SteamCMD exits 1 when it finds no x86 `flags` line. The shim redirects
   `open`/`open64`/`openat`/`openat64`/`fopen`/`fopen64` of exactly
   `/proc/cpuinfo` to `$I386_FAKE_CPUINFO` (an x86 cpuinfo written at install
   time). It can't be done with a bind mount: Apple `container` won't mount
   over `/proc`, and `RUN unshare` is blocked during builds.

Also needed, though not in the shim: `ca-certificates`, without which
steamclient stays `disconnected from Steam3`. `i386-compat.sh` always
installs it.

## SteamCMD

[`image/install-steamcmd.sh`](image/install-steamcmd.sh) installs SteamCMD
into `/opt/steamcmd` and a `/usr/local/bin/steamcmd` wrapper. The whole recipe
is two variables:

```bash
DEBUGGER=run-i386 STEAM_PLATFORM=linux32 /opt/steamcmd/steamcmd.sh +login anonymous ...
```

- `steamcmd.sh` launches its binary as `$DEBUGGER linux32/steamcmd …`, so
  `DEBUGGER=run-i386` runs it under qemu-i386 on arm64 and is a plain exec on
  x86.
- Without `STEAM_PLATFORM=linux32`, `steamcmd.sh` on arm64 picks a
  `linuxarm64` build that Valve doesn't ship. (`linux32` is already the
  default on x86.)

**SteamCMD itself is always a 32-bit x86 binary**, even when the server it
downloads is 64-bit. So this helps any SteamCMD-installed server on arm64,
not only 32-bit ones: in a `linux/amd64` image under Rosetta, SteamCMD
can't run at all. The first `steamcmd +quit` self-updates (a ~40 MB
download, about 200 MB unpacked) and may exit 1 right after updating; run it at build time (`install-steamcmd.sh
--bootstrap`, or as in the example) so containers don't redo it.

For a 64-bit x86 server, the kit gets SteamCMD working in an arm64 image;
running the x86_64 server binary itself still needs Rosetta (or a native
arm64 build, if the game ships one). That combination isn't verified here.

## Apple `container` notes

Findings from porting three servers (cs-server, minecraft-server,
mc-dad-server) to Apple `container` 1.7:

- Apple's builder doesn't set `TARGETARCH`: don't pick stages with
  `FROM base-${TARGETARCH}`. `i386-compat.sh` asks `dpkg` instead.
- It can emulate whole `linux/386` build stages, but an amd64 (Rosetta)
  stage can't exec i386 children.
- `RUN unshare` is blocked in builds; you can't mount over `/proc` at all.
- `container stop`'s default grace period is 5 s; pass `-t`.
- Named volumes are a fresh root-owned ext4 with `lost+found` at the top, so
  non-root images can't write to them until chowned.
- `-c` means `--cpus` in `container` but `--cpu-shares` in podman/docker.
  Use the long forms `--memory`/`--cpus` in shared scripts.
- Single-file `-v host:ctr:ro` binds work.

## `macos/container-launchd`: run it as a login service

A generic version of the launchd wrapper (the macOS stand-in for a Quadlet or
systemd unit). One config file per service:

```bash
mkdir -p ~/.config/container-launchd
cp macos/example.conf ~/.config/container-launchd/myserver.conf   # edit it
macos/container-launchd myserver install
```

```
container-launchd CONFIG install | build | status | logs [-f] | restart
                         | stop | start | uninstall [--image] | plist | serve
```

`CONFIG` is a file path or `NAME` for `~/.config/container-launchd/NAME.conf`.
The config is bash: `NAME`, `IMAGE` (required), `PORTS=()`, `MOUNTS=()`,
`ENV=()`, `ENV_FILE`, `MEMORY`, `CPUS`, `STOP_TIMEOUT`, `RUN_ARGS=()`,
`CMD=()`, `VOLUME_OWNER`, `LABEL`, `LOG_DIR`, `LOG_MAX_MB`, and optionally
`BUILD_CONTEXT`/`CONTAINERFILE`/`PLATFORM` to build the image when it's
missing. See
[`macos/example.conf`](macos/example.conf).

- The agent (`local.container-launchd.NAME`, from
  [`container-launchd.plist.in`](macos/container-launchd.plist.in)) runs
  `container-launchd CONFIG serve`, which `exec`s `container run --rm`
  in the foreground. Logs go to `~/Library/Logs/container-launchd/NAME.log`
  (`LOG_DIR`).
- launchd never trims that file. Each time the service starts, a log over
  `LOG_MAX_MB` (default 10; 0 = never) is copied to `NAME.log.1` and emptied.
  A service that runs for months without a restart isn't trimmed in between.
- `KeepAlive { SuccessfulExit = false }`: launchd restarts it after a crash
  or killed VM but not after a graceful stop. `stop` runs
  `container stop -t STOP_TIMEOUT` and unloads the agent; `ExitTimeOut` is
  `STOP_TIMEOUT + 15` so launchd doesn't SIGKILL a clean shutdown.
- `VOLUME_OWNER=uid:gid` chowns the top of every named-volume mount before
  each start (the root-owned volume issue above).
- Uses `--memory`/`--cpus`, starts `container system` if needed, and runs
  under macOS's stock bash 3.2.
- The plist points at the script by absolute path. Move the kit, then run
  `install` again.

## Layout

```
image/i386-compat.sh        per-arch i386 userland, run-i386, launchers
image/i386-qemu-shim.c      LD_PRELOAD shim (get_robust_list, /proc/cpuinfo)
image/install-steamcmd.sh   SteamCMD + DEBUGGER/STEAM_PLATFORM wrapper
macos/container-launchd     launchd wrapper for one Apple container service
macos/container-launchd.plist.in, macos/example.conf
probe.sh                    which binaries need what
examples/Containerfile      SteamCMD image + i386 smoke test (examples/hello.c)
tests/launcher-comm.sh      comm / pgrep -x / pidof check for a launcher (CI)
justfile                    lint / test recipes
```

## Status

Verified on an Apple silicon Mac with Apple `container` 1.7.1 and Debian
trixie (qemu 10.0):

- `examples/Containerfile` builds for `linux/arm64`; the i386 smoke test
  passes (dynamic libc6:i386, shim robust list, fake cpuinfo); SteamCMD
  self-updates and runs (build time as root, run time as uid 1000);
  `/proc/PID/comm` of a launcher is `NAME` and `pgrep -x NAME` finds it.
- `--i386-pkg`, `$I386_EXTRA_PACKAGES` and `--launcher` in a plain
  `debian:trixie-slim` container; build tools purged afterwards.
- `probe.sh` on arm64, amd64 and i386-payload images.
- The amd64 path of `i386-compat.sh` (multiarch `:i386` libs, plain-exec
  `run-i386`): CI builds the example on `ubuntu-latest` and runs the i386
  smoke test and SteamCMD. **Docker caveat on x86_64 Linux hosts:** Docker
  29's default seccomp profile answers 32-bit `socket()` with `ENOSYS`, so
  native i386 code gets no network at all (SteamCMD: "needs to be online to
  update"; curl: "Could not resolve host"). Run such containers with
  `--security-opt seccomp=unconfined` (or a profile that allows the i386
  socket syscalls), and build with buildx's `docker-container` driver.
  Apple silicon is unaffected: qemu-i386 issues 64-bit syscalls.
- `container-launchd serve` (ports, env, named volume + `VOLUME_OWNER`) and
  plist rendering (`plutil -lint`, paths with `&#<>`) under bash 3.2 and 5.

- CI builds the example on `ubuntu-24.04-arm` as well (qemu-i386 path) and
  runs the smoke test, `tests/launcher-comm.sh`, a native child started from
  the i386 process (no `LD_PRELOAD` inherited) and SteamCMD.

Not verified:

- log rotation (`LOG_MAX_MB`) under a live launchd: tested with `serve` run
  by hand on Linux and its output appended to the log file;

- `container-launchd install`/`stop`/`restart`/`uninstall` against a live
  launchd (the same flow as cs-server's `ops/cs-server`, which is in use);
- Ubuntu bases (arm64 needs extra apt sources for i386) and zstd layers;
- running a 64-bit x86 server fetched by SteamCMD in an arm64 image.

## License

The kit (scripts, shim, examples) is MIT. See [LICENSE](LICENSE).

**Images built with it for arm64 also contain QEMU.** On non-x86,
`i386-compat.sh` copies Debian's `qemu-i386` binary to
`/usr/local/bin/qemu-i386`, and QEMU is licensed under the GNU GPL version 2
(the static binary also carries the libraries it links, such as LGPL glib).
Building and running such an image for yourself asks nothing of you. If you
**distribute** it (push it to a public registry, hand it to someone), you are
distributing a GPLv2 binary and have to meet GPLv2 section 3: pass on the
license and make the corresponding source available (ship it alongside, or
give a written offer for it). To make that practical, the image keeps:

- `/usr/local/share/i386-kit/qemu-i386.copyright`: Debian's copyright file
  for the package, with the license terms;
- `/usr/local/share/i386-kit/qemu-i386.SOURCE`: the Debian source package
  and exact version the binary came from, and where to fetch it
  (<https://snapshot.debian.org/package/qemu/>, or `apt-get source`).

The binary is unmodified, so that Debian source package is the corresponding
source; a pointer to someone else's download is not by itself a written
offer, so mirror the source (or publish your own offer) if you distribute
images for real. The shim is a separate MIT work: it is loaded into the i386
guest process, not linked into QEMU. amd64 images contain no QEMU. This is a
summary, not legal advice.
