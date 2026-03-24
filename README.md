# SpiderNode

Standalone node runtime binaries for the Spiderweb filesystem and capability ecosystem.

SpiderNode exists so operators can run node daemons on Linux/macOS/Windows without cloning the full server repo. It exports filesystem roots and node-hosted capabilities that Spiderweb mounts into the unified namespace.

The node runtime sources now live in this repo under `src/spiderweb_node/`. `SpiderProtocol` remains the shared protocol/runtime substrate dependency, while SpiderNode owns the concrete node daemon and service runtime implementation.

Learn more:
- `docs/overview.md`
- `docs/README.md`

## Quick Build

```bash
zig build -Doptimize=ReleaseSafe
```

## Quick Run (Invite Pairing)

```bash
./zig-out/bin/spiderweb-fs-node \
  --export "work=.:rw" \
  --control-url "ws://<server>:18790/" \
  --control-auth-token "<admin-token>" \
  --pair-mode invite \
  --invite-token "inv-..." \
  --node-name "edge-node"
```
