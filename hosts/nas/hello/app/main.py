"""Tiny HTTP service used to prove the build-and-deploy pipeline end to end."""

import json
import os
import socket
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STARTED = datetime.now(timezone.utc).isoformat(timespec="seconds")
GREETING = os.environ.get("GREETING", "hello")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, {"status": "ok"})
            return
        self._send(
            200,
            {
                "greeting": GREETING,
                "container": socket.gethostname(),
                "started": STARTED,
            },
        )

    def _send(self, code, body):
        data = json.dumps(body, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        # Keep health checks out of the logs.
        if "/healthz" not in (args[0] if args else ""):
            super().log_message(fmt, *args)


if __name__ == "__main__":
    print(f"hello listening on :8080 (started {STARTED})")
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
