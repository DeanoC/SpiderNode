# spiderweb-fs-node Operations

This guide covers pairing, terminal services, and manifest-driven service publication.

## Build

```bash
zig build -Doptimize=ReleaseSafe
```

## Linux-Side Windows Build Verification

Cross-compile Windows outputs from Linux:

```bash
TARGET=x86_64-windows-gnu OPTIMIZE=ReleaseSafe RUN_WINE_SMOKE=0 ./scripts/check-windows-build.sh
```

Optional smoke test (requires wine):

```bash
TARGET=x86_64-windows-gnu RUN_WINE_SMOKE=1 ./scripts/check-windows-build.sh
```

## Run (Invite Pairing)

```bash
./zig-out/bin/spiderweb-fs-node \
  --export "work=.:rw" \
  --control-url "ws://<server>:18790/" \
  --control-auth-token "<admin-token>" \
  --pair-mode invite \
  --invite-token "inv-..." \
  --node-name "edge-node"
```

## Built-in Terminal Service

Use `--terminal-id <id>` (repeatable) to publish executable terminal namespaces:

```bash
./zig-out/bin/spiderweb-fs-node \
  --export "work=.:rw" \
  --terminal-id "1" \
  --control-url "ws://<server>:18790/" \
  --control-auth-token "<admin-token>" \
  --pair-mode invite \
  --invite-token "inv-..." \
  --node-name "edge-node"
```

Each terminal service is exposed as:

- service id: `terminal-<id>`
- mount: `/nodes/<node_id>/terminal/<id>`
- invoke path: `control/invoke.json`

Invoke payload examples:

```json
{"command":"echo hello from terminal"}
```

```json
{"argv":["/bin/sh","-lc","echo hello"],"cwd":".","max_output_bytes":65536}
```

## Add Extra Services (Manifest)

`spiderweb-fs-node` can advertise additional namespace services via JSON manifests:

- `--venom-manifest <path>` (repeatable)
- `--venoms-dir <path>` (repeatable, loads `*.json`)

Example:

```bash
./zig-out/bin/spiderweb-fs-node \
  --export "work=.:rw" \
  --control-url "ws://<server>:18790/" \
  --control-auth-token "<admin-token>" \
  --pair-mode request \
  --manifest-reload-interval-ms 2000 \
  --venom-manifest ./examples/services.d/echo.json \
  --venoms-dir ./services.d
```

Manifest shape (minimum):

```json
{
  "service_id": "camera-main",
  "kind": "camera",
  "state": "online",
  "endpoints": ["/nodes/{node_id}/camera"],
  "capabilities": { "still": true },
  "mounts": [
    {
      "mount_id": "camera-main",
      "mount_path": "/nodes/{node_id}/camera",
      "state": "online"
    }
  ],
  "ops": { "model": "namespace", "style": "plan9" },
  "runtime": {
    "type": "native_proc",
    "abi": "namespace-driver-v1",
    "executable_path": "./zig-out/bin/spiderweb-echo-driver"
  },
  "permissions": { "default": "deny-by-default" },
  "schema": { "model": "namespace-mount" },
  "invoke_template": {},
  "help_md": "Camera namespace driver"
}
```

Notes:

- `{node_id}` is expanded at runtime after pairing resolves the real node ID.
- `enabled: false` keeps a manifest file present but inactive.
- Built-in providers and manifest services share one catalog namespace; duplicate service IDs are rejected.
- `invoke_template` seeds namespace `TEMPLATE.json`/`template.json`.

## Reference Driver Invoke Flow

The included `spiderweb-echo-driver` consumes JSON from stdin and returns JSON on stdout. With `echo.json` loaded, the service is projected as a namespace mount (`/nodes/<node_id>/echo`) with:

- `control/invoke.json` (write JSON payload)
- `control/reset` (write any payload to reset state files)
- `SCHEMA.json` / `schema.json`
- `TEMPLATE.json` / `template.json`
- `result.json` (driver stdout)
- `status.json`
- `metrics.json`
- `last_error.txt`
- `config.json` (runtime policy input)
- `health.json` (runtime + supervision state)
- `HOST.json` (runtime host contract metadata)
