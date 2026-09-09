#!/usr/bin/env python3
# KB Operative taskd v1.0 - rig-side task server for scoped engagement agents.
# stdlib only. File-queue design: operator actions are files under
#   ROOT/<eng>/targets/<host>/tasks/NNN.sh ; KILL / RECALL marker files beat tasks.
# Discipline enforced HERE (auditable, server-side):
#  - engagement phrase proof per beacon: sha256(PHRASE:N); monotonic N + replay guard
#  - EXPIRY epoch in engagement.conf: after it, server answers KILL to every beat
#  - SCOPE cidrs: registration records peer IP; taskctl refuses to queue tasks for
#    hosts whose registered IP is out of scope (see taskctl.sh scope gate)
# v1 honest limits (documented in README): plain HTTP = lab/LAN transport only;
# no public-path crypto story; anti-analysis is NOT the goal - accountability is.
import hashlib, http.server, json, os, re, socketserver, sys, time
ROOT = os.environ.get("KB_OP_ROOT", os.path.expanduser("~/kbop"))
def eng_dir(e): return os.path.join(ROOT, e)
def load_eng(e):
    p = os.path.join(eng_dir(e), "engagement.conf")
    cfg = {}
    if not os.path.isfile(p): return None
    for line in open(p):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line: continue
        k, v = line.split("=", 1); cfg[k.strip()] = v.strip()
    return cfg
def proof_ok(token, n, got):
    if not re.fullmatch(r"\d{1,12}", n): return False
    want = hashlib.sha256(f"{token}:{n}".encode()).hexdigest()
    return got == want

def lastn(hd):
    # per-host high-water mark of accepted beat counters (replay guard)
    try:
        return int(open(os.path.join(hd, "lastn")).read().strip())
    except (OSError, ValueError):
        return -1
class H(http.server.BaseHTTPRequestHandler):
    def _eng(self):
        e = self.headers.get("X-Engagement", "")
        cfg = load_eng(e) if re.fullmatch(r"[A-Za-z0-9_-]{1,40}", e) else None
        if not cfg: return None, None, None
        auth = self.headers.get("Authorization", "")
        m = re.match(r"KBPROOF ([0-9a-f]{64})$", auth)
        q = self.path
        return cfg, e, (m.group(1) if m else "")
    def _send(self, code, body=b""):
        self.send_response(code); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def _host_dir(self, e, hid):
        return os.path.join(eng_dir(e), "targets", hid)
    def do_GET(self):
        cfg, e, got = self._eng()
        if not cfg: return self._send(403, b"bad engagement\n")
        m = re.match(r"^/beat/([A-Za-z0-9_.-]{1,64})/(\d+)$", self.path)
        if m:
            hid, n = m.group(1), m.group(2)
            if not proof_ok(cfg["PHRASE"], n, got): return self._send(403, b"proof\n")
            st = os.path.join(eng_dir(e), "beacons"); os.makedirs(st, exist_ok=True)
            hd = self._host_dir(e, hid); os.makedirs(hd, exist_ok=True)
            # MONOTONIC N: a captured beat header is not replayable (v1 shipped the
            # "strictly increasing" claim in docs WITHOUT enforcing it - exegesis
            # truth-audit 2026-09-09 caught the drift; this guard closes it).
            if int(n) <= lastn(hd): return self._send(403, b"replay\n")
            open(os.path.join(hd, "lastn"), "w").write(n)
            reg = os.path.join(hd, "registered")
            peer = self.client_address[0]
            first = not os.path.isfile(reg)
            with open(reg, "w") as f:
                f.write(f"{time.time()}\n{peer}\n")
            open(os.path.join(st, hid), "w").write(f"{time.time()} n={n} peer={peer}\n")
            # expiry gate: weaponized failsafe (Stuxnet lesson #4, turned to good)
            if time.time() > float(cfg.get("EXPIRY", "9999999999")):
                open(os.path.join(hd, "KILL"), "w").write("expired\n")
            if os.path.isfile(os.path.join(hd, "KILL")): return self._send(200, b"KILL\n")
            if os.path.isfile(os.path.join(hd, "RECALL")): return self._send(200, b"RECALL\n")
            tq = os.path.join(hd, "tasks")
            if os.path.isdir(tq):
                for t in sorted(os.listdir(tq)):
                    if re.fullmatch(r"\d{3,6}\.sh", t):
                        return self._send(200, f"TASK {t}\n".encode())
            return self._send(200, b"NOTASK\n")
        m = re.match(r"^/task/([A-Za-z0-9_.-]{1,64})/(\d{3,6}\.sh)$", self.path)
        if m:
            hid, t = m.groups()
            # task fetch proof must bind to the CURRENT high-water N (old proofs die)
            hb = self.headers.get("X-Beat", "x")
            if not proof_ok(cfg["PHRASE"], hb, got): return self._send(403, b"proof\n")
            if not hb.isdigit() or int(hb) != lastn(self._host_dir(e, hid)): return self._send(403, b"stale\n")
            p = os.path.join(self._host_dir(e, hid), "tasks", t)
            if os.path.isfile(p):
                body = open(p, "rb").read()
                # AT-MOST-ONCE delivery: consumed on fetch. Without this rename the
                # same task re-announces every beat and the agent re-executes it in
                # a loop (witness 2026-09-09: n=1097 = 1 task run ~1100 times).
                try: os.rename(p, p + ".delivered")
                except OSError: pass
                return self._send(200, body)
            return self._send(404, b"gone\n")
        return self._send(404, b"?\n")
    def do_POST(self):
        cfg, e, got = self._eng()
        if not cfg: return self._send(403, b"bad engagement\n")
        m = re.match(r"^/result/([A-Za-z0-9_.-]{1,64})/(\d{3,6}\.sh)$", self.path)
        if m:
            hb = self.headers.get("X-Beat", "x")
            if not proof_ok(cfg["PHRASE"], hb, got): return self._send(403, b"proof\n")
            if not hb.isdigit() or int(hb) != lastn(self._host_dir(e, m.group(1))): return self._send(403, b"stale\n")
            hid, t = m.groups()
            ln = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(min(ln, 200000))
            rd = os.path.join(self._host_dir(e, hid), "results"); os.makedirs(rd, exist_ok=True)
            open(os.path.join(rd, t + ".out"), "wb").write(body)
            return self._send(200, b"got\n")
        if self.path == "/dead":
            hid = self.headers.get("X-Host", "")[:64]
            hb = self.headers.get("X-Beat", "x")
            if not proof_ok(cfg["PHRASE"], hb, got): return self._send(403, b"proof\n")
            if not hb.isdigit() or int(hb) != lastn(self._host_dir(e, hid)): return self._send(403, b"stale\n")
            if hid:
                open(os.path.join(self._host_dir(e, hid), "DEAD"), "w").write(f"{time.time()}\n")
                print(f"[taskd] {e}/{hid}: agent confirmed self-destruct", flush=True)
            return self._send(200, b"rest in peace\n")
        return self._send(404, b"?\n")
    def log_message(self, fmt, *a): pass
class TS(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
    os.makedirs(ROOT, exist_ok=True)
    bind = os.environ.get("KB_OP_BIND", "127.0.0.1")  # lab-witness override; default localhost-only
    print(f"[taskd] root={ROOT} bind={bind} port={port}", flush=True)
    TS((bind, port), H).serve_forever()
