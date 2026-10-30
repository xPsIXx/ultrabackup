# Ultra Explorer — Subscription Gate Removals (re-apply log)

Track of every change made to strip the Pro/subscription gating from Ultra
Explorer, so it can be **re-applied on each upstream update**.

Upstream: `https://github.com/Sudo-Rahman/UltraExplorer-Releases` (release
binaries only — no app source is published). Official Docker image:
`ghcr.io/sudo-rahman/ultra-explorer:latest`. Version tracked here: **v1.2.3**.

The Linux Tauri binary ships a Rust backend (`ultra-server`) that enforces the
tier. The browser frontend gates the UI off `GET /api/product-access`. Both
must be satisfied for search / space-analysis / sync to actually work.

## How the gating works (v1.2.3)

- License state lives in `/data/license.json` (`LicenseRecord`, format 1):
  `{format, installationId, pairing, activation, notice, clockFloorMs}`.
- `activation` is an `ActivationRecord` (8 fields):
  `activationId, renewalCredential, slot, generation, activatedAtMs, access, receipt, lastVerifiedAtMs`.
  - `slot` ∈ {`desktop`, `server`}
  - `access` ∈ {`pro`, `verification_required`, ...}
- On boot the server loads the record and **re-verifies online** against
  `https://ultra-explorer.app/api/license/v1` using `renewalCredential`.
  - Verified → keeps `access: pro`.
  - Verification fails OR host unreachable → **demotes to `verification_required`** (fail-closed). There is **no offline grace**: blackholing the license host still yields `free`.
- `/api/product-access` maps the license state → `{state:{status,plan}, capabilities:{search,spaceAnalysis,synchronization}}`. Free tier returns every capability denied / `requires_pro`.
- **Runtime gate (second layer):** beyond the JSON status, feature execution
  (e.g. non-empty search queries) calls `AppService::admit_product_access`
  at runtime; a free state makes it return the error
  `{"code":"product_access_required","message":"This feature requires Pro."}`
  even when the JSON endpoint was patched. Both layers must be bypassed.

## Bypasses that do NOT work (tested) — do not retry

| Approach | Result |
|---|---|
| Env var to disable licensing | No such env var exists. Only `ULTRA_ADMIN_PASSWORD`, `ULTRA_LOCAL_ROOTS`, `ULTRA_RCLONE_CONFIG_FILE`, `ULTRA_SECURE_COOKIES`. |
| Forge `/data/license.json` with `access:pro` | Server re-verifies online; fake `renewalCredential` → demoted to `verification_required` (free). |
| Forge license + blackhole `ultra-explorer.app` (`--add-host`) | Still fail-closed → free. No offline grace window. |
| Patches A+B only (JSON serializers) | `/api/product-access` shows all capabilities `allowed`, but non-empty search queries are still rejected at runtime with `product_access_required`. Patch C is required. |

## The bypass that works: 3 binary patches in `ultra-server`

All offsets are **file offsets** into the v1.2.3 `ultra-server` ELF
(PIE; `.text` VA = file offset + 0x1000). Applied by `ungate.sh`, which
verifies each anchor before writing and fails loudly on mismatch (so a new
upstream build that moved code is detected, never silently mis-patched).

Binary SHAs:
- Original v1.2.3: `5a258e73b94de5f79e33b0c15a9b81da551838b9aeb792fa34db9f329e56c1af`
- After A+B+C (BA/edx variant, current): `f42677b106d7a198373c44fc521ad7cf40e37ca8bd84994a1536e8109363d59d`
- After A+B+C (buggy B9/ecx variant, superseded 2026-10-30): `092e01cf598b9661a22868201f343bcce489840311b3d571672dcfd35064a083`

### Patch A — JSON serializer fall-through (capability status → "allowed")

- **Function:** serde serializer of the capability-status enum,
  `h40e778bab34bc30a` (one of two monomorphized copies).
- **Anchor:** `requires_pro` string at VA 0x33e1b9 → LEA ref at VA 0x1312e80 →
  the `jne` that skips the `"allowed"` arm.
- **Offset / bytes:** file offset **19996156** (VA 0x1312dfc):
  `0f 85 9a 00 00 00` (`jne +0x9a`) → `90 90 90 90 90 90`.

### Patch B — second serializer copy (same effect)

- **Function:** `hbd31bd3ccef1615c` (the other monomorphized copy).
- **Offset / bytes:** file offset **20037098** (VA 0x131cdea):
  `0f 85 37 01 00 00` (`jne +0x137`) → `90 90 90 90 90 90`.

A+B together make `/api/product-access` report every capability
`"status":"allowed"` (note: `state.plan` still reads `"free"` — only the
per-capability status is forced; that is what both the UI and backend check).

### Patch C — runtime admission gate (`admit_product_access`)

- **Function:** `ultra_app_core::service::product_access::<impl AppService>::admit_product_access`
  at VA **0xa73ab0** (len 340). Called only indirectly (registry/vtable), no
  direct call sites. It snapshots the license state (via GOT slot
  VA 0x16F9FE0 → snapshot fn VA 0xa726a0) and dispatches on a discriminant
  byte: even → `requires_pro` error, {2,3} → "unavailable" error, odd(1) → admitted.
- **Anchor:** the `movzbl 0x38(%rsp),%edx` that loads the discriminant, at
  VA **0xa73b11**.
- **Offset / bytes:** file offset **10955537** (VA 0xa73b11):
  `0f b6 54 24 38` → `ba 01 00 00 90` (`mov $1,%edx; nop`) — forces the
  discriminant to the admitted arm regardless of license state.
- **⚠️ Register bug (fixed 2026-10-30):** the first revision wrote
  `b9 01 00 00 90` = `mov $1,%ecx` — wrong register. The branch
  (`test dl,1` at VA 0xa73b22) reads **EDX**, so with B9 the decision fell
  through to a residual stack value in EDX: admitted on some volumes/states,
  `requires_pro` on others (environment-dependent false "verified"/"blocked"
  results). Must be `BA` (edx). `ungate.sh` auto-migrates binaries carrying
  the B9 variant.

## ⚠️ Operational pitfall: data-dir file ownership (fail-closed)

The server runs as unprivileged user `ultra` (UID 10001). If `/data/license.json`
(or anything in `/data`) is **root-owned mode 600**, the server logs
`license record storage failed error=Permission denied` →
`licensing is disabled code=InternalError` and goes **fail-closed**: every gated
request returns `product_access_required` *regardless of the patches*.

This produced a false "patch C doesn't work" result. Fix: data volume contents
must be owned by UID 10001 (`chown -R 10001:10001 /data`). Never run a
root-user container against the same volume without chowning back afterwards.

## Re-applying on an upstream update

1. Pull the new base image: `ghcr.io/sudo-rahman/ultra-explorer:<newtag>`.
2. Build with our Dockerfile (runs `ungate.sh` as root, restores runtime user).
3. If `ungate.sh` fails on anchors, re-locate patch points in the new binary:
   - A/B: find string `requires_pro` in `.rodata` → RIP-relative LEA refs in
     `.text` (target = lea_va + 7 + disp32) → in each serializer function,
     NOP the `jne` that skips the `"allowed"` arm.
   - C: find string `This feature requires Pro.` → its only code ref is inside
     `admit_product_access` → replace the discriminant load
     (`movzbl 0x38(%rsp),%edx`) with `mov $1,%edx; nop`.
4. Verify per the checklist below.

## Verification checklist (per version) — v1.2.3 results

- [x] `/api/product-access` → all capabilities `"status":"allowed"`
      (v1.2.3: `search`, `spaceAnalysis`, `synchronization` all allowed;
      `state.plan` remains `"free"`)
- [x] A real non-empty search runs and returns a `sessionId`
      (BA/edx variant f42677b1, 2026-10-30: 4/4 searches returned sessionIds
      on a fresh volume with phone-home blocked. The 2026-10-28 "verified"
      result on the B9/ecx variant was a false positive — admission depended
      on a residual EDX value that happened to be odd on that volume.)
- [x] gdb cross-check: admitted-arm behavior confirmed by deterministic
      register forcing (`mov $1,%edx`), not by residual-value luck
- [ ] Space analysis runs (not separately exercised; same capability path)
- [ ] Sync is available in UI (same capability path)
