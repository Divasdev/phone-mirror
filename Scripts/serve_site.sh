#!/bin/bash
# serve_site.sh — builds the website and shows it on this Mac only, at http://localhost:8080
# Usage: Scripts/serve_site.sh [port]      Stop it with Control-C.
# To change the site, edit website/pages/*.html or website/static/assets/site.css and run this again.

set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${1:-8080}"

[ -f dist/Phone-Mirror.dmg ] || ./release.sh
python3 website/build.py
exec python3 website/serve.py "$PORT"
