#!/usr/bin/env python3
"""Function-level GDScript profile of a Godot run, through the remote debugger.

    python tools/gdprof.py --godot <exe> [--top 60] -- <godot args...>

Listens on 127.0.0.1:<port>, starts Godot with --remote-debug, turns on the
script profiler (native calls included) and sums the per-frame data of every
frame. A script can bracket the region to keep with print("GDPROF_ON") and
print("GDPROF_OFF") (the frames in between are kept; without markers, all).
Prints the functions by self time and by total time.
"""
import argparse
import socket
import struct
import subprocess
import sys
import threading
from collections import defaultdict


# --- Variant encoding (the subset the debugger uses) -------------------------

def _pad(n):
    return (4 - n % 4) % 4


def enc(v):
    if v is None:
        return struct.pack("<I", 0)
    if isinstance(v, bool):
        return struct.pack("<II", 1, 1 if v else 0)
    if isinstance(v, int):
        return struct.pack("<Iq", 2 | (1 << 16), v)
    if isinstance(v, float):
        return struct.pack("<Id", 3 | (1 << 16), v)
    if isinstance(v, str):
        b = v.encode("utf-8")
        return struct.pack("<II", 4, len(b)) + b + b"\0" * _pad(len(b))
    if isinstance(v, (list, tuple)):
        return struct.pack("<II", 28, len(v)) + b"".join(enc(x) for x in v)
    raise TypeError(type(v))


class Dec:
    def __init__(self, b):
        self.b = b
        self.p = 0

    def u32(self):
        v = struct.unpack_from("<I", self.b, self.p)[0]
        self.p += 4
        return v

    def take(self, n):
        v = self.b[self.p:self.p + n]
        self.p += n
        return v

    def string(self):
        n = self.u32()
        s = self.take(n).decode("utf-8", "replace")
        self.p += _pad(n)
        return s

    def var(self):
        h = self.u32()
        t = h & 0xFF
        f64 = h & (1 << 16)
        if t == 0:
            return None
        if t == 1:
            return self.u32() != 0
        if t == 2:
            if f64:
                return struct.unpack("<q", self.take(8))[0]
            return struct.unpack("<i", self.take(4))[0]
        if t == 3:
            if f64:
                return struct.unpack("<d", self.take(8))[0]
            return struct.unpack("<f", self.take(4))[0]
        if t in (4, 21, 22):
            if t == 22:
                raise ValueError("nodepath")
            return self.string()
        if t in (5, 6):
            self.take(8)
            return None
        if t in (7, 8, 12, 13, 14, 15, 20):
            self.take(16)
            return None
        if t in (9, 10):
            self.take(12)
            return None
        if t == 24:  # object: id only (encoded as int64 when not full)
            self.take(8)
            return None
        if t == 27:
            n = self.u32() & 0x7FFFFFFF
            d = {}
            for _ in range(n):
                k = self.var()
                d[str(k)] = self.var()
            return d
        if t == 28:
            # Typed arrays (4.x): bits 16-17 container type kind.
            kind = (h >> 16) & 3
            if kind == 1:
                self.u32()
            elif kind in (2, 3):
                self.string()
            n = self.u32() & 0x7FFFFFFF
            return [self.var() for _ in range(n)]
        if t == 29:
            n = self.u32()
            v = self.take(n)
            self.p += _pad(n)
            return v
        if t in (30, 32):
            n = self.u32()
            fmt = "<%d%s" % (n, "i" if t == 30 else "f")
            return list(struct.unpack(fmt, self.take(4 * n)))
        if t in (31, 33):
            n = self.u32()
            fmt = "<%d%s" % (n, "q" if t == 31 else "d")
            return list(struct.unpack(fmt, self.take(8 * n)))
        if t == 34:
            n = self.u32()
            return [self.string() for _ in range(n)]
        raise ValueError("variant type %d" % t)


def send(sock, arr):
    b = enc(arr)
    sock.sendall(struct.pack("<I", len(b)) + b)


def recv_exact(sock, n):
    out = b""
    while len(out) < n:
        c = sock.recv(n - len(out))
        if not c:
            raise EOFError
        out += c
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", required=True)
    ap.add_argument("--port", type=int, default=6117)
    ap.add_argument("--top", type=int, default=60)
    ap.add_argument("--no-native", action="store_true")
    ap.add_argument("--marked", action="store_true",
                    help="keep only frames between EngineDebugger.send_message('gdprof:on'/'gdprof:off')")
    ap.add_argument("rest", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    rest = a.rest[1:] if a.rest and a.rest[0] == "--" else a.rest

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.port))
    srv.listen(1)
    proc = subprocess.Popen([a.godot, "--remote-debug", "tcp://127.0.0.1:%d" % a.port] + rest,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    state = {"on": not a.marked, "marked": False}

    def pump():
        for line in proc.stdout:
            s = line.decode("utf-8", "replace").rstrip()
            if "GDPROF_ON" in s:
                state["on"] = True
                state["marked"] = True
            elif "GDPROF_OFF" in s:
                state["on"] = False
            print(s, flush=True)

    t = threading.Thread(target=pump, daemon=True)
    t.start()
    srv.settimeout(60)
    conn, _ = srv.accept()
    send(conn, ["profiler:servers", 1, [True, [100000, not a.no_native]]])
    sigs = {}
    self_t = defaultdict(float)
    tot_t = defaultdict(float)
    calls = defaultdict(int)
    frames = 0
    kinds = defaultdict(int)
    try:
        while True:
            n = struct.unpack("<I", recv_exact(conn, 4))[0]
            body = recv_exact(conn, n)
            try:
                m = Dec(body).var()
            except Exception as e:  # noqa
                kinds["<undecodable>"] += 1
                continue
            if not isinstance(m, list) or len(m) < 2:
                continue
            name = m[0]
            data = m[-1]
            kinds[name] += 1
            if name == "gdprof:on":
                state["on"] = True
            elif name == "gdprof:off":
                state["on"] = False
            if name == "output":
                for line in (data[0] if data and isinstance(data[0], list) else []):
                    if "GDPROF_ON" in str(line):
                        state["on"] = True
                        state["marked"] = True
                    elif "GDPROF_OFF" in str(line):
                        state["on"] = False
            if name == "servers:function_signature":
                # [name, id]
                if len(data) >= 2:
                    sigs[data[1]] = data[0]
            elif name == "servers:profile_frame":
                if not state["on"]:
                    continue
                frames += 1
                _accumulate(data, sigs, self_t, tot_t, calls)
    except (EOFError, ConnectionError):
        pass
    proc.wait()
    t.join(2)
    print("\nmessages:", dict(kinds))
    print("frames kept: %d" % frames)
    print("\n== self time (ms) ==")
    for k, v in sorted(self_t.items(), key=lambda x: -x[1])[:a.top]:
        print("%10.1f %10.1f %8d  %s" % (v, tot_t[k], calls[k], k))
    print("\n== total time (ms) ==")
    for k, v in sorted(tot_t.items(), key=lambda x: -x[1])[:a.top]:
        print("%10.1f %10.1f %8d  %s" % (self_t[k], v, calls[k], k))


def _accumulate(data, sigs, self_t, tot_t, calls):
    # ServersProfilerFrame: 6 numbers, n_servers, (name, 2k, (fn, t)*k)*,
    # 5m, (sig, calls, self, total, internal)*m
    idx = 7
    for _ in range(int(data[6])):
        idx += 2 + int(data[idx + 1])
    n = int(data[idx]) // 5
    idx += 1
    for i in range(n):
        b = idx + 5 * i
        nm = sigs.get(data[b], "#%s" % data[b])
        calls[nm] += int(data[b + 1])
        self_t[nm] += float(data[b + 2]) * 1000.0
        tot_t[nm] += float(data[b + 3]) * 1000.0


if __name__ == "__main__":
    main()
