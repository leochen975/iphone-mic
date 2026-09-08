#!/usr/bin/env python3
"""
iPhone 无线麦克风服务器 - 流式版

接收 iPhone Safari 通过 HTTPS POST 发来的 16-bit PCM 音频，
以最小缓冲写入本地的 bh_player 进程，最终路由到 BlackHole 2ch。

音频格式约定：
  - 采样率: 44100 Hz
  - 声道数: 1 (mono)
  - 位深:   16-bit signed little-endian
"""

import logging
import os
import re
import socket
import ssl
import subprocess
import threading
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

HOST = "0.0.0.0"
PORT = int(os.environ.get("PORT", 8080))

BASE_DIR = Path(__file__).resolve().parent
BIN_DIR = BASE_DIR / "bin"
# bh_player 位于项目内，不再依赖 /tmp。
BH_PLAYER = os.environ.get("BH_PLAYER", str(BIN_DIR / "bh_player"))
STATIC_DIR = BASE_DIR / "static"

# 与 iPhone 前端约定一致。
SAMPLE_RATE = 44100
CHANNELS = 1
BYTES_PER_SAMPLE = 2

audio_buffer = bytearray()
buffer_lock = threading.Lock()
data_available = threading.Event()

player_proc = None
player_lock = threading.Lock()

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("iphone-mic")


def _is_private_ip(ip):
    """判断是否为局域网私有地址（192.168/10/172.16-31）。"""
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    try:
        octets = [int(p) for p in parts]
    except ValueError:
        return False
    if octets[0] == 10:
        return True
    if octets[0] == 172 and 16 <= octets[1] <= 31:
        return True
    if octets[0] == 192 and octets[1] == 168:
        return True
    return False


def get_local_ip():
    """优先返回局域网私有地址，避免 VPN 虚拟网卡地址。"""
    candidates = []

    try:
        output = subprocess.check_output(["ifconfig"], text=True, stderr=subprocess.DEVNULL)
        candidates.extend(re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", output))
    except Exception:
        pass

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        candidates.append(s.getsockname()[0])
        s.close()
    except Exception:
        pass

    for ip in candidates:
        if _is_private_ip(ip):
            return ip
    for ip in candidates:
        if ip and ip != "127.0.0.1":
            return ip
    return "127.0.0.1"


def start_player():
    """启动 bh_player 进程并返回 Popen 对象。"""
    if not Path(BH_PLAYER).is_file():
        log.error("bh_player not found: %s", BH_PLAYER)
        log.error("Build it with: scripts/build_player.sh")
        return None

    try:
        proc = subprocess.Popen(
            [BH_PLAYER, "--uid", "BlackHole2ch_UID", "--rate", str(SAMPLE_RATE)],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        log.info("bh_player started (pid=%d)", proc.pid)
        return proc
    except Exception as exc:
        log.error("bh_player start failed: %s", exc)
        return None


def player_writer():
    """持续把音频缓冲写入 bh_player，进程退出时自动重启。"""
    global player_proc

    while True:
        with player_lock:
            if player_proc is None or player_proc.poll() is not None:
                if player_proc is not None:
                    log.warning("bh_player exited, restarting...")
                player_proc = start_player()
                if player_proc is None:
                    data_available.wait(timeout=3)
                    continue
            proc = player_proc

        data_available.wait()
        data_available.clear()

        with buffer_lock:
            if not audio_buffer:
                continue
            data = bytes(audio_buffer)
            audio_buffer.clear()

        if proc.poll() is not None:
            continue

        try:
            proc.stdin.write(data)
            proc.stdin.flush()
        except (BrokenPipeError, OSError):
            log.warning("bh_player pipe broken, will restart")
            with player_lock:
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
        elif path == "/stop":
            self._handle_stop()
        else:
            self.send_error(404)

    def _serve_static(self, path):
        safe = path.lstrip("/")
        fp = STATIC_DIR / safe
        try:
            fp = fp.resolve()
            if not str(fp).startswith(str(STATIC_DIR.resolve())):
                self.send_error(403)
                return
        except (ValueError, OSError):
            self.send_error(400)
            return

        if fp.exists() and fp.is_file():
            content = fp.read_bytes()
            content_type = {
                ".html": "text/html; charset=utf-8",
                ".js": "application/javascript",
                ".css": "text/css",
            }.get(fp.suffix, "application/octet-stream")
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(content)
        else:
            self.send_error(404)

    def _handle_audio(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""
        if body:
            with buffer_lock:
                audio_buffer.extend(body)
            data_available.set()
        self._send_json(b'{"ok":true}')

    def _handle_stop(self):
        with buffer_lock:
            audio_buffer.clear()
        self._send_json(b'{"ok":true}')

    def _send_json(self, payload):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        log.info("%s - %s", self.client_address[0], fmt % args)


def main():
    print("=" * 50)
    print("  iPhone Mic Server (streaming)")
    print(f"  Safari: https://{get_local_ip()}:{PORT}")
    print(f"  Player: {BH_PLAYER}")
    print("=" * 50)

    # 先绑定端口，成功后再启动播放线程，避免端口冲突时产生孤儿进程。
    httpd = HTTPServer((HOST, PORT), MicHandler)
    cert_path = BASE_DIR / "cert.pem"
    key_path = BASE_DIR / "key.pem"
    if cert_path.exists() and key_path.exists():
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(cert_path), str(key_path))
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

    thread = threading.Thread(target=player_writer, daemon=True)
    thread.start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        httpd.server_close()
        with player_lock:
            if player_proc is not None:
                player_proc.terminate()


if __name__ == "__main__":
    main()
