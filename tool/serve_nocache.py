#!/usr/bin/env python3
"""Static file server that disables caching — so Flutter web rebuilds are always
picked up in the preview. Usage: serve_nocache.py <port> <dir>"""
import http.server
import os
import socketserver
import sys

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8123
root = sys.argv[2] if len(sys.argv) > 2 else "."
os.chdir(root)


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, *args):
        pass


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", port), Handler) as httpd:
    httpd.serve_forever()
