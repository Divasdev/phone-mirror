#!/bin/bash
# publish_site.sh — builds the website and puts the finished copy in public/, the folder the web host serves.
# Usage: Scripts/publish_site.sh
# Then commit and push. The host (Vercel) watches the GitHub repository and shows the new site about a
# minute after the push. Nothing is built on the host: the download can only be made on a Mac, so the
# whole finished site, download included, is made here and kept in the repository.

set -euo pipefail
cd "$(dirname "$0")/.."

[ -f dist/Phone-Mirror.dmg ] || ./release.sh
python3 website/build.py
rm -rf public
ditto dist/site public
echo "public/ is ready: $(find public -type f | wc -l | tr -d ' ') files, $(du -sh public | awk '{print $1}')"
echo "Next: git add -A && git commit -m \"...\" && git push"
