#!/usr/bin/env python3
"""Play from a phone: web build + WebSocket zone server behind one address.

  python tools/serve_web.py                 # export if needed, serve on http://127.0.0.1:8080
  python tools/serve_web.py --bot --cluster # plus an idle bot next to where you spawn
  python tools/serve_web.py --lan           # reachable from phones on the same Wi-Fi
  python tools/serve_web.py --tunnel        # public https URL through a Cloudflare quick tunnel

The page and the game share one origin: /game is forwarded to the zone
server, so the browser connects to wss://<same host>/game behind any HTTPS
tunnel or reverse proxy without CORS or mixed-content problems.
"""
from __future__ import annotations

import argparse
import asyncio
import gzip
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / "game"
BUILD = ROOT / "build" / "web"
sys.path.insert(0, str(Path(__file__).resolve().parent))
from bots import godot_binary  # noqa: E402

MIME = {
    ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".wasm": "application/wasm",
    ".pck": "application/octet-stream", ".png": "image/png", ".svg": "image/svg+xml",
    ".json": "application/json", ".ico": "image/x-icon",
}
COMPRESSIBLE = {".html", ".js", ".wasm", ".pck", ".json", ".svg"}


class WebHost:
    def __init__(self, root: Path, game_port: int):
        self.root = root.resolve()
        self.game_port = game_port
        self._gzip_cache: dict[tuple[Path, float], bytes] = {}

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 20)
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError, ConnectionError):
            writer.close()
            return
        lines = head.decode("latin-1").split("\r\n")
        try:
            method, target, _ = lines[0].split(" ", 2)
        except ValueError:
            writer.close()
            return
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        path = target.split("?", 1)[0]
        try:
            if path == "/game" or path.startswith("/game/"):
                if headers.get("upgrade", "").lower() != "websocket":
                    await self._respond(writer, 400, b"WebSocket only")
                    return
                await self._proxy(head, reader, writer)
            elif method in ("GET", "HEAD"):
                await self._static(writer, path, method == "HEAD", "gzip" in headers.get("accept-encoding", ""))
            else:
                await self._respond(writer, 405, b"Method not allowed")
        except (ConnectionError, OSError):
            pass
        finally:
            if not writer.is_closing():
                writer.close()

    async def _proxy(self, head: bytes, reader, writer) -> None:
        try:
            up_reader, up_writer = await asyncio.open_connection("127.0.0.1", self.game_port)
        except OSError:
            await self._respond(writer, 502, b"Game server is not running")
            return
        up_writer.write(head)

        async def pump(src, dst):
            try:
                while data := await src.read(65536):
                    dst.write(data)
                    await dst.drain()
            except (ConnectionError, OSError):
                pass
            finally:
                if not dst.is_closing():
                    dst.close()

        await asyncio.gather(pump(reader, up_writer), pump(up_reader, writer))

    async def _static(self, writer, path: str, head_only: bool, gzip_ok: bool) -> None:
        rel = path.lstrip("/") or "index.html"
        file = (self.root / rel).resolve()
        if self.root not in file.parents or not file.is_file():
            await self._respond(writer, 404, b"Not found")
            return
        body = file.read_bytes()
        extra = ""
        if gzip_ok and file.suffix in COMPRESSIBLE:
            key = (file, file.stat().st_mtime)
            if key not in self._gzip_cache:
                self._gzip_cache[key] = gzip.compress(body, 6)
            body = self._gzip_cache[key]
            extra = "Content-Encoding: gzip\r\nVary: Accept-Encoding\r\n"
        header = (f"HTTP/1.1 200 OK\r\nContent-Type: {MIME.get(file.suffix, 'application/octet-stream')}\r\n"
                  f"Content-Length: {len(body)}\r\n{extra}Cache-Control: no-cache\r\nConnection: close\r\n\r\n")
        writer.write(header.encode())
        if not head_only:
            writer.write(body)
        await writer.drain()

    @staticmethod
    async def _respond(writer, status: int, text: bytes) -> None:
        reason = {400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 502: "Bad Gateway"}[status]
        writer.write(f"HTTP/1.1 {status} {reason}\r\nContent-Type: text/plain\r\nContent-Length: {len(text)}\r\n"
                     f"Connection: close\r\n\r\n".encode() + text)
        await writer.drain()


def export_web() -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    print("exporting web build ...")
    result = subprocess.run([godot_binary(), "--headless", "--path", str(GAME), "--export-release", "Web",
                             str(BUILD / "index.html")], capture_output=True, text=True, encoding="utf-8",
                            errors="replace")
    errors = [l for l in (result.stdout + result.stderr).splitlines() if "ERROR" in l]
    if result.returncode != 0 or not (BUILD / "index.wasm").exists():
        print("\n".join(errors) or result.stdout[-2000:])
        sys.exit("web export failed (export templates for this Godot version installed?)")
    size = sum(f.stat().st_size for f in BUILD.iterdir()) / 1e6
    print(f"web build ready in {BUILD} ({size:.0f} MB before compression)")


def needs_export() -> bool:
    index = BUILD / "index.pck"
    if not index.exists():
        return True
    built = index.stat().st_mtime
    watched = list(GAME.rglob("*.gd")) + list(GAME.rglob("*.json")) + [GAME / "project.godot"]
    return any(p.stat().st_mtime > built for p in watched if ".godot" not in p.parts)


def spawn(name: str, args: list[str]) -> subprocess.Popen:
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8", errors="replace")

    def forward():
        for line in proc.stdout:
            print(f"[{name}] {line.rstrip()}", flush=True)

    threading.Thread(target=forward, daemon=True).start()
    return proc


def wait_for_port(port: int, timeout: float = 40.0) -> None:
    import time
    end = time.time() + timeout
    while time.time() < end:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            return
        except OSError:
            time.sleep(0.3)
    sys.exit(f"zone server did not start listening on port {port}")


def find_cloudflared() -> str | None:
    local = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "cloudflared" / "cloudflared.exe"
    return shutil.which("cloudflared") or (str(local) if local.exists() else None)


def start_tunnel(port: int) -> subprocess.Popen:
    binary = find_cloudflared()
    if not binary:
        sys.exit("cloudflared not found: install it from https://github.com/cloudflare/cloudflared/releases")
    proc = subprocess.Popen([binary, "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{port}"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                            errors="replace")

    def watch():
        for line in proc.stdout:
            match = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", line)
            if match:
                print("\n" + "=" * 64 + f"\n  Telefondan aç: {match.group(0)}\n" + "=" * 64 + "\n", flush=True)

    threading.Thread(target=watch, daemon=True).start()
    return proc


def lan_addresses() -> list[str]:
    try:
        return sorted({a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)
                       if not a[4][0].startswith("127.")})
    except OSError:
        return []


async def serve(args) -> None:
    host = WebHost(BUILD, args.game_port)
    bind = "0.0.0.0" if args.lan else "127.0.0.1"
    server = await asyncio.start_server(host.handle, bind, args.port)
    print(f"web: http://127.0.0.1:{args.port}")
    if args.lan:
        for ip in lan_addresses():
            print(f"web (same Wi-Fi): http://{ip}:{args.port}")
    async with server:
        await server.serve_forever()


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8080, help="web port")
    parser.add_argument("--game-port", type=int, default=7001, help="WebSocket zone server port")
    parser.add_argument("--zone", default="tr_istanbul_kadikoy_001")
    parser.add_argument("--cluster", action="store_true", help="everyone spawns at the same spot")
    parser.add_argument("--spawn-at", default="", help="with --cluster: spawn spot as east,north metres")
    parser.add_argument("--bot", action="store_true", help="add an idle bot that accepts talk requests")
    parser.add_argument("--export", action="store_true", help="re-export even if the build looks current")
    parser.add_argument("--lan", action="store_true", help="listen on all interfaces, not just localhost")
    parser.add_argument("--tunnel", action="store_true", help="public URL via a Cloudflare quick tunnel")
    args = parser.parse_args()

    if args.export or needs_export():
        export_web()
    procs = [spawn("server", [godot_binary(), "--headless", "--path", str(GAME), "--", "--server",
                              "--transport=ws", f"--port={args.game_port}", f"--zone={args.zone}",
                              *(["--cluster"] if args.cluster else []),
                              *([f"--spawn-at={args.spawn_at}"] if args.spawn_at else [])])]
    wait_for_port(args.game_port)
    if args.bot:
        procs.append(spawn("bot", [godot_binary(), "--headless", "--path", str(GAME), "--", "--bot=idle",
                                   f"--connect=ws://127.0.0.1:{args.game_port}", "--name=Ayşe"]))
    if args.tunnel:
        procs.append(start_tunnel(args.port))
    try:
        asyncio.run(serve(args))
    except KeyboardInterrupt:
        pass
    finally:
        for p in procs:
            p.terminate()
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.default_int_handler)
    sys.exit(main())
