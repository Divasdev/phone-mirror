#!/bin/bash
# tell_search_engines.sh — tells Bing and the other search engines that use IndexNow that the site's pages
# changed, so they fetch them now instead of whenever they next come by.
# Usage: Scripts/tell_search_engines.sh      (after the push, once the new site is live)
# Google does not take part in IndexNow: for Google, add the sitemap once in Search Console.
# The key is not a secret. It is the file website/static/<key>.txt, which the site serves so that the
# search engine can see the request really comes from this site.

set -euo pipefail
cd "$(dirname "$0")/.."

SITE=$(sed -n 's/^SITE_URL = "\([^"]*\)".*/\1/p' website/build.py)
KEY=$(basename "$(ls website/static/*.txt | grep -E '/[0-9a-f]{32}\.txt$')" .txt)

if [ "$(curl -fsS --max-time 20 "${SITE}/${KEY}.txt" 2>/dev/null)" != "$KEY" ]; then
    echo "The key file is not on ${SITE} yet. Push first and wait a minute for the new site."
    exit 1
fi

PAGES=$(sed -n 's/.*<loc>\([^<]*\)<\/loc>.*/\1/p' public/sitemap.xml)
BODY=$(python3 -c 'import json, sys
site, key = sys.argv[1], sys.argv[2]
print(json.dumps({"host": site.split("//")[1], "key": key, "keyLocation": f"{site}/{key}.txt",
                  "urlList": sys.argv[3].split()}))' "$SITE" "$KEY" "$PAGES")

STATUS=$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X POST 'https://api.indexnow.org/indexnow' \
    -H 'Content-Type: application/json; charset=utf-8' -d "$BODY")
case "$STATUS" in
    200|202) echo "Told the search engines about $(echo "$PAGES" | wc -l | tr -d ' ') pages (answer ${STATUS})." ;;
    *)       echo "The search engines answered ${STATUS}. Nothing is broken; try again later."; exit 1 ;;
esac
