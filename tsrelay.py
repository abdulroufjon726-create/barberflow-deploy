#!/usr/bin/env python3
"""Oddiy TCP -> SOCKS5 relay.

Render'da tailscaled `userspace-networking` rejimida ishlaydi: TUN qurilmasi
yo'q, shuning uchun tailnet ichidagi TCP manzillarga to'g'ridan-to'g'ri
ulanib bo'lmaydi. Buning o'rniga tailscaled `--socks5-server` proksisini
beradi. psycopg2 SOCKS'ni bilmaydi, shuning uchun shu kichik relay
127.0.0.1:<port> ni tinglaydi va har bir ulanishni SOCKS5 orqali tailnet
manziliga uzatadi.
"""
import socket
import struct
import sys
import threading

SOCKS_HOST = "127.0.0.1"
SOCKS_PORT = 1055


def read_exact(sock, size):
    buf = b""
    while len(buf) < size:
        chunk = sock.recv(size - len(buf))
        if not chunk:
            raise ConnectionError("socks: ulanish uzildi")
        buf += chunk
    return buf


def socks_connect(host, port):
    sock = socket.create_connection((SOCKS_HOST, SOCKS_PORT), timeout=15)
    sock.sendall(b"\x05\x01\x00")
    if read_exact(sock, 2) != b"\x05\x00":
        raise ConnectionError("socks: autentifikatsiya rad etildi")
    sock.sendall(
        b"\x05\x01\x00\x03" + bytes([len(host)]) + host.encode() + struct.pack("!H", port)
    )
    head = read_exact(sock, 4)
    if head[1] != 0:
        raise ConnectionError("socks: xato kodi %d" % head[1])
    atyp = head[3]
    if atyp == 1:
        read_exact(sock, 4)
    elif atyp == 4:
        read_exact(sock, 16)
    else:
        read_exact(sock, read_exact(sock, 1)[0])
    read_exact(sock, 2)
    sock.settimeout(None)
    return sock


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client, host, port):
    try:
        upstream = socks_connect(host, port)
    except Exception as exc:  # noqa: BLE001 - relay hech qachon yiqilmasin
        print("[relay] ulanmadi: %r" % (exc,), flush=True)
        client.close()
        return
    threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
    pump(upstream, client)


def main():
    listen = sys.argv[1]
    target = sys.argv[2]
    listen_host, listen_port = listen.rsplit(":", 1)
    host, target_port = target.rsplit(":", 1)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((listen_host, int(listen_port)))
    server.listen(64)
    print(
        "[relay] %s -> socks %s:%d -> %s:%s"
        % (listen, SOCKS_HOST, SOCKS_PORT, host, target_port),
        flush=True,
    )
    while True:
        client, _ = server.accept()
        threading.Thread(
            target=handle, args=(client, host, int(target_port)), daemon=True
        ).start()


if __name__ == "__main__":
    main()
