#!/bin/sh
# ungate.sh — Ultra Explorer subscription gate bypass (v1.3.0)
#
# Three patches to ultra-server:
#
#   A, B: the two monomorphized serde serializers of the ProductAccessStatus
#         enum. v1.3.0 restructured the JSON shape to {"status":"allowed"} /
#         {"status":"denied","reason":...} with reason in
#         {requires_pro, entitlements_unavailable}. Each serializer selects
#         the "allowed" arm via `cmp $0x2,<disc>; jne <denied arm>`; NOP the
#         jne so every variant renders {"status":"allowed"} in
#         /api/product-access. (x86-64 file offsets; .text file_off = VA - 0x1000)
#           A: file 25906636 (VA 0x18b5dcc)  jne +0x9a  -> 6x NOP   (serializer h88b25f36db6f10a1)
#           B: file 25939210 (VA 0x18bdd0a)  jne +0x137 -> 6x NOP   (serializer hf476a6825d62a266)
#
#   C: AppService::admit_product_access (VA 0xf6f230, h1a9a6a537494d3e3) — the
#      runtime gate that blocks non-empty feature queries (search etc.) with
#      "This feature requires Pro." The function snapshots RecognizedState and
#      dispatches on a state discriminant byte: (disc&~1)==2 -> requires_pro
#      error, even(0) -> unavailable error, odd(1) -> admitted arm. We replace
#      the `movzbl 0x38(%rsp),%edx` load of that discriminant with
#      `mov $1,%edx; nop` so the admitted arm is always taken. NOTE: must be BA
#      (edx) — the dispatch reads %dl/%sil derived from %edx; B9 (ecx) would
#      leave edx as a residual stack value and re-arm the gate per-environment:
#           C: file 16179857 (VA 0xf6f291)  0f b6 54 24 38 -> ba 01 00 00 90
#
# Idempotent: safe to re-run. Fails loudly if any anchor doesn't match (new
# upstream build — re-locate via LEA xrefs, see SUBSCRIPTION_REMOVALS.md).

set -eu

BIN="${1:-/usr/local/bin/ultra-server}"

[ -f "$BIN" ] || { echo "error: $BIN not found" >&2; exit 1; }

ORIG_SHA="3d935ea14c7b0f50c7c3ecc0562cfd87a6d832680db350060893270367c069af"
PATCHED_SHA="8ca10e36e705be02db8e54ee7f13d2e588db9ebb75298b4852f0713c65045391" # v1.3.0 after A+B+C (2026-10-31)

sha() { sha256sum "$BIN" | cut -d' ' -f1; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# read N bytes at decimal offset into a file (portable: no od -An, no NULs in vars)
read_bytes() { dd if="$BIN" bs=1 skip="$2" count="$1" 2>/dev/null > "$TMPD/cur"; }

# sanity: must be an ELF we know the layout of, else anchors are meaningless
read_bytes 4 0
printf '\177ELF' > "$TMPD/elf"
if ! cmp -s "$TMPD/cur" "$TMPD/elf"; then
    echo "error: $BIN is not an ELF binary — refusing to patch" >&2
    exit 1
fi

patch_at() {
    len="$1"; off="$2"; anchor_octal="$3"; new_octal="$4"; label="$5"
    read_bytes "$len" "$off"
    printf "$anchor_octal" > "$TMPD/exp"
    printf "$new_octal"    > "$TMPD/new"
    if cmp -s "$TMPD/cur" "$TMPD/new"; then
        echo "  [$label] already patched (offset $off)"
    elif cmp -s "$TMPD/cur" "$TMPD/exp"; then
        dd of="$BIN" bs=1 seek="$off" count="$len" conv=notrunc < "$TMPD/new" 2>/dev/null
        # verify the write actually landed (guards against partial writes)
        read_bytes "$len" "$off"
        if ! cmp -s "$TMPD/cur" "$TMPD/new"; then
            echo "error: [$label] write verification failed at offset $off" >&2
            exit 1
        fi
        echo "  [$label] patched (offset $off)"
    else
        echo "error: [$label] anchor mismatch at file offset $off" >&2
        echo "       binary changed upstream — re-locate patch point (see SUBSCRIPTION_REMOVALS.md)" >&2
        exit 1
    fi
}

apply_all() {
    # A/B: jne -> 6x NOP (0x90)
    patch_at 6 25906636 '\017\205\232\000\000\000' '\220\220\220\220\220\220' "A/product-access-serializer"
    patch_at 6 25939210 '\017\205\067\001\000\000' '\220\220\220\220\220\220' "B/status-serializer-twin"
    # C: movzbl 0x38(%rsp),%edx -> mov $1,%edx ; nop   (BA = edx; B9 would be ecx — wrong register)
    patch_at 5 16179857 '\017\266\124\044\070'     '\272\001\000\000\220' "C/admit-product-access"
}

echo "ungate: $BIN"
before=$(sha)
echo "  sha256(before) = $before"

if [ "$before" = "$ORIG_SHA" ]; then
    echo "  known v1.3.0 baseline — applying patches"
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
