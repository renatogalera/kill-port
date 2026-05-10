# kill-port

Native command-line tool for killing the process that is listening on a TCP or UDP port.

`kill-port` is written in Zig and ships as a single binary. There is no Node.js runtime, package manager dependency, or shell pipeline involved in the port lookup.

## Status

The current implementation supports Linux. It reads socket tables from `/proc/net`, resolves socket inodes through `/proc/<pid>/fd`, and sends `SIGKILL` directly to matching processes.

## Build

```sh
zig build
```

The binary will be available at:

```sh
zig-out/bin/kill-port
```

Optimized build:

```sh
zig build -Doptimize=ReleaseFast
```

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
