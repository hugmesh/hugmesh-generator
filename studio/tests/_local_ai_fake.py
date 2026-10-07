"""A fake Ollama on loopback, shared by the local-AI tests (not a test module itself).

Binds 127.0.0.1 on a free port inside the test process. ``requests`` records every
request as (method, path, body), so a test can assert what was — and was NOT — sent.
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeOllama:
    def __init__(self):
        self.models = [{"name": "qwen3:8b"}]
        self.loaded = [{"name": "qwen3:8b"}]
        self.chunks = ["Hel", "lo ", "there"]
        self.chat_status = 200
        self.error_line = ""
        self.stall = 0.0
        self.redirect = False
        self.requests = []           # (method, path, body-dict)
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _json(self, obj, code=200):
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                outer.requests.append(("GET", self.path, None))
                if outer.redirect and self.path != "/bounced":
                    self.send_response(302)
                    self.send_header("Location", f"http://127.0.0.1:{outer.port}/bounced")
                    self.end_headers()
                    return
                if self.path == "/api/tags":
                    self._json({"models": outer.models})
                elif self.path == "/api/ps":
                    self._json({"models": outer.loaded})
                else:
                    self._json({}, 404)

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}")
                outer.requests.append(("POST", self.path, body))
                if outer.redirect:
                    self.send_response(302)
                    self.send_header("Location", f"http://127.0.0.1:{outer.port}/bounced")
                    self.end_headers()
                    return
                if outer.chat_status != 200:
                    self._json({"error": "model not found"}, outer.chat_status)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/x-ndjson")
                self.end_headers()
                if outer.stall:
                    time.sleep(outer.stall)
                try:
                    for c in outer.chunks:
                        self.wfile.write(json.dumps({"message": {"content": c}, "done": False}).encode() + b"\n")
                        self.wfile.flush()
                    if outer.error_line:
                        self.wfile.write(json.dumps({"error": outer.error_line}).encode() + b"\n")
                    self.wfile.write(json.dumps({"done": True}).encode() + b"\n")
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def host(self):
        return f"127.0.0.1:{self.port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
