#!/usr/bin/env python3
"""Mock OpenAI-compatible + Ollama server used to verify OCRLaTeX's HTTP layer."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

FENCED = "```latex\n$$ \\frac{a}{b} $$\n```"
OLLAMA = "\\sum_{i=1}^{n} i"
PROBE = "4"
ALIGNED = "```latex\n\\begin{align*}\nx_{1} &= x = x_{4}\n\\end{align*}\n```"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.endswith("/api/tags"):
            self._send({"models": [{"name": "llava:latest"}, {"name": "qwen2.5vl:7b"}]})
        elif self.path.endswith("/v1/models"):
            self._send({"data": [{"id": "mock-vision"}, {"id": "gpt-4o-mini"}]})
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            request = json.loads(raw)
        except Exception:
            request = {}

        def is_probe(payload):
            blob = json.dumps(payload.get("messages", []))
            return "Solve the arithmetic" in blob

        if self.path.endswith("/v1/chat/completions"):
            if request.get("model") == "boom":
                self._send({"error": {"message": "model exploded"}}, 400)
                return
            if request.get("model") == "text-only":
                self._send({"error": {"message": "this model does not support images"}}, 400)
                return
            if request.get("model") == "align":
                self._send({"choices": [{"message": {"role": "assistant", "content": ALIGNED}}]})
                return
            if is_probe(request):
                self._send({"choices": [{"message": {"role": "assistant", "content": PROBE}}]})
                return
            # Validate the multimodal payload reached us
            messages = request.get("messages", [])
            has_image = any(
                isinstance(m.get("content"), list)
                and any(p.get("type") == "image_url" for p in m["content"])
                for m in messages
            )
            if not has_image:
                self._send({"error": {"message": "no image_url part"}}, 400)
                return
            self._send({"choices": [{"message": {"role": "assistant", "content": FENCED}}]})
        elif self.path.endswith("/api/chat"):
            if is_probe(request):
                self._send({"message": {"role": "assistant", "content": PROBE}, "done": True})
                return
            messages = request.get("messages", [])
            has_images = any(m.get("images") for m in messages)
            if not has_images:
                self._send({"error": "no images"}, 400)
                return
            self._send({"message": {"role": "assistant", "content": OLLAMA}, "done": True})
        else:
            self._send({"error": "not found"}, 404)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
