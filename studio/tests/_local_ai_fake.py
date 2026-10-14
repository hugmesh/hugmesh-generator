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
        self.stall = 0.0             # seconds before the first chunk
        self.chunk_delay = 0.0       # seconds between chunks: lets a test act mid-answer
        self.redirect = False
        # A stream that dies. Ollama streams with chunked transfer encoding, so this
        # fake does too when one of these is set. ``cut_in_chunk``: the server declares a
        # chunk longer than it sends and drops the connection — http.client raises
        # IncompleteRead (an HTTPException, NOT an OSError) from the reader's loop.
        # ``cut_between_chunks``: the connection drops after a whole chunk, with no
        # terminating chunk and no ``done`` line — http.client's readline sees a clean
        # end of file, so the reader is handed a truncated answer with no error at all.
        self.cut_in_chunk = False
        self.cut_between_chunks = False
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
                if outer.cut_in_chunk or outer.cut_between_chunks:
                    self._stream_then_cut()
                    return
                self.end_headers()
                if outer.stall:
                    time.sleep(outer.stall)
                try:
                    for i, c in enumerate(outer.chunks):
                        if i and outer.chunk_delay:
                            time.sleep(outer.chunk_delay)
                        self.wfile.write(json.dumps({"message": {"content": c}, "done": False}).encode() + b"\n")
                        self.wfile.flush()
                    if outer.error_line:
                        self.wfile.write(json.dumps({"error": outer.error_line}).encode() + b"\n")
                    self.wfile.write(json.dumps({"done": True}).encode() + b"\n")
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def _stream_then_cut(self):
                """Chunked encoding, every chunk but the last written whole, then the
                connection is dropped: inside the last chunk (declared longer than sent)
                or right after it (no terminating chunk, no ``done`` line)."""
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                lines = [json.dumps({"message": {"content": c}, "done": False}).encode() + b"\n"
                         for c in outer.chunks]
                try:
                    for data in lines[:-1]:
                        self.wfile.write(f"{len(data):X}\r\n".encode() + data + b"\r\n")
                    last = lines[-1]
                    if outer.cut_in_chunk:
                        self.wfile.write(f"{len(last) + 64:X}\r\n".encode() + last[:len(last) // 2])
                    else:
                        self.wfile.write(f"{len(last):X}\r\n".encode() + last + b"\r\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                self.close_connection = True

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def host(self):
        return f"127.0.0.1:{self.port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
