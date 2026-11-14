# i386-arm64-kit — lint and smoke-test recipes (Apple `container` on macOS)

HADOLINT_IMAGE := "ghcr.io/hadolint/hadolint:v2.15.0-debian"
EXAMPLE_IMAGE := "i386-kit-example:test"

# List recipes
default:
    @just --list

# shellcheck every script, hadolint the example
lint:
    shellcheck --enable=all -x image/i386-compat.sh image/install-steamcmd.sh probe.sh macos/container-launchd macos/example.conf
    container run --rm -i {{HADOLINT_IMAGE}} hadolint - < examples/Containerfile

# Build the example for linux/arm64 and run the i386 smoke test
test:
    container build --platform linux/arm64 -t {{EXAMPLE_IMAGE}} -f examples/Containerfile .
    container run --rm {{EXAMPLE_IMAGE}}
    ./probe.sh {{EXAMPLE_IMAGE}} /opt/hello/hello-i386 /opt/steamcmd/linux32/steamcmd
