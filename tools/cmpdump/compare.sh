#!/bin/sh
# Build the Nuklear and zuklear command-stream dumpers, run them with identical
# input, and diff the canonical command output. A clean diff means zuklear emits
# the same draw commands as Nuklear for the `overview` demo.
#
# Usage: ./compare.sh
set -e
cd "$(dirname "$0")"
ROOT=../..
NK="$ROOT/../nuklear"

# Nuklear reference dumper. -O0 on purpose: Nuklear's type-punning miscompiles
# under -O2 here (segfault), unrelated to the comparison.
zig cc -O0 -I"$NK" dump_nk.c -lm -o dump_nk

# zuklear dumper (headless, reuses examples/.../overview.zig).
( cd "$ROOT" && zig build dump )

# Normalize away the text BACKGROUND color: it is renderer-irrelevant (backends
# draw glyphs transparent) and Nuklear leaves it *uninitialized* for
# NK_TREE_TAB headers, so it is not a meaningful difference.
norm() { sed -E 's/^(TEXT( [0-9-]+){4} [0-9a-f]{8}) [0-9a-f]{8}/\1 ......../'; }

./dump_nk | norm > nk.txt
"$ROOT/zig-out/bin/dump_zk" 2>&1 | norm > zk.txt

if diff -u nk.txt zk.txt; then
    echo "EQUIVALENT: zuklear emits the same command stream as Nuklear."
else
    echo "DIVERGENCE: see the diff above (nk.txt = Nuklear, zk.txt = zuklear)."
    exit 1
fi
