#!/usr/bin/env python3
"""Minecraft Server List Ping: exit 0 and print the status JSON if the server answers.

A server binds its port before the worlds are loaded, but status requests are
only answered once the main tick loop runs, so an answer here means the server
genuinely finished starting - unlike a bare TCP connect.

usage: mc-ping.py HOST PORT
"""
import json
import socket
import struct
import sys


def varint(n: int) -> bytes:
    n &= 0xFFFFFFFF
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def recv_exact(s: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed")
        buf += chunk
    return buf


def read_varint(s: socket.socket) -> int:
    n = shift = 0
    while True:
        b = recv_exact(s, 1)[0]
        n |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            return n
        if shift > 35:
            raise ValueError("varint too long")


def ping(host: str, port: int) -> dict:
    with socket.create_connection((host, port), timeout=10) as s:
        s.settimeout(10)
        host_b = host.encode()
        # Handshake: id 0, protocol version (any works for status), host, port, next state 1.
        hs = varint(0) + varint(767) + varint(len(host_b)) + host_b + struct.pack(">H", port) + varint(1)
        s.sendall(varint(len(hs)) + hs)
        # Status request: id 0, no payload.
        s.sendall(varint(1) + varint(0))

        read_varint(s)                      # packet length
        if read_varint(s) != 0:             # packet id
            raise ValueError("unexpected packet id")
        length = read_varint(s)
        return json.loads(recv_exact(s, length).decode("utf-8"))


def main() -> int:
    host, port = sys.argv[1], int(sys.argv[2])
    try:
        status = ping(host, port)
    except Exception as e:  # not up yet, or not answering
        print(f"no answer: {e}", file=sys.stderr)
        return 1
    version = status.get("version", {}).get("name", "?")
    players = status.get("players", {})
    print(f"server answered: version={version} players={players.get('online', '?')}/{players.get('max', '?')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
