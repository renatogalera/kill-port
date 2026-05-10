# kill-port

Native command-line tool for killing the process that is listening on a TCP or UDP port.

`kill-port` is written in Zig and ships as a single binary.

## Status

The current implementation supports Linux, macOS, and Windows.

On Linux, it reads socket tables from `/proc/net`, resolves socket inodes through `/proc/<pid>/fd`, and sends `SIGKILL` directly to matching processes.

On Windows, it uses the native IP Helper API to find the owning PID for TCP and UDP endpoints, then terminates the matching process through Win32 process APIs.

On macOS, it uses `libproc` to inspect process file descriptors, matches TCP and UDP socket metadata, and sends `SIGKILL` directly to matching processes.

## Build

```sh
zig build
```

The binary will be available at:

```sh
zig-out/bin/kill-port
```

Windows builds produce `zig-out/bin/kill-port.exe`.

Optimized build:

```sh
zig build -Doptimize=ReleaseFast
```

## Release Binaries

Tagged releases publish `.tar.gz` archives for:

- `linux-amd64`
- `linux-arm64`
- `macos-amd64`
- `macos-arm64`
- `windows-amd64`
- `windows-arm64`

## Install

```sh
zig build -Doptimize=ReleaseFast --prefix ~/.local
```

Make sure `~/.local/bin` is in your `PATH`.

## Usage

Kill one port:

```sh
kill-port 8080
```

Kill multiple ports:

```sh
kill-port 8080 3000 5000
kill-port --port 8080,3000,5000
```

Match UDP instead of TCP:

```sh
kill-port --port 5353 --method udp
```

Show killed process IDs:

```sh
kill-port 8080 --verbose
```

## Options

```text
-p, --port <ports>      Port or comma-separated ports to kill
-m, --method <method>   Protocol to match: tcp or udp (default: tcp)
-v, --verbose           Print killed PIDs
-h, --help              Show help
-V, --version           Show version
```

## Test

```sh
zig build test
```

## License

MIT
