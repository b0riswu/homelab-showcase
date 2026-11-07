# Screenshots

Captured from the live system on 2026-11-08. Metric and log dashboards show the
last 36 hours; the backup summary shows the last 30 days. Before capture,
addresses and identifiers on the page were replaced in the browser with the same
placeholders the rest of this repository uses; disk serial numbers were cropped
out. Nothing else was edited. Captions describe only what is on screen plus facts
documented elsewhere in this repository.

## Cluster overview

![Kubernetes global view: 5 nodes, 20 namespaces, 90 running pods, CPU and memory usage](images/grafana-cluster-global.png)

Five Talos nodes, 20 namespaces, 90 running pods, with real usage, requests and
limits side by side for CPU and memory.

## GitOps state

![ArgoCD summary: 24 applications, all Synced and Healthy, 1 cluster, 14 namespaces](images/argocd-summary.png)

![ArgoCD application list with sources and destinations](images/argocd-list.png)

24 Applications (23 services plus the app-of-apps root), all `Synced` and
`Healthy`. Auto-sync is intentionally off; see
[ADR 0002](decisions/0002-argocd-manual-sync.md).

## Storage

![ZFS overview: pool ONLINE, 0 errors, 7 TiB free, 100% ARC hit rate](images/grafana-zfs.png)

The NAS pool: `ONLINE`, zero ZFS errors, 7 TiB free, a 7.6 GiB ARC serving all
reads from RAM, and per-dataset read/write load.

![SMART: 7 devices across 2 hosts, 0 unhealthy, disk temperatures](images/grafana-smart.png)

Seven disks on two hosts, zero unhealthy. SMART attributes feed the disk alert
rules, including the cable-error rule that needed a 48-hour identity-stability
window to stop a false positive.

## Backups

![Restic backups over 30 days: 30 starts, 30 completions, 30 prunes, 0 run failures](images/grafana-restic-backups.png)

Thirty nightly restic runs in 30 days: thirty completions, thirty prunes, zero
failures. Restores are proved separately by timed drills (see the README).

## Alerting

![vmalert: 224 alerting rules, 94 recording rules, 0 evaluation errors](images/grafana-vmalert.png)

224 alerting rules and 94 recording rules across 61 groups, zero evaluation
errors.

![Alertmanager: active alerts and receive rate](images/grafana-alertmanager.png)

Alertmanager's view of the same window. Alerts are delivered to Telegram; the
in-cluster path is backed by an out-of-band NAS poller and a healthchecks.io
dead-man switch.

Message templates used by the out-of-band checks and the backup job (templates,
not a screenshot):

```
❌ <check> failing for <N> min<detail> (seen from <HOST>)
⏰ <check> still failing — <N> min<detail> (seen from <HOST>)
✅ <check> recovered<detail> (seen from <HOST>)
⚠️ Restic repo on <HOST> shrank to <PCT>% of its previous size (<prev> → <now>).
✅ Weekly backup summary — <HOST> · Snapshots: <N> · Integrity check (5% of data): passed
```

## Logs

![Talos node logs over 36 hours: 385K service lines and 15K kernel lines, log rate by node and service](images/grafana-talos-logs.png)

Talos cannot ship logs off the node by itself, so every node pushes service and
kernel logs to an in-cluster Vector relay, broken down here by node and by Talos
service.
