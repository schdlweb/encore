# Test addon: Cinemeta catalogs/meta + a local MKV for every stream request.
import http.server, json, os, re, sys, urllib.request
# Usage: python3 scripts/test-addon.py <media dir containing test.mkv, addon_en.srt, addon_es.srt>
ROOT = os.path.dirname(os.path.abspath(sys.argv[1] + "/x")) if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
CINEMETA = "https://v3-cinemeta.strem.io"
BASE = "http://127.0.0.1:8765"
MANIFEST = {
  "id": "local.test", "name": "Encore Test Addon", "version": "0.0.1",
  "resources": ["catalog", "meta", "stream", "subtitles"], "types": ["movie", "series"], "idPrefixes": ["tt"],
  "catalogs": [
    {"type": "movie", "id": "top", "name": "Popular Movies", "extra": [{"name": "search"}, {"name": "skip"}, {"name": "genre", "options": ["Action", "Comedy"]}]},
    {"type": "series", "id": "top", "name": "Popular Series", "extra": [{"name": "search"}, {"name": "skip"}]},
    {"type": "movie", "id": "imdbRating", "name": "Top Rated Movies", "extra": [{"name": "skip"}]},
    {"type": "series", "id": "imdbRating", "name": "Top Rated Series", "extra": [{"name": "skip"}]},
    {"type": "movie", "id": "searchonly", "name": "Search Only", "extra": [{"name": "search", "isRequired": True}]}
  ]
}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): sys.stderr.write("%s\n" % self.path)
    def send_json(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p = self.path
        if p == "/manifest.json": return self.send_json(MANIFEST)
        if p.startswith("/catalog/") or p.startswith("/meta/"):
            try:
                with urllib.request.urlopen(urllib.request.Request(CINEMETA + p, headers={"User-Agent": "Mozilla/5.0"}), timeout=30) as r: data = r.read()
                self.send_response(200); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
            except Exception as e:
                self.send_response(502); self.end_headers()
            return
        if p.startswith("/stream/"):
            return self.send_json({"streams": [
                {"name": "Broken\n404", "description": "missing file", "url": BASE + "/media/missing.mkv"},
                {"name": "Failed\ndebrid", "description": "redirects to an AIOStreams error video", "url": BASE + "/playback/fail", "behaviorHints": {"videoSize": 2000000000}},
                {"name": "Local 4K\nHEVC 10-bit", "description": "test.mkv\n🔊 TrueHD 5.1 · DD+ 5.1\n💾 local", "url": BASE + "/media/test.mkv", "behaviorHints": {"bingeGroup": "local-hevc", "filename": "test.mkv"}},
                {"name": "Local (alt)\nsame file", "description": "second source for switching", "url": BASE + "/media/test.mkv?alt=1", "behaviorHints": {"bingeGroup": "local-alt"}},
                {"name": "Torrent\nP2P", "description": "no direct url", "infoHash": "0123456789abcdef0123456789abcdef01234567"}
            ]})
        if p.startswith("/subtitles/"):
            return self.send_json({"subtitles": [
                {"id": "1", "url": BASE + "/media/addon_en.srt", "lang": "eng"},
                {"id": "2", "url": BASE + "/media/addon_es.srt", "lang": "spa"}]})
        if p == "/playback/fail":
            self.send_response(302); self.send_header("Location", BASE + "/static/download_failed.mp4"); self.end_headers(); return
        if p == "/static/download_failed.mp4":
            b = b"\x00" * 4096
            self.send_response(200); self.send_header("Content-Type", "video/mp4"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b); return
        m = re.match(r"^/media/([\w.\-]+)", p)
        if m:
            f = os.path.join(ROOT, m.group(1))
            if not os.path.isfile(f): self.send_response(404); self.end_headers(); return
            size = os.path.getsize(f); start, end = 0, size - 1
            rng = self.headers.get("Range")
            if rng:
                a, _, b = rng.replace("bytes=", "").partition("-")
                start = int(a) if a else 0; end = int(b) if b else size - 1
                self.send_response(206); self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            else:
                self.send_response(200)
            self.send_header("Accept-Ranges", "bytes"); self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Content-Type", "video/x-matroska" if f.endswith(".mkv") else "text/plain"); self.end_headers()
            with open(f, "rb") as fh:
                fh.seek(start); left = end - start + 1
                try:
                    while left > 0:
                        chunk = fh.read(min(1 << 20, left))
                        if not chunk: break
                        self.wfile.write(chunk); left -= len(chunk)
                except (BrokenPipeError, ConnectionResetError): pass
            return
        self.send_response(404); self.end_headers()
http.server.ThreadingHTTPServer(("127.0.0.1", 8765), H).serve_forever()
