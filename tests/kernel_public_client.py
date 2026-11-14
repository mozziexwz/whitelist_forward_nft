#!/usr/bin/env python3
"""Public-client half of the disposable-host kernel reboot acceptance."""
import argparse
import ipaddress
import socket

parser = argparse.ArgumentParser()
parser.add_argument("--relay4", required=True)
parser.add_argument("--relay6", required=True)
parser.add_argument("--source4")
parser.add_argument("--source6")
args = parser.parse_args()

cases = (
    ("IPv6 -> IPv6", args.relay6, args.source6, 45981, "v6"),
    ("IPv6 -> IPv4", args.relay6, args.source6, 45982, "v4"),
    ("IPv4 -> IPv6", args.relay4, args.source4, 45983, "v6"),
    ("IPv4 -> IPv4", args.relay4, args.source4, 45984, "v4"),
)
for title, host, source, port, backend in cases:
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    for protocol in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        with socket.socket(family, protocol) as sock:
            sock.settimeout(5)
            if source:
                sock.bind((source, 0))
            if protocol == socket.SOCK_STREAM:
                sock.connect((host, port))
                sock.sendall(b"GET / HTTP/1.0\r\nHost: nft-kernel-test\r\n\r\n")
                data = bytearray()
                while True:
                    part = sock.recv(65535)
                    if not part:
                        break
                    data.extend(part)
                assert data.split(b"\r\n\r\n", 1)[1].strip() == ("nft-kernel-" + backend).encode()
            else:
                payload = b"nft-kernel-public-probe"
                sock.sendto(payload, (host, port))
                data, peer = sock.recvfrom(65535)
                assert data == backend.encode() + b":" + payload
                assert ipaddress.ip_address(peer[0]) == ipaddress.ip_address(host)
                assert peer[1] == port
        print("PASS:", "TCP" if protocol == socket.SOCK_STREAM else "UDP", title)
