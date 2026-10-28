# Ultra Explorer — Subscription Gate Removals (re-apply log)

Track of every change made to strip the Pro/subscription gating from Ultra
Explorer, so it can be **re-applied on each upstream update**.

Upstream: `https://github.com/Sudo-Rahman/UltraExplorer-Releases` (release
binaries only — no app source is published). Official Docker image:
`ghcr.io/sudo-rahman/ultra-explorer:latest`. Version tracked here: **v1.2.3**.

The Linux Tauri binary ships a Rust backend (`ultra-server`) that enforces the
tier. The browser frontend gates the UI off `GET /api/product-access`. Both
must be satisfied for search / space-analysis / sync to actually work.

---

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
- `/api/product-access` maps the license state → `{plan: free|pro, capabilities:{search,spaceAnalysis,synchronization}}`. Free tier returns every capability `denied / requires_pro`.

## Bypasses that do NOT work (tested) — do not retry

| Approach | Result |
|---|---|
| Env var to disable licensing | No such env var exists. Only `ULTRA_ADMIN_PASSWORD`, `ULTRA_LOCAL_ROOTS`, `ULTRA_RCLONE_CONFIG_FILE`, `ULTRA_SECURE_COOKIES`. |
| Forge `/data/license.json` with `access:pro` | Server re-verifies online; fake `renewalCredential` → demoted to `verification_required` (free). |
| Forge license + blackhole `ultra-explorer.app` (`--add-host`) | Still fail-closed → free. No offline grace window. |

## The bypass that works: binary patch at the entitlement decision

A single patch in `ultra-server` forces the entitlement/capability decision to
Pro, which simultaneously (a) makes `/api/product-access` report `plan:pro` +
all capabilities allowed (unlocks the frontend UI) and (b) un-gates the backend
feature execution that reads the same entitlement source.

### Patch P1 — force Pro entitlement

- **File:** `/usr/local/bin/ultra-server`
- **Anchor string:** `requires_pro` (the reason token emitted for denied capabilities)
- **Decision function:** *(filled in after Ghidra xref)*
- **Change:** *(exact bytes / branch flip, filled in after decompile)*
- **Applied by:** `ungate.sh`

## Re-applying on an upstream update

1. Pull the new base image: `ghcr.io/sudo-rahman/ultra-explorer:<newtag>`.
2. Run `ungate.sh` against its `/usr/local/bin/ultra-server`.
3. If the anchor string or branch moved, re-run the Ghidra xref on
   `requires_pro` to find the new decision function and update `ungate.sh`.
4. Verify: log in → `GET /api/product-access` must show `plan:"pro"` and all
   capabilities `"status":"allowed"`.

## Verification checklist (per version)

- [ ] `/api/product-access` → `plan:"pro"`, search/spaceAnalysis/synchronization all `allowed`
- [ ] A real search runs (not `product_access_required`)
- [ ] Space analysis runs
- [ ] Sync is available in UI
