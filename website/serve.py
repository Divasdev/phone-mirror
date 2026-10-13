#!/usr/bin/env python3
"""Shows the built website (dist/site) on this Mac only.

Python's own one-line server can't send just a part of a file. Browsers ask for parts of a video
(Safari won't play one otherwise, and no browser can skip ahead), so this small server adds that.
It also shows the site's own "not found" page. Only the standard library is used.

    python3 website/serve.py [port]        # default 8080; stop with Control-C
"""

import gzip
import http.server
import io
import os
import pathlib
import re
import sys

SITE = pathlib.Path(__file__).resolve().parent.parent / "dist" / "site"

# Text is sent compressed, the way every real web host does it, so that sizes and speeds
# measured here are close to what visitors will get.
TEXT = (".html", ".css", ".js", ".svg", ".xml", ".txt", ".vtt", ".json")


class Handler(http.server.SimpleHTTPRequestHandler):
    part_length = None   # set while a "part of a file" answer is being sent

    def send_head(self):
        path = self.translate_path(self.path)
        if not os.path.exists(path):
            return self.not_found()
        wanted = self.headers.get("Range")
        if not wanted:
            return self.compressed(path) or super().send_head()
        if not os.path.isfile(path):
            return super().send_head()

        # "bytes=100-199" (a stretch), "bytes=100-" (from there to the end), "bytes=-500" (the last 500)
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", wanted.strip())
        if not match or match.group(0) == "bytes=-":
            return super().send_head()
        size = os.path.getsize(path)
        first, last = match.group(1), match.group(2)
        if first == "":
            start, end = max(0, size - int(last)), size - 1
        else:
            start, end = int(first), min(int(last) if last else size - 1, size - 1)
        if start >= size or start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return None

        file = open(path, "rb")
        file.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Last-Modified", self.date_time_string(os.path.getmtime(path)))
        self.end_headers()
        self.part_length = end - start + 1
        return file

    def compressed(self, path):
        """The file, gzipped, if it is text and the browser accepts that. Otherwise None."""
        if os.path.isdir(path) and self.path.split("?")[0].endswith("/"):
            path = os.path.join(path, "index.html")
        if not (os.path.isfile(path) and path.endswith(TEXT)
                and "gzip" in self.headers.get("Accept-Encoding", "")):
            return None
        with open(path, "rb") as file:
            body = gzip.compress(file.read(), 6)
        self.send_response(200)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Encoding", "gzip")
        self.send_header("Vary", "Accept-Encoding")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Last-Modified", self.date_time_string(os.path.getmtime(path)))
        self.end_headers()
        return io.BytesIO(body)

    def not_found(self):
        page = SITE / "404.html"
        body = page.read_bytes() if page.exists() else b"Not found"
        self.send_response(404)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        return None

    def end_headers(self):
        self.send_header("Accept-Ranges", "bytes")   # tells browsers that parts can be asked for
        self.send_header("Cache-Control", "no-cache")  # always ask again, so an edited page shows at once
        super().end_headers()

    def copyfile(self, source, outputfile):
        try:
            if self.part_length is None:
                return super().copyfile(source, outputfile)
            left, self.part_length = self.part_length, None
            while left > 0:
                chunk = source.read(min(64 * 1024, left))
                if not chunk:
                    break
                outputfile.write(chunk)
                left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass   # the browser stopped listening (it does that with videos); nothing is wrong


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    if not SITE.exists():
        sys.exit("Build the site first: python3 website/build.py")
    handler = lambda *args: Handler(*args, directory=str(SITE))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)   # 127.0.0.1 = this Mac only
    print(f"Open http://localhost:{port} in your browser. (Only this Mac can see it.)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
