# 0001 — OpenTofu state, encrypted client-side, stored in Backblaze B2

- Status: accepted (2026-11-07)
- Supersedes: plaintext local state files on the operator's laptop

## Context

On 2026-11-07 the only copy of this homelab's Terraform state turned out to be a
set of plaintext files on one Mac, with no backup — and that state is not resource
bookkeeping. The `talos` module holds `talos_machine_secrets.this` — etcd,
Kubernetes, aggregator and OS CA keys, the service-account signing key, the
secretbox encryption key, bootstrap and trustd tokens — plus the full text of
`kubeconfig` and `talosconfig` in two `local_sensitive_file` resources. Anyone with
that state has cluster-admin and can decrypt etcd. The `cloudflare` state holds the
tunnel secret and OIDC client secrets; the `infra` state describes the entire PVE
layout.

There was no Time Machine and no other backup. Terraform itself has no state
encryption (hashicorp/terraform#9556), so "put it in a bucket" would have moved
the problem rather than solved it.

Constraints found while evaluating:

- B2 rejects the conditional write OpenTofu's S3 lockfile relies on
  (`If-None-Match` → 501, tested 2026-11-07). There is no backend lock.
- A CI runner has no fixed source address, so a CI credential cannot be
  IP-filtered and must not be able to write.
- Provider credentials should not live on the workstation.

## Decision

1. **OpenTofu 1.13.9**, `required_version >= 1.13.0`, three modules
   (`infra`, `talos`, `cloudflare`), one state object per module in one private B2
   bucket, with B2's 90-day file versioning.
2. **Client-side encryption**: `pbkdf2` key provider → `aes_gcm`, one passphrase
   per module, applied to both `state` and `plan` with `enforced = true`. A
   plaintext state placed in the bucket is rejected, not trusted.
3. **No backend lock, so lock in the wrapper.** A single `terraform/tf` entry point
   takes a per-module `lockf(1)` lock; a second run exits 75 and names the lock
   file. It protects every worktree on one machine, and nothing else.
4. **Apply only from merged code.** `apply`/`destroy` are refused unless the run is
   in the main checkout, on `main`, at `origin/main`, with no uncommitted changes
   under `terraform/`. A per-module freeze file blocks apply during multi-step
   rotations, with a one-line reason printed.
5. **CI plans, never applies.** Workflow credentials are read-only counterparts
   (B2 key limited to one prefix; Cloudflare token with Read permissions), and the
   plan is posted to the job summary. The write token stays IP-filtered and is used
   from the main checkout after merge.
6. **Provider tokens come from OpenBao at runtime**, for commands that call the
   provider only: `init`, `fmt`, `validate`, `output` and `state` do not log in.

## Consequences

- **Losing one module's passphrase loses that module's state.** There is no escrow
  and no recovery path; B2 versioning only survives overwrites. Recovering means
  importing every resource again, and for `talos`, regenerating machine config —
  i.e. a full identity rotation.
- **The workflow now has a human dependency**: provider-backed commands need the
  cluster up, OpenBao unsealed, and an interactive second factor. That is
  deliberate — no standing Proxmox or Cloudflare credential sits on the
  workstation — and it has a written DR path (a one-day PVE token minted as
  root, removed immediately after).
- **The lock is single-machine.** Two operators, or the same operator on two
  machines, can still race. Accepted for a one-person lab; it would not be
  acceptable with a second operator.
- **CI cannot fix a broken apply.** The trade is explicit: the credentialed path is
  narrow and manual, and the automated path is read-only.
- The state is now backed up and versioned, but the `generated/` kubeconfig and
  talosconfig files are still outside every backup path — a known, documented gap.

## Excerpt

`examples/opentofu/versions.tf` shows the backend and encryption blocks;
`examples/opentofu/tf-wrapper.sh` shows the apply guard, freeze and lock.
