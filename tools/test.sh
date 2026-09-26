#!/bin/sh
# Runs both test layers inside a Debian container with the real KOReader
# Linux build, so nothing needs installing on the Mac.
#
#   tools/test.sh <koreader-dir> [covers-dir] [out-dir]
#
# <koreader-dir> is an extracted koreader-linux-arm64 release (the folder with
# bin/ and lib/). It must live under $HOME: Colima only shares that with Docker.
set -e
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
KO="${1:?usage: tools/test.sh <koreader-dir> [covers-dir] [out-dir]}"
COVERS="${2:-$PLUGIN/tools/empty}"
OUT="${3:-$HOME/.cache/streakchain-kotest/out}"
mkdir -p "$OUT" "$PLUGIN/tools/empty"

echo "== unit tests"
docker run --rm -e TZ=Asia/Kolkata -v "$KO":/ko:ro -v "$PLUGIN":/plugin:ro -w /plugin \
    debian:bookworm-slim /ko/lib/koreader/luajit tests/run.lua

echo "== KOReader renders and checks"
docker run --rm -e TZ=Asia/Kolkata -e SDL_VIDEO_DRIVER=offscreen -e LC_ALL=C.UTF-8 \
    -e KO_MULTIUSER=1 -e EMULATE_READER_W=1264 -e EMULATE_READER_H=1680 \
    -v "$KO":/ko:ro -v "$PLUGIN":/plugin:ro -v "$COVERS":/covers:ro -v "$OUT":/out \
    -w /ko/lib/koreader debian:bookworm-slim ./luajit /plugin/tools/render.lua /out /covers

echo "== renders in $OUT"
