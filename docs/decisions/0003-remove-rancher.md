# 0003 — Remove Rancher (and with it the only cluster dashboard)

- Status: accepted, executed 2026-11-02
- Replaces: Rancher-managed UI and Fleet-based delivery

## Context

Rancher 2.14 — the newest release available — supported Kubernetes only up to
1.35, and no Rancher release supported the 1.37 the cluster was moving to. That
ceiling was the hard blocker; nine days of usage data confirmed there was nothing
worth keeping.

Rancher had been installed early, when the cluster was still RKE2-shaped. By late
2026 the cluster was Talos-managed, delivered by ArgoCD, and Rancher had become an
idle second control plane. Nine days of instrumentation before the decision:

| Signal | Value |
|---|---|
| Rancher UI logins | 2 |
| Changes made through the UI | 0 |
| Fleet GitRepos | 0 |
| CAPI-managed clusters | 0 |
| Memory held | ~2.8 GiB |
| CRDs installed | 94 |
| Share of API-server watch traffic | 24.5% |
| Kubernetes support ceiling | 1.35 (Rancher 2.14); nothing supported 1.37 |

What Rancher did provide — a UI, a Fleet delivery path, and a place to look at
resources — was either unused or already covered: ArgoCD for sync state, Grafana
for metrics and logs, and `k9s`/`kubectl` for resources. A second dashboard was
also a second credential surface.

## Decision

Remove Rancher, Fleet, CAPI and the Turtle CRDs. **Do not replace them with another
in-cluster dashboard.** Day-to-day views are: `k9s` and `kubectl` with a personal
kubeconfig for resources, the ArgoCD UI for sync state, Grafana for metrics and
logs. Take an etcd snapshot before starting.

Headlamp was trialled the same day and removed (#113 deployed, #120 removed): its
ServiceAccount could read Secrets cluster-wide with only the ingress access gate in
front of it. During the trial a proxy misconfiguration made it briefly reachable
without authentication; the exposure was limited to the operator's own host, and it
was enough to end the trial.

Removal order matters, and is recorded for anyone repeating it:

1. Delete the Rancher/CAPI admission webhooks first. The secrets webhook
   intercepts Secrets cluster-wide with `failurePolicy: Fail`; removing the
   controller before the webhook wedges secret operations.
2. `helm uninstall rancher` **before** deleting CRDs — a running Rancher
   reinstalls its own system chart.
3. Remove `turtles`, then `fleet-agent-local` (its `--wait` hangs on a `default`
   ServiceAccount that Kubernetes recreates), then `fleet` and `fleet-crd`.
4. Run the official `rancher-cleanup`, then delete what it misses:
   `cattle-local-user-passwords`, `cattle-ui-plugin-system`.

## Consequences

- **Freed**: ~2.8 GiB of memory, 94 CRDs, 24.5% of API-server watch traffic, and
  the version ceiling. The 1.36 upgrade went through afterwards.
- **Lost**: a UI for browsing arbitrary resources, and any future multi-cluster
  story. Neither was in use; both are recoverable by installing something else if
  the requirement ever appears.
- **Fewer places to authenticate.** One less dashboard means one less long-lived
  admin session and one less path that must be fronted by an access proxy.
- **The lesson generalised**: removing a component needs a measurement window and
  an ordering plan, not just a `helm uninstall`. The same discipline later showed
  up in alert-rule changes — measure first, then delete.
