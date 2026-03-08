#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${TARGET:-x86_64-windows-gnu}"
OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"
RUN_WINE_SMOKE="${RUN_WINE_SMOKE:-auto}"
WINE_TIMEOUT_SECS="${WINE_TIMEOUT_SECS:-20}"

if [[ "$TARGET" != *"windows"* ]]; then
  echo "TARGET must be a Windows target triple, got: $TARGET" >&2
  exit 1
fi

cd "$ROOT_DIR"

if [[ "${ALLOW_ZWASM_WINDOWS_CROSS:-0}" != "1" ]] && grep -q 'b.dependency("zwasm"' deps/spider-protocol/build.zig; then
  echo "==> Skipping Windows cross-build: embedded zwasm is not yet Windows-compatible"
  echo "==> Set ALLOW_ZWASM_WINDOWS_CROSS=1 to force this check once the runtime supports Windows"
  exit 0
fi

echo "==> Cross-compiling SpiderNode for $TARGET ($OPTIMIZE)"
zig build -Dtarget="$TARGET" -Doptimize="$OPTIMIZE"

BIN_DIR="$ROOT_DIR/zig-out/bin"
REQUIRED=(
  "$BIN_DIR/spiderweb-fs-node.exe"
  "$BIN_DIR/spiderweb-echo-driver.exe"
  "$BIN_DIR/spiderweb-web-search-driver.exe"
  "$BIN_DIR/spiderweb-echo-driver-inproc.dll"
  "$BIN_DIR/spiderweb-echo-driver-wasm.wasm"
)

echo "==> Verifying expected artifacts"
for path in "${REQUIRED[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing artifact: $path" >&2
    exit 1
  fi
  echo "ok: $path"
done

if [[ "$RUN_WINE_SMOKE" == "0" || "$RUN_WINE_SMOKE" == "false" || "$RUN_WINE_SMOKE" == "no" ]]; then
  echo "==> RUN_WINE_SMOKE disabled; skipping Wine execution smoke test"
  exit 0
fi

WINE_BIN=""
if command -v wine64 >/dev/null 2>&1; then
  WINE_BIN="$(command -v wine64)"
elif command -v wine >/dev/null 2>&1; then
  WINE_BIN="$(command -v wine)"
fi

if [[ -z "$WINE_BIN" ]]; then
  if [[ "$RUN_WINE_SMOKE" == "1" || "$RUN_WINE_SMOKE" == "true" || "$RUN_WINE_SMOKE" == "yes" ]]; then
    echo "RUN_WINE_SMOKE requested, but wine/wine64 not found" >&2
    exit 1
  fi
  echo "==> Wine not found; skipping optional Windows execution smoke test"
  exit 0
fi

echo "==> Running Windows binary smoke test via $WINE_BIN"
timeout "$WINE_TIMEOUT_SECS" "$WINE_BIN" "$BIN_DIR/spiderweb-fs-node.exe" --help >/tmp/spiderweb-fs-node-win-help.txt 2>&1

echo "Windows smoke output (first 10 lines):"
head -n 10 /tmp/spiderweb-fs-node-win-help.txt || true

echo "Windows cross-build check passed"
