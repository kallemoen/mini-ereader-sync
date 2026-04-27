#!/usr/bin/env bash
# Probe the reader's upload endpoint. Run while connected to the E-Paper
# hotspot. Tries several known variants and prints the status code + first
# 200 bytes of the response body for each.
set -u

# Find an epub we've already built, or make a 1-byte file.
EPUB=$(ls -1 "$HOME/Library/Application Support/MiniEreader/epubs/"*.epub 2>/dev/null | head -1)
if [[ -z "${EPUB:-}" ]]; then
  EPUB=/tmp/probe-test.epub
  printf 'probe' > "$EPUB"
fi
echo "Using file: $EPUB ($(wc -c < "$EPUB") bytes)"
echo

try() {
  local label="$1"; shift
  printf '\n--- %s\n' "$label"
  local out
  out=$(curl -s -w '\nHTTP %{http_code}\n' --max-time 15 "$@" http://192.168.3.3/"$ENDPOINT" 2>&1)
  printf '%s\n' "$out" | head -c 500
  echo
}

ENDPOINT="FileUpdata"; try "POST /FileUpdata  field=fileName"               -X POST -F "fileName=@$EPUB"
ENDPOINT="FileUpdata"; try "POST /FileUpdata  field=file"                   -X POST -F "file=@$EPUB"
ENDPOINT="fileupdata"; try "POST /fileupdata (lowercase) field=fileName"    -X POST -F "fileName=@$EPUB"
ENDPOINT="FileUpdate"; try "POST /FileUpdate  field=fileName"               -X POST -F "fileName=@$EPUB"
ENDPOINT="upload";     try "POST /upload      field=file"                   -X POST -F "file=@$EPUB"

ENDPOINT="FileUpdata"; try "POST /FileUpdata + Referer + Origin"  \
  -X POST -F "fileName=@$EPUB" -H "Referer: http://192.168.3.3/" -H "Origin: http://192.168.3.3"

ENDPOINT="Read_fileSync"; try "GET /Read_fileSync (free-space probe)" -X GET
