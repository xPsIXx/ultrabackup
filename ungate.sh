#!/bin/sh
# ungate.sh — Ultra Explorer subscription gate bypass (v1.2.3)
#
# Three patches to ultra-server:
#
#   A, B: the two monomorphized serde serializers of the ProductAccessStatus
#         enum. NOP the jne that selects the denied/requires_pro arms so every
#         capability status renders as {"status":"allowed"} in /api/product-access.
#         (x86-64 file offsets; .text file_off = VA - 0x1000)
#           A: file 0x1311dfc  jne +0x9a  -> 6x NOP   (serializer h40e778bab34bc30a)
#           B: file 0x131bdea  jne +0x137 -> 6x NOP   (serializer hbd31bd3ccef1615c)
#
#   C: AppService::admit_product_access (VA 0xa73ab0) — the runtime gate that
#      blocks non-empty feature queries (search etc.) with
#      "This feature requires Pro." The function snapshots RecognizedState and
#      dispatches on a state discriminant byte: even -> requires_pro error,
#      {2,3} -> unavailable error, odd(1) -> admitted arm. We replace the
#      `movzbl 0x38(%rsp),%edx` load of that discriminant with `mov $1,%edx`
#      so the admitted arm is always taken:
#           C: file 0xa72b11 (VA 0xa73b11)  0f b6 54 24 38 -> b9 01 00 00 90
#
# Idempotent: safe to re-run. Fails loudly if any anchor doesn't match (new
# upstream build — re-locate via LEA xrefs, see SUBSCRIPTION_REMOVALS.md).

set -eu

BIN="${1:-/usr/local/bin/ultra-server}"

[ -f "$BIN" ] || { echo "error: $BIN not found" >&2; exit 1; }

ORIG_SHA="5a258e73b94de5f79e33b0c15a9b81da551838b9aeb792fa34db9f329e56c1af"
PATCHED_SHA="" # set after first verified A+B+C patch

sha() { sha256sum "$BIN" | cut -d' ' -f1; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# read N bytes at decimal offset into a file (portable: no od -An, no NULs in vars)
read_bytes() { dd if="$BIN" bs=1 skip="$2" count="$1" 2>/dev/null > "$TMPD/cur"; }

patch_at() {
    len="$1"; off="$2"; anchor_octal="$3"; new_octal="$4"; label="$5"
    read_bytes "$len" "$off"
    printf "$anchor_octal" > "$TMPD/exp"
    printf "$new_octal"    > "$TMPD/new"
    if cmp -s "$TMPD/cur" "$TMPD/new"; then
        echo "  [$label] already patched (offset $off)"
    elif cmp -s "$TMPD/cur" "$TMPD/exp"; then
        dd of="$BIN" bs=1 seek="$off" count="$len" conv=notrunc < "$TMPD/new" 2>/dev/null
        echo "  [$label] patched (offset $off)"
    else
        echo "error: [$label] anchor mismatch at file offset $off" >&2
        echo "       binary changed upstream — re-locate patch point (see SUBSCRIPTION_REMOVALS.md)" >&2
        exit 1
    fi
}

apply_all() {
    # A/B: jne -> 6x NOP (0x90)
    patch_at 6 19996156 '\017\205\232\000\000\000' '\220\220\220\220\220\220' "A/product-access-serializer"
    patch_at 6 20037098 '\017\205\067\001\000\000' '\220\220\220\220\220\220' "B/status-serializer-twin"
    # C: movzbl 0x38(%rsp),%edx -> mov $1,%edx ; nop
    patch_at 5 10955537 '\017\266\124\044\070'     '\271\001\000\000\220' "C/admit-product-access"
}

echo "ungate: $BIN"
before=$(sha)
echo "  sha256(before) = $before"

if [ "$before" = "$ORIG_SHA" ]; then
    echo "  known v1.2.3 baseline — applying patches"
    apply_all
elif [ -n "$PATCHED_SHA" ] && [ "$before" = "$PATCHED_SHA" ]; then
    echo "  already patched (known patched hash) — nothing to do"
else
    # unknown build: try anchors anyway, fail loudly on mismatch
    echo "  unknown baseline — attempting anchor-based patch"
    apply_all
fi

after=$(sha)
echo "  sha256(after)  = $after"
if [ "$before" = "$after" ]; then
    echo "  no changes made (was already patched)"
else
    echo "OK: binary patched. If this is a new upstream build, record the"
    echo "    after-hash as PATCHED_SHA in ungate.sh and update SUBSCRIPTION_REMOVALS.md"
fi
