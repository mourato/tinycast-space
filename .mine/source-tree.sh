#!/bin/bash
set -euo pipefail

if (($# > 2)); then
  echo "usage: $0 [repository] [ref]" >&2
  exit 2
fi

repository="${1:-.}"
ref="${2:-HEAD}"
git -C "$repository" rev-parse --verify "$ref^{commit}" >/dev/null
git -C "$repository" ls-tree -r -z --abbrev=40 --full-tree "$ref" -- . |
  python3 -c '
import hashlib
import sys

records = []
for record in sys.stdin.buffer.read().split(b"\0"):
    if not record:
        continue
    path = record.split(b"\t", 1)[1]
    if path == b"Makefile" or path.startswith(b".mine/"):
        continue
    records.append(record + b"\0")

print(hashlib.sha256(b"".join(records)).hexdigest())
'
