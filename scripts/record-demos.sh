#!/usr/bin/env sh
# Record the README demos from data/demo/scenes/*.scene with nvim-demo.
#
#   scripts/record-demos.sh                          # every scene
#   scripts/record-demos.sh data/demo/scenes/01-*.scene   # selected scenes
#
# Each scene writes its GIF and cast to data/demo/out/. Needs nvim, agg, pyte and an
# interpreter with debugpy. nvim-demo
# (https://github.com/mbfoss/nvim-demo-tool) is cloned into
# $XDG_CACHE_HOME/ndap.nvim when missing. Set NVIM_DEMO to a checkout's
# bin/nvim-demo to use that instead.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/ndap.nvim

if [ -n "${NVIM_DEMO:-}" ]; then
    demo=$NVIM_DEMO
else
    tool=$cache/nvim-demo-tool
    demo=$tool/bin/nvim-demo
    if [ ! -x "$demo" ]; then
        mkdir -p "${tool%/*}"
        git clone --depth 1 \
            https://github.com/mbfoss/nvim-demo-tool "$tool"
    fi
fi

# The scenes run here; keep the path short for the exception demo.
work=$cache/work
rm -rf "$work"
mkdir -p "$work"
cp "$root/data/demo/series.py" "$work/series.py"
git -C "$work" init -q
git -C "$work" add series.py
git -C "$work" -c user.email=demo@example.com -c user.name=demo commit -qm series

mkdir -p "$root/data/demo/out"
if [ "$#" -eq 0 ]; then
    set -- "$root"/data/demo/scenes/*.scene
fi

for scene in "$@"; do
    printf '=== %s\n' "$(basename "$scene")"
    # ndap persists breakpoints per project; every take starts clean.
    rm -f "$work/.ndap.json"
    NDAP_DEMO_WORK="$work" "$demo" record "$scene"
done
