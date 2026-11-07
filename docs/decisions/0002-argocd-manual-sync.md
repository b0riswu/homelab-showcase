# 0002 — ArgoCD with app-of-apps and manual sync only

- Status: accepted (2026-08-02), structure revised 2026-10-31 and 2026-11-06

## Context

The trigger was a provenance question: given a database backup from a given night,
which manifest version was actually running? `git log --before=<backup time>` is
the obvious answer and it is wrong whenever the deployed state and the git HEAD
diverge. That had already happened once: a manifest was committed while an older
file from a different path was what had been applied, and the two were out of sync
for a while.

Alternatives were considered and rejected:

| Option | Cost | Why not |
|---|---|---|
| Record image digests with each backup | very low | answers "which image", not "which cluster manifest state" |
| Tag the repository after each deploy | low | depends on human discipline; fails the same way as the original problem |
| Single recursive Application over the whole tree | low | one bad file blocks every service, including the password manager |

## Decision

- **App-of-apps with one Application per service.** A root Application
  (`argocd-apps`) points at `kubernetes/argocd-apps/`; each Git-sourced child
  points at one service directory, and chart-based Applications name one chart (an
  OCI registry or a Helm repository). The root is applied by hand once at
  bootstrap and lives *outside* the directory it manages, so it cannot sync away
  its own source.
- **Manual sync everywhere.** No `automated`, no `selfHeal`, no `prune` on any
  Application. Adopting a service is a four-step ritual: create the Application,
  diff until empty, sync once as a no-op, and confirm pod `AGE` did not reset.
- **No `resources-finalizer` on the root.** Deleting it must leave child
  Applications and workloads in place. Retiring an Application stays a deliberate
  `kubectl delete`.
- **Namespaces are bootstrapped by hand**, never owned by an Application: their
  labels gate workload admission and secret sync, and several Applications share
  one namespace.
- **No prune for data-bearing services, indefinitely.** Proxmox CSI volumes are
  single-copy with `reclaimPolicy: Retain`; a mistaken prune is a restore event.
  `prune` is only even discussable for a service with a passing restore drill.
- **Adoption is measured, not assumed.** Eight services, 49 resources, zero pod
  restarts; every diff contained only the `tracking-id` annotation. `status.resources`
  must be non-empty — a `directory.include` glob that matches zero files reports
  `Synced/Healthy` and looks exactly like success.

## Consequences

- **"What was running at 03:00?"** is now answered by `argocd app history` plus
  `git show <revision>:<file>`, including the case where a commit landed at 01:00
  but was synced at 03:00.
- **Drift is visible but not corrected.** A manual `kubectl apply` shows as
  `OutOfSync` until someone syncs. During an incident, an emergency fix is not
  reverted under your hands — which is the intended trade.
- **ArgoCD only guarantees what is in Git.** In the 2026-11-06 incident, 41
  generated alert rule groups and the default dashboards were garbage-collected
  after their owning ServiceAccount was deleted as an "orphan". ArgoCD reported all
  Applications `Synced/Healthy` the whole time: the objects were never in Git, so
  there was no diff to see. The catch was an out-of-band dead-man check, not the
  GitOps tool.
- **Sync is a human step in the deploy path.** That is a cost, paid deliberately
  for reversibility; it also means a forgotten sync is a silent drift, so the
  deployment habit includes diffing before syncing.
- **Scaling this to a team would need more than policy.** Manual sync relies on one
  operator knowing the ritual; at team scale it would need either automation with
  a restore-gated `prune`, or an explicit approval workflow.

## Excerpt

`examples/argocd/root-app.yaml` and `examples/argocd/application-vault-warden.yaml`
are sanitized copies, including the comments that explain the missing sync policy.
