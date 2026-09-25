#!/usr/bin/env python3
"""Multiplayer smoke and load tests with headless bot clients.

  python tools/bots.py smoke            # 2 social bots must meet, talk, chat and wave
  python tools/bots.py load --bots 16   # wander bots, prints server tick/bandwidth stats

Set GODOT to the Godot 4 console binary if it is not on PATH.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / "game"


def godot_binary() -> str:
    candidates = [os.environ.get("GODOT", "")]
    candidates += [shutil.which(n) or "" for n in ("godot4", "godot", "Godot_v4.7.2-stable_win64_console.exe")]
    local = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "Godot"
    if local.exists():
        candidates += [str(p) for p in sorted(local.glob("Godot_v4*_console.exe"))]
    for c in candidates:
        if c and Path(c).exists():
            return c
    sys.exit("Godot 4 not found: set the GODOT environment variable")


class Proc:
    def __init__(self, name: str, args: list[str]):
        self.name = name
        self.lines: list[str] = []
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, encoding="utf-8", errors="replace")
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    def _read(self) -> None:
        for line in self.proc.stdout:
            self.lines.append(line.rstrip())

    def wait_for(self, needle: str, timeout: float) -> bool:
        end = time.time() + timeout
        while time.time() < end:
            if any(needle in l for l in self.lines):
                return True
            if self.proc.poll() is not None and not self._reader.is_alive():
                return any(needle in l for l in self.lines)
            time.sleep(0.1)
        return False

    def finish(self, timeout: float) -> int:
        try:
            return self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            return -9
        finally:
            self._reader.join(timeout=2)

    def has(self, needle: str) -> bool:
        return any(needle in l for l in self.lines)

    def errors(self) -> list[str]:
        return [l for l in self.lines if "SCRIPT ERROR" in l or l.startswith("ERROR")]


def godot(*user_args: str, headless: bool = True) -> list[str]:
    args = [godot_binary()]
    if headless:
        args.append("--headless")
    return args + ["--path", str(GAME), "--", *user_args]


def address(port: int, transport: str) -> str:
    return f"ws://127.0.0.1:{port}" if transport == "ws" else f"127.0.0.1:{port}"


def start_server(port: int, data_dir: str, quit_after: int, extra: list[str]) -> Proc:
    server = Proc("server", godot("--server", f"--port={port}", f"--data-dir={data_dir}",
                                  f"--quit-after={quit_after}", *extra))
    if not server.wait_for("listening on", 30):
        print("\n".join(server.lines))
        sys.exit("server did not start")
    return server


def cmd_smoke(args) -> int:
    data_dir = tempfile.mkdtemp(prefix="soa_smoke_")
    server = start_server(args.port, data_dir, args.seconds + 20, ["--cluster", f"--transport={args.transport}"])
    bots = [Proc(n, godot(f"--bot=social", f"--connect={address(args.port, args.transport)}", f"--name={n}",
                          f"--quit-after={args.seconds}")) for n in ("BotA", "BotB")]
    for b in bots:
        b.finish(args.seconds + 30)
    server.proc.terminate()
    server.finish(10)

    checks = [
        (server, "BotA joined"), (server, "BotB joined"),
        (bots[0], "welcome id="), (bots[1], "welcome id="),
        (bots[0], "sees BotB"), (bots[1], "sees BotA"),
        (bots[0], "conversation open with BotB"), (bots[1], "conversation open with BotA"),
        (bots[0], "chat from BotB: merhaba"), (bots[1], "chat from BotA: merhaba"),
        (bots[0], "BotB did wave"), (bots[1], "BotA did wave"),
        (bots[0], "stats snapshots="), (bots[1], "stats snapshots="),
    ]
    failed = [f"{p.name}: missing '{needle}'" for p, needle in checks if not p.has(needle)]
    for p in [server, *bots]:
        failed += [f"{p.name}: {e}" for e in p.errors()]

    # Prediction must agree with the server: on a clean localhost link any
    # correction beyond a few centimetres means client and server diverged.
    for b in bots:
        line = next((l for l in b.lines if "max_correction=" in l), "")
        if line and float(line.split("max_correction=")[1].split("m")[0]) > 0.25:
            failed.append(f"{b.name}: prediction diverged from server ({line.split('] ', 1)[1]})")

    accounts = json.loads((Path(data_dir) / "accounts.json").read_text(encoding="utf-8"))
    audit = (Path(data_dir) / "audit.jsonl").read_text(encoding="utf-8").splitlines()
    if len(accounts) != 2:
        failed.append(f"expected 2 persisted accounts, found {len(accounts)}")
    if not all("location" in a and "avatar" in a for a in accounts.values()):
        failed.append("accounts missing location or avatar")
    if sum('"event":"join"' in l for l in audit) != 2:
        failed.append("expected 2 join audit events")

    for b in bots:
        print(next((l for l in b.lines if "stats snapshots=" in l), f"[{b.name}] no stats"))
    if args.verbose or failed:
        for p in [server, *bots]:
            print(f"--- {p.name} ---")
            print("\n".join(p.lines[-40:]))
    shutil.rmtree(data_dir, ignore_errors=True)
    if failed:
        print("SMOKE TEST FAILED")
        for f in failed:
            print("  " + f)
        return 1
    print(f"SMOKE TEST PASSED over {args.transport} ({len(checks)} checks, persistence verified)")
    return 0


def cmd_commute(args) -> int:
    """Commuter bots run to a stop, board the next tram, request a stop and get off."""
    data_dir = tempfile.mkdtemp(prefix="soa_commute_")
    server = start_server(args.port, data_dir, args.seconds + 30, ["--cluster", f"--transport={args.transport}"])
    names = ["Yolcu1", "Yolcu2"]
    bots = [Proc(n, godot("--bot=commuter", f"--connect={address(args.port, args.transport)}", f"--name={n}",
                          f"--quit-after={args.seconds}")) for n in names]
    end = time.time() + args.seconds + 20
    while time.time() < end and not all(b.has("commute complete") for b in bots):
        time.sleep(1)
    for b in bots:
        b.proc.terminate()
        b.finish(10)
    server.proc.terminate()
    server.finish(10)
    failed = []
    for b in bots:
        for needle in ("commute plan:", "boarded", "alighted at", "commute complete"):
            if not b.has(needle):
                failed.append(f"{b.name}: missing '{needle}'")
        failed += [f"{b.name}: {e}" for e in b.errors()]
        print(" | ".join(l.split("] ", 1)[-1] for l in b.lines if any(k in l for k in ("plan:", "boarded", "alighted", "complete"))))
    for n in names:
        if not server.has(f"{n} boarded") or not server.has(f"{n} left"):
            failed.append(f"server did not log {n} boarding and leaving the tram")
    failed += [f"server: {e}" for e in server.errors()]
    shutil.rmtree(data_dir, ignore_errors=True)
    if failed:
        print("COMMUTE TEST FAILED")
        for f in failed:
            print("  " + f)
        if args.verbose:
            for p in [server, *bots]:
                print(f"--- {p.name} ---")
                print("\n".join(p.lines[-30:]))
        return 1
    print(f"COMMUTE TEST PASSED over {args.transport}: both riders boarded and got off at the next stop")
    return 0


def cmd_load(args) -> int:
    data_dir = tempfile.mkdtemp(prefix="soa_load_")
    extra = (["--cluster"] if args.cluster else []) + [f"--transport={args.transport}"]
    server = start_server(args.port, data_dir, args.seconds + 30, extra)
    bots = []
    for i in range(args.bots):
        bots.append(Proc(f"Bot{i:02d}", godot("--bot=wander", f"--connect={address(args.port, args.transport)}",
                                              f"--name=Bot{i:02d}", f"--quit-after={args.seconds}")))
        time.sleep(0.2)
    for b in bots:
        b.finish(args.seconds + 40)
    server.proc.terminate()
    server.finish(10)
    for l in server.lines:
        if "stats:" in l:
            print(l)
    worst = 0.0
    for b in bots:
        line = next((l for l in b.lines if "stats snapshots=" in l), "")
        if "max_correction=" in line:
            worst = max(worst, float(line.split("max_correction=")[1].split("m")[0]))
    errors = [f"{p.name}: {e}" for p in [server, *bots] for e in p.errors()]
    finished = sum(1 for b in bots if b.has("stats snapshots="))
    print(f"{finished}/{len(bots)} bots finished cleanly, worst prediction correction {worst:.3f} m")
    shutil.rmtree(data_dir, ignore_errors=True)
    for e in errors[:20]:
        print("  " + e)
    return 0 if finished == len(bots) and not errors else 1


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("smoke")
    p.add_argument("--port", type=int, default=7011)
    p.add_argument("--seconds", type=int, default=22)
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--transport", choices=["enet", "ws"], default="enet")
    p.set_defaults(func=cmd_smoke)
    p = sub.add_parser("commute")
    p.add_argument("--port", type=int, default=7013)
    p.add_argument("--seconds", type=int, default=240)
    p.add_argument("--transport", choices=["enet", "ws"], default="enet")
    p.add_argument("-v", "--verbose", action="store_true")
    p.set_defaults(func=cmd_commute)
    p = sub.add_parser("load")
    p.add_argument("--port", type=int, default=7012)
    p.add_argument("--bots", type=int, default=8)
    p.add_argument("--seconds", type=int, default=30)
    p.add_argument("--cluster", action="store_true", help="spawn everyone in one spot (worst case)")
    p.add_argument("--transport", choices=["enet", "ws"], default="enet")
    p.set_defaults(func=cmd_load)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
