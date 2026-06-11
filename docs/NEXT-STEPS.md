# Next steps — PR consolidation + deploy

State as of umbrella commit `c4a2be7` on `feat/k8s-minikube`. Everything below
the line "MERGED" is done and pushed; everything under "PENDING" is not.

---

## MERGED & build-verified (NOT deployed yet)

All open PRs consolidated into `feat/k8s-minikube`, synthesized onto our live
tree (not blind pointer-swaps — #27's submodule pointers were orphan lineages
missing today's deployed fixes).

| Area | Commit | Content | Verified |
|---|---|---|---|
| chat-orch | `869b290` (dev) | Telegram per-chat RL + CSAT stars + 4096 msg limit + X-Internal-Key sender | `cargo check` ✅ |
| Tenant | `b224633` (dev) | CORS allow-list (C1) + TRUST_PROXY_HEADERS (H1) + 429 secs (#13) | `go build` ✅ |
| User-Auth | `0d845ee` (feat/tenant-exchange-on-verify) | OTP 429 concrete seconds (#2) | `go build` ✅ |
| FrontEnd | `c4cf74e` (feat/k8s-minikube) | login 429 message (#17) | `npm build` ✅ |
| Compliance | in-tree | X-Internal-Key required on writes (M1) | syntax ✅ |
| agent-runtime | unchanged `4cb968` | #27 only adds tests — no runtime change | n/a |
| k8s overlays | in-tree | TRUST_PROXY_HEADERS=true + CORS on tenant, INTERNAL_API_KEY on compliance | both render ✅ |

Three GKE deploy-breakers fixed inline: (1) analytics-freeze → chat-orch now
sends X-Internal-Key; (2) global login lockout → tenant TRUST_PROXY_HEADERS=true;
(3) M1 inert → compliance gets INTERNAL_API_KEY.

---

## PENDING

### 1. Deploy (the route) — awaiting go-ahead
```bash
TAG=c4a2be7
make -C k8s gke-build  TAG=$TAG               # build + push 10 images (~8-10 min, chat-orch+frontend are slow)
make -C k8s gke-deploy ENV=dev  TAG=$TAG       # dev first
#   → verify dev (section 2) before touching prod
make -C k8s gke-deploy ENV=prod TAG=$TAG
```
Rollback if anything misbehaves: `make -C k8s gke-deploy ENV=<env> TAG=580ed36`
(the last known-good tag).

### 2. Verify after deploy (per env, dev first)
- **Login 429 message**: hammer `/auth/login` with a bad password 6×, last shows
  429 with "Espera N segundos" (not "invalid credentials") in the UI.
- **Analytics still counts** (the breaker that mattered most): send a chat turn,
  confirm `/stats/kpis` total_conversations increments. If it freezes →
  chat-orch isn't sending the key → check `INTERNAL_API_KEY` matches on
  chat-orch + compliance.
- **Login NOT globally locked**: two different machines/IPs can both log in
  (proves TRUST_PROXY_HEADERS is keying per-user, not per-nginx-pod).
- **Telegram CSAT**: finish a Telegram booking, confirm the star-rating inline
  keyboard appears and a tap records a CSAT.
- **Telegram message cap**: paste a >4096-char message, expect a graceful reject.
- **No regressions**: operator panel still survives reload; chat replies arrive
  over SSE; OTP email still delivers.
- `make -C k8s netcheck NS=unagent-<env>` still 6/6.

### 3. Close out the PRs
Once deployed & verified, the 4 source PRs are consumed by this branch:
- dev-runner #27, Tenant #13, FrontEnd #17, User-Auth #2 → comment "consolidated
  into feat/k8s-minikube @ c4a2be7" and close (or merge to `dev` if you want the
  dev lineage to carry them too).

### 4. Reconcile the orphan lineages (tech debt, not blocking)
#27's FrontEnd (`b11024c`) and agent-runtime (`1105333`) are on rewritten
histories with no common ancestor to our deployed commits. We took their *value*
as deltas; their unique extras not yet pulled:
- agent-runtime: the 15 TS unit tests (no runtime impact — re-apply when convenient).
- FrontEnd: an "Agent Console isSending guard" (minor; prevents double-send). Low priority.
Long-term: stop force-pushing these repos so histories stay mergeable.

### 5. Still-open from before this session
- Merge `feat/k8s-minikube` → `main` (the whole GKE migration is still on a branch).
- Rotate `INTERNAL_API_KEY` off the `dev-internal-key` default (works, but weak).
- Optional: SendGrid domain auth for `unagent.site` so OTP/confirmation emails
  stop being slow/spam-foldered via the gmail.com sender.

---

## One judgment call before deploy
This makes Daniel's **Telegram CSAT** and the **4096-char message cap** live
behavior. Both are good; just confirm they belong in the demo before prod.
