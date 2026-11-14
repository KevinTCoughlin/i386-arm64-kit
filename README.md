# i386-arm64-kit

Run 32-bit x86 (i386) Linux game servers and tools (HLDS, SteamCMD, old
`*_linux` dedicated servers) in containers on Apple silicon, from the same
Containerfile that builds for x86. Rosetta for Linux only translates x86_64;
this kit adds qemu-i386 user-mode emulation plus a small shim for Valve's
Steam libraries, and a launchd wrapper for Apple `container` services.

Extracted from cs-server's Apple silicon support. Work in progress.

## License

MIT. See [LICENSE](LICENSE).
