#!/usr/bin/env python3
"""Explicitly started TCP/UDP target for the disposable-host reboot acceptance."""
import argparse
import http.server
import socketserver
import threading

parser = argparse.ArgumentParser()
parser.add_argument("--bind", required=True)
parser.add_argument("--tcp", type=int, default=46888)
parser.add_argument("--udp", type=int, default=46889)
parser.add_argument("--body", default="nft-reboot-target")
args = parser.parse_args()


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
        sock.sendto(data, self.client_address)


class HTTPServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer 默认反查服务器 IP；隔离网络没有 DNS，不应因此延迟开始监听。
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


http = HTTPServer((args.bind, args.tcp), HTTP)
udp = socketserver.ThreadingUDPServer((args.bind, args.udp), UDP)
threading.Thread(target=udp.serve_forever, daemon=True).start()
http.serve_forever()
