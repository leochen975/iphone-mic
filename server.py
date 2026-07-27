#!/usr/bin/env python3
"""
iPhone 无线麦克风服务器 v7 - 流式版
直接将音频流入 bh_player，最小缓冲
"""

import json
import logging
import os
import socket
import ssl
import subprocess
import threading
import time
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

HOST = "0.0.0.0"
PORT = int(os.environ.get("PORT", 8080))
BH_PLAYER = "/tmp/audiowork/bh_player"

# Ring buffer - accumulate audio and feed continuously
audio_buffer = bytearray()
buffer_lock = threading.Lock()
data_available = threading.Event()

player_proc = None
player_lock = threading.Lock()

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("iphone-mic")
BASE_DIR = Path(__file__).parent
STATIC_DIR = BASE_DIR / "static"


def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("10.255.255.255", 1))
    ip = s.getsockname()[0]
    s.close()
    return ip


def player_writer():
    """Continuously feed audio to bh_player"""
    global player_proc
    try:
        player_proc = subprocess.Popen(
            [BH_PLAYER],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log.info("bh_player started")
    except Exception as e:
        log.error(f"bh_player start failed: {e}")
        return

    while True:
        data_available.wait()
        data_available.clear()

        with buffer_lock:
            if not audio_buffer:
                continue
            data = bytes(audio_buffer)
            audio_buffer.clear()

        if player_proc.poll() is not None:
            log.warning("bh_player died, restarting...")
            break

        try:
            player_proc.stdin.write(data)
            player_proc.stdin.flush()
        except BrokenPipeError:
            log.warning("Pipe broken")
            break

    player_proc = None


class MicHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            path = "/index.html"
        self._serve_static(path)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/audio":
            self._handle_audio()
        else:
            self.send_error(404)

    def _serve_static(self, path):
        safe = path.lstrip("/")
        fp = STATIC_DIR / safe
        try:
            fp = fp.resolve()
            if not str(fp).startswith(str(STATIC_DIR.resolve())):
                self.send_error(403); return
        except:
            self.send_error(400); return
        if fp.exists() and fp.is_file():
            c = fp.read_bytes()
            ct = {".html": "text/html; charset=utf-8", ".js": "application/javascript",
                  ".css": "text/css"}.get(fp.suffix, "application/octet-stream")
            self.send_response(200)
            self.send_header("Content-Type", ct)
            self.send_header("Content-Length", str(len(c)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(c)
        else:
            self.send_error(404)

    def _handle_audio(self):
        cl = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(cl) if cl > 0 else b""
        if body:
            with buffer_lock:
                audio_buffer.extend(body)
            data_available.set()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, fmt, *args):
        log.info("%s - %s" % (self.client_address[0], fmt % args))


def main():
    print("=" * 50)
    print("  iPhone Mic Server v7 (streaming)")
    print(f"  Safari: https://{get_local_ip()}:{PORT}")
    print("=" * 50)

    t = threading.Thread(target=player_writer, daemon=True)
    t.start()

    httpd = HTTPServer((HOST, PORT), MicHandler)
    cert_path = BASE_DIR / "cert.pem"
    key_path = BASE_DIR / "key.pem"
    if cert_path.exists() and key_path.exists():
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(cert_path), str(key_path))
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
        httpd.server_close()
        if player_proc:
            player_proc.terminate()


if __name__ == "__main__":
    main()
