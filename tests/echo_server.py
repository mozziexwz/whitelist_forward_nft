#!/usr/bin/env python3
"""Explicitly started TCP/UDP target for the disposable-host reboot acceptance."""
import argparse
import http.server
import socket
import socketserver
import threading

parser = argparse.ArgumentParser()
parser.add_argument("--bind", required=True)
parser.add_argument("--tcp", type=int, default=46888)
parser.add_argument("--udp", type=int, default=46889)
parser.add_argument("--body", default="nft-reboot-target")
parser.add_argument("--udp-prefix", default="")
args = parser.parse_args()
family = socket.AF_INET6 if ":" in args.bind else socket.AF_INET


class HTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = (args.body + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(args.udp_prefix.encode() + data, self.client_address)


class HTTPServer(http.server.ThreadingHTTPServer):
    address_family = family

    def server_bind(self):
        if family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        # HTTPServer 默认反查服务器 IP；隔离网络没有 DNS，不应因此延迟开始监听。
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class UDPServer(socketserver.ThreadingUDPServer):
    address_family = family
    max_packet_size = 65535

    def server_bind(self):
        if family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


http = HTTPServer((args.bind, args.tcp), HTTP)
udp = UDPServer((args.bind, args.udp), UDP)
threading.Thread(target=udp.serve_forever, daemon=True).start()
http.serve_forever()
