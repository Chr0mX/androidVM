#!/usr/bin/env bash
# Allocate a free TCP port starting from a base, skipping any in use.
#
# alloc_port <base> [reserved_csv]   → echoes the first free port >= base
#
# Uses python3 to bind a socket (POSIX-portable) instead of grepping ss output.

alloc_port() {
  local base="${1:?alloc_port: base port required}"
  local reserved="${2:-}"
  python3 - "$base" "$reserved" <<'PY'
import socket, sys
base = int(sys.argv[1])
reserved = set()
if len(sys.argv) > 2 and sys.argv[2]:
    reserved = {int(p) for p in sys.argv[2].split(",") if p.strip()}
for port in range(base, base + 200):
    if port in reserved:
        continue
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))
    except OSError:
        continue
    finally:
        s.close()
    print(port)
    sys.exit(0)
sys.stderr.write(f"alloc_port: no free port in [{base}, {base+200})\n")
sys.exit(1)
PY
}
