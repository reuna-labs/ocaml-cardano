#!/usr/bin/env python3
"""A stand-in for Ogmios on a Unix socket.

The sptmac tender maps a guest vsock connect(cid, port) onto a Unix socket at
$VSOCK_UNIX_DIR/<cid>.<port>, so from the guest's side this is indistinguishable
from a real endpoint. It answers JSON-RPC 2.0 over HTTP/1.1 and echoes the
request id back, the way Ogmios does.
"""
import json, os, socket, sys, threading

path = sys.argv[1]
if os.path.exists(path):
    os.unlink(path)
os.makedirs(os.path.dirname(path), exist_ok=True)

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(4)
print(f"fake-ogmios: listening on {path}", flush=True)

RESULTS = {
    "queryLedgerState/epoch": 651,
    "queryLedgerState/tip": {"slot": 195948511, "id": "d4f7cdc5", "height": 13847351},
}

def serve(conn):
    buf = b""
    while True:
        try:
            data = conn.recv(65536)
        except OSError:
            break
        if not data:
            break
        buf += data
        while b"\r\n\r\n" in buf:
            head, rest = buf.split(b"\r\n\r\n", 1)
            length = 0
            for line in head.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":", 1)[1])
            if len(rest) < length:
                break
            body, buf = rest[:length], rest[length:]
            req = json.loads(body)
            method = req.get("method", "")
            print(f"fake-ogmios: {method} id={req.get('id')}", flush=True)
            reply = json.dumps({
                "jsonrpc": "2.0",
                "method": method,
                "result": RESULTS.get(method, None),
                "id": req.get("id"),
            }).encode()
            conn.sendall(
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                b"Content-Length: " + str(len(reply)).encode() + b"\r\n\r\n" + reply)
    conn.close()

while True:
    conn, _ = srv.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
