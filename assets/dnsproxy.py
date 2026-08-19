#!/usr/bin/env python3
"""dnsproxy.py — no-root DNS fix for Claude Code on Android.

The Claude Code musl (Bun) binary cannot read Android's /etc/resolv.conf
(ENOENT) and its c-ares resolver falls back to 127.0.0.1:53, which no one
answers -> "API error · Retrying" forever.

This runs a tiny localhost HTTP CONNECT proxy. It asks Android's own
resolver (via python's bionic getaddrinfo) for real DNS answers, so the
musl binary never needs to do DNS itself. No root, no proot required.

How it is used: the claude wrapper sets HTTPS_PROXY=http://127.0.0.1:PORT,
starts this proxy on demand, then runs claude. Claude/Bun tunnel HTTPS
(its own TLS) through the proxy; the proxy merely pipes bytes.

Usage:  python3 dnsproxy.py [port]   (default 127.0.0.1:8080)
"""

import socket
import sys
import threading

HOST = "127.0.0.1"
PORT = 8080 if len(sys.argv) < 2 else int(sys.argv[1])
BUF = 65536


def pipe(a, b):
    """Copy bytes a->b until EOF, then shutdown b."""
    try:
        while True:
            data = a.recv(BUF)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        try:
            b.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client, addr):
    try:
        client.settimeout(30)
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = client.recv(BUF)
            if not chunk:
                return
            req += chunk
            if len(req) > 16 * 1024:
                return
        line = req.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        parts = line.split()
        if len(parts) < 2 or parts[0].upper() != "CONNECT":
            client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            return
        host, _, port = parts[1].rpartition(":")
        port = int(port or 443)
        print(f"CONNECT {host}:{port}", flush=True)

        # Resolve via Android's bionic resolver (works on Termux)
        ip = socket.gethostbyname(host)
        upstream = socket.create_connection((ip, port), timeout=15)
        client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        client.settimeout(None)
        upstream.settimeout(None)
        t1 = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
        t2 = threading.Thread(target=pipe, args=(upstream, client), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except Exception:  # noqa: BLE001
        pass
    finally:
        try:
            client.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(64)
    print(f"dnsproxy: listening on {HOST}:{PORT}", flush=True)
    while True:
        c, a = srv.accept()
        threading.Thread(target=handle, args=(c, a), daemon=True).start()


if __name__ == "__main__":
    try:
        main()
    except OSError as e:
        print(f"dnsproxy: error: {e}", flush=True)
        sys.exit(1)