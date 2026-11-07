# Architecture — eight views of one small platform

The [README](../README.md) shows the system on one page. This document takes it
apart: hardware and failure domains, the network, the Kubernetes layers, how a
change travels from a pull request to a running pod, where secrets come from,
what watches the system when it is broken, how data is backed up and restored,
and the order in which the platform was upgraded.

Addresses and hostnames here are placeholders on the same scheme as the rest of
the repository: `10.0.10.0/24` is the lab LAN, `10.0.50.0/24` the client network,
`10.200.0.0/16` pods and `10.201.0.0/16` services. Versions, counts and
timestamps are real.

## 1. Physical and hardware view

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TB
  ont["ISP ONT"]

  subgraph power["Power — one UPS is a shared dependency"]
    ups["UPS · NUT primary on PVE<br/>NAS runs a netclient as a second opinion"]
  end

  subgraph site["Single site, single room, one L2 switch"]
    rtr["MikroTik RB5009UG+S+<br/>router · firewall · DHCP · syslog · IPFIX"]
    sw["L2 switch"]

    subgraph pve["Failure domain 1 — the whole lab"]
      host["Proxmox VE 9.2 · i7-13700 16C/24T<br/>96 GB non-ECC (4 DIMMs, 2 vendors, 2 capacities)"]
      nvme0[("NVMe 1 TB — pve-root + local-lvm<br/>every database volume is a single disk here")]
      nvme1[("NVMe 2 TB — second controller<br/>kdump target, not enabled")]
      nic["bond0 · 2 × 1 GbE"]
      guests["5 Talos VMs · HAProxy LXC · cloudflared LXC<br/>Windows VM on demand, GPU passthrough"]
    end

    subgraph nas["Failure domain 2 — storage and the out-of-band watch"]
      nashw["ZFS NAS · Debian 13<br/>Celeron N5095 · 16 GB"]
      ssd[("256 GB SSD · ext4 boot")]
      pool[("4 × 3.6 TB HDD · raidz2<br/>~7.2 TB usable, 2 disk failures tolerated")]
    end

    gpu["GTX 1660 SUPER<br/>vfio-pci, one VM at a time"]
  end

  ont --> rtr
  rtr --- sw
  sw --- pve
  sw --- nas
  pve --- gpu
  ups -. "USB → upsd" .-> host
  ups -. "netclient" .-> nashw
  host --- nvme0
  host --- nvme1
  host --- nic
  host --- guests
  nashw --- ssd
  nashw --- pool
```

This is a two-machine system, not a cluster with a spare: the Proxmox host holds
every VM, the API VIP, the tunnel and the monitoring stack, so a host freeze takes
the entire lab with it — which is exactly what happened for ~29 hours on
2026-09-05. The NAS is a separate failure domain, but only for storage and the
external poller; it shares the same room, switch, internet path and UPS. The two
NVMe drives sit behind different controllers so a kdump target exists, but kdump
is not enabled, and the 1 TB drive carries both the root filesystem and the LVM-thin
pool that backs every database volume — one disk, one copy.

## 2. Network view

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TB
  inet((Internet))
  client["Client devices<br/>10.0.50.0/24 · DHCP .100–.199"]

  subgraph edge["Cloudflare edge"]
    cf["Proxied hostnames · Cloudflare Access<br/>*.example.net"]
    tun["cloudflared LXC<br/>outbound-only tunnel"]
  end
  inet --> cf
  cf --> tun

  subgraph rtr["RB5009 — the policy lives here"]
    fw["Forward chain · default drop<br/>client → lab: 8006, 22, 6443, 443, game port, ICMP<br/>lab → client: drop · lab → internet: accept"]
  end
  client --> fw
  inet -->|"direct path — hostnames that skip the proxy"| fw
  cf -->|"proxied path — Cloudflare, then Access where gated"| fw

  subgraph lab["br-lab · 10.0.10.0/24 · static leases only"]
    pve["PVE<br/>10.0.10.10"]
    nas["NAS<br/>10.0.10.11"]
    hap["HAProxy LXC<br/>10.0.10.20 · API VIP :6443"]
    nodes["3 control planes 10.0.10.21–23<br/>2 workers 10.0.10.30–31"]
    vip["MetalLB L2 pool<br/>10.0.10.200–210 (6 in use)"]
  end
  fw --> pve
  fw --> hap
  fw --> nas
  tun --> pve
  hap --> nodes
  nodes --- vip

  subgraph ingress["Ingress chain"]
    direction LR
    tr["Traefik 3.7.17<br/>two entrypoints: direct and cloudflare"]
    gw["Gateway API HTTPRoutes<br/>listener = entrypoint"]
    svc["Services<br/>10.201.0.0/16"]
    pods["Pods<br/>10.200.0.0/16"]
  end
  fw -->|"direct path"| tr
  fw -->|"proxied path"| tr
  vip -. "announced over L2 by a worker" .-> tr
  tr --> gw --> svc --> pods
```

There are two L2 segments and no 802.1Q VLANs: with a single host and one switch,
the segmentation that matters is the router's forward chain, which drops by
default and allows the ports the client network uses — including PVE UI, SSH, the
Kubernetes API, HTTPS to Traefik, RDP/Moonlight, the game port and ICMP — while the
lab may not initiate into the client network. Ingress has two paths on purpose.
Proxied hosts arrive on their own origin path through Cloudflare — the edge
terminates TLS, applies Access where the host is gated, and forwards to the
origin — while hostnames that would hit Cloudflare's request-size limit are served
directly from the origin. The PVE UI cannot sit behind Traefik, so it is reached
through the outbound-only tunnel. The proxied path does not authenticate Cloudflare
at the origin yet, and the direct path is public by construction. Inside the
cluster MetalLB announces the VIP pool over L2 and Traefik's Gateway listeners —
named after the entrypoints — fan out to HTTPRoutes.

## 3. Kubernetes platform layers

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TB
  subgraph infra["Node layer — Talos Linux v1.14.5, no SSH"]
    cp["3 × control plane<br/>2 vCPU / 6 GB · etcd 3.7.3<br/>control-plane taint kept"]
    wk["workers<br/>6 vCPU / 16 GB and 8 vCPU / 32 GB"]
  end

  subgraph plumbing["Cluster plumbing — kube-system"]
    cni["Flannel · pods 10.200.0.0/16<br/>NetworkPolicy accepted, not enforced"]
    kp["kube-proxy · services 10.201.0.0/16"]
    dns["CoreDNS"]
    csi["Proxmox CSI (Retain) + NFS CSI"]
  end

  subgraph platform["Platform namespaces"]
    argo["argocd<br/>ArgoCD 3.6 · 24 Applications"]
    ing["metallb-system · traefik · networking<br/>MetalLB 0.16.1 · Traefik 3.7.17 · external-dns"]
    sec["openbao · external-secrets · cert-manager<br/>OpenBao 2.6.3 · ESO 2.14.0 · homelab-ca"]
    mon["monitoring<br/>VMSingle · VLSingle · vmalert · Alertmanager · Grafana"]
    ops["etcd-backup · descheduler · csi-proxmox"]
  end

  subgraph apps["Workload namespaces"]
    media["media<br/>Immich + PostgreSQL"]
    pydio["pydio<br/>Cells + MySQL"]
    tools["tools<br/>Vaultwarden · hermes-agent · it-tools · browserless · router-backup"]
    misc["searxng · games<br/>SearXNG · Palworld · bmc2"]
  end

  cp --> cni
  wk --> cni
  cni --> kp
  cni --> dns
  wk --> csi
  plumbing --> platform
  platform --> apps
```

The layers are stacked so that each one can be reasoned about — and rebuilt — on
its own: Talos nodes with no SSH and a pinned Kubernetes version, then the CNI,
kube-proxy and CSI drivers that make pods and volumes work, then the platform
services in their own namespaces, then workloads that assume none of the platform
internals. Flannel is the deliberate weak point: the API accepts NetworkPolicy
objects and the CNI enforces nothing, so namespace isolation is documented intent
rather than a control. Database volumes are Proxmox CSI disks with `reclaimPolicy: Retain` and
bulk files are NFS, which is why a pod move is a re-attach and not a failover.

## 4. GitOps and IaC change flow

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  pr["Change on a branch<br/>terraform/ or kubernetes/"] --> ci["GitHub Actions — plan only<br/>tofu fmt · init · validate · plan<br/>read-only credentials, never apply"]
  ci --> merge["Review and merge to main"]

  merge --> argo["ArgoCD root Application<br/>watches kubernetes/argocd-apps"]
  argo --> manual["Manual sync per Application<br/>no automated · no selfHeal · no prune"]
  manual --> live["Running cluster"]

  merge --> apply["terraform/tf — guarded local apply<br/>main checkout on main · HEAD == origin/main<br/>clean terraform/ tree"]
  apply --> lock["lockf serialises runs<br/>freeze flag blocks apply during a rotation"]
  lock --> tofu["OpenTofu 1.13.9<br/>provider token fetched from OpenBao<br/>interactive, with a second factor"]
  tofu --> pve["Proxmox VE: VMs, LXCs, images"]
  tofu --> state[("Encrypted state in B2<br/>infra / talos / cloudflare<br/>one passphrase per module · 90-day versions")]
  tofu --> cf["Cloudflare: Access, tunnel, DNS"]
```

Two tracks share one merge: Kubernetes manifests go to ArgoCD, infrastructure goes
through OpenTofu, and neither applies itself. CI runs `plan` with credentials that
can read and nothing else, while `apply` happens only from the main checkout on
`main` at `origin/main` with a clean `terraform/` tree, through one wrapper that
serialises runs with a lock and can freeze a module mid-rotation. ArgoCD is manual
on purpose — `OutOfSync` after a hand edit is the signal that Git and the cluster
disagree — and `prune` stays off for anything holding data. State lives in B2,
encrypted client-side with one passphrase per module; provider tokens live in
OpenBao, and no long-lived Proxmox or Cloudflare credential sits on the workstation.

## 5. Secrets flow

```mermaid
sequenceDiagram
  participant Git as Git
  participant SS as sealed-secrets
  participant OB as OpenBao
  participant ESO as External Secrets
  participant Pod as Workload pod

  Note over Git,OB: Bootstrap — the circular dependency, tamed
  Git->>SS: one bootstrap secret, sealed to the cluster key
  SS->>OB: rendered as a plain Secret
  OB->>OB: starts without a human in the loop

  Note over ESO,Pod: Steady state — the app holds no static credential
  ESO->>OB: Kubernetes auth, 600 s projected SA token
  OB-->>ESO: policy-scoped read of the app's KV path
  ESO->>ESO: render Secret, deletionPolicy Retain
  ESO-->>Pod: env or volume mount

  Note over OB: Rotation — keys and identity, not every password
  OB->>OB: hourly Raft snapshot → NFS → restic → B2
```

Machine secrets live in OpenBao and reach pods only through External Secrets, with
a per-namespace `SecretStore` and a Kubernetes-auth role bound to one ServiceAccount,
each role restricted to that application's KV path with a read-only policy — so the
application path carries no static bootstrap credential. Sealed-secrets survives as
the bootstrap mechanism, plus a short exception list (the alert bot, ArgoCD's repo
credential); its own rotation was switched off at eight keys, which are backed up
GPG-encrypted to B2 because losing one makes that era's SealedSecrets
undecryptable. Audit goes to stdout, and Raft snapshots are taken hourly so the
nightly restic run can carry them off-site; what is *not* automatic is database
password rotation, an accepted trade recorded as a known gap rather than hidden.

## 6. Observability and alerting paths

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TB
  subgraph sources["What is measured"]
    metrics["node-exporter · KSM · kubelet/cAdvisor<br/>etcd, scheduler, controller-manager, kube-proxy<br/>pve-exporter · nut-exporter · mktxp<br/>NAS node, SMART and ZFS exporters"]
    logs["pod stdout/stderr<br/>Talos service + kernel logs (Vector relay .204)<br/>PVE, NAS, HAProxy, cloudflared journals<br/>router syslog and IPFIX"]
  end

  subgraph inc["In-cluster — shares the cluster's fate"]
    vm["VMAgent → VMSingle<br/>30 days · 71 targets"]
    vl["VLAgent → VLSingle<br/>30 days"]
    rule["vmalert<br/>61 rule groups"]
    am["Alertmanager"]
    graf["Grafana<br/>on the proxied path"]
  end

  subgraph oob["Out of band — does not"]
    watch["NAS homelab-watch<br/>every 60 s: PVE ping + API, k8s API,<br/>OpenBao, UPS, cloudflared /ready"]
    hc["healthchecks.io<br/>dead-man switch"]
  end

  tg["Telegram<br/>one operator"]

  metrics --> vm
  logs --> vl
  vm --> rule --> am --> tg
  vm --> graf
  vl --> graf
  am -. "Watchdog ping ~every 2 min" .-> hc
  watch --> tg
  watch -. "self-liveness ping" .-> hc
```

Metrics and logs are collected inside the cluster because that is where the detail
is, but nothing inside the cluster can report that the cluster is gone, so the
checks that matter most run on the NAS: every 60 seconds it probes the PVE host and
its API, the Kubernetes API, OpenBao and the UPS, and it pings healthchecks.io so
its own death is noticed too. In-cluster, vmalert evaluates 61 rule groups into
Alertmanager and Telegram, and a Watchdog alert exercises the whole path to
healthchecks.io about every two minutes. Log sources are deliberately broad — pod
output, Talos service and kernel logs through a per-node Vector port, host journals,
router syslog and IPFIX — because the 2026-09-05 freeze left no usable log at all
when journald shared a disk with the failing controller.

## 7. Backup and restore

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  subgraph l3["Layer 3 — application-consistent dumps (CronJobs)"]
    dumps["02:00 Immich pg_dump · 02:15 Vaultwarden sqlite .backup<br/>02:30 Pydio mysqldump · 02:45 Palworld<br/>hourly OpenBao Raft snapshot · every 6 h etcd<br/>02:00 router backup, 02:20 pull"]
  end

  nas[("NAS per-service datasets<br/>tank/immich · tank/pydio · tank/openbao-snapshots …")]

  subgraph l1["Layer 1 — ZFS snapshots, on the NAS"]
    snap["24 hourly · 30 daily · 12 monthly<br/>per dataset, pruned by count"]
  end

  subgraph l2["Layer 2 — restic to B2"]
    restic["daily 03:00<br/>30 daily · 12 monthly<br/>weekly 5% read-data verify<br/>shrink guard at 80%"]
  end

  b2[("Backblaze B2<br/>content-addressed, encrypted")]

  dumps --> nas
  nas --> snap
  nas --> restic --> b2
  snap -->|"seconds — roll back a file or dataset"| r1["ZFS rollback"]
  b2 -->|"hours — site or pool loss"| r2["restic restore"]
  dumps -->|"pg_restore · sqlite3 · etcdutl"| r3["restore into a live database"]

```

Three layers exist because they fail differently: ZFS snapshots are fast and local
but die with the pool, restic is off-site and survives site loss but is slow to
restore, and the dumps capture database state that a block-level copy cannot make
consistent. Retention is 24 hourly / 30 daily / 12 monthly locally and 30 daily /
12 monthly off-site, with a weekly read-data check and a repo-shrink guard so a
failed mount cannot age good data out. Restores are treated as drills: Vaultwarden
and Immich have timed, verified restores into the live services; OpenBao's drill
restored a snapshot from an offline key into a disposable kind cluster, not into
the production cluster, so a production OpenBao restore is documented but not
drilled. etcd has been restored to a data directory but
not rebuilt into a cluster, and Pydio is named as never drilled.
`backup-monitor` checks `lastSuccessfulTime` daily and alerts to Telegram, because a
CronJob that never fired cannot report its own failure.

## 8. Upgrade path

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  L0["L0 — pins and component bumps<br/>cert-manager 1.21.3 · ESO 2.14 · Traefik 3.7.17<br/>MetalLB 0.16.1 · Gateway API CRDs 1.6.3"]
  L1["L1 — Talos v1.12.6 → v1.12.12<br/>containerd 2.1.6 → 2.2.7<br/>Kubernetes 1.35.0 → 1.35.10"]
  L2["L2 — Talos v1.12.12 → v1.13.12<br/>Kubernetes stays 1.35.10"]
  L3["L3 — Kubernetes 1.35.10 → 1.36.6<br/>descheduler 0.36.0 and ArgoCD 3.5.7 first"]
  L4["L4 — Talos v1.13.12 → v1.14.5<br/>containerd 2.3.7 · etcd 3.6.14 → 3.7.3"]
  L5["L5 — next: Kubernetes 1.37<br/>blocked on cert-manager 1.22 and KSM 2.21"]

  L0 --> L1 --> L2 --> L3 --> L4 --> L5
```

Each OS hop — L1, L2 and L4 — runs the same gates:

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 320}}}%%
flowchart TD
  snap["etcd snapshot<br/>the only rollback path"] --> dry["validate first<br/>talosctl validate · upgrade-k8s --dry-run"]
  dry --> cp["control planes first, one at a time<br/>non-leaders before the etcd leader"]
  cp --> chk["etcd status healthy · all nodes Ready<br/>extensions still present"]
  chk --> wk["workers: drain with a 60 s cap,<br/>reboot clears stuck mounts"]
  wk --> post["post-upgrade: ArgoCD Synced/Healthy,<br/>HTTP 200s, next backup run"]
```

The upgrade was planned as layers rather than one leap: pin and bump components
first (L0), then move the OS without moving Kubernetes (L1, L2), then move
Kubernetes on a stable OS (L3), then take the OS to 1.14 (L4) — each stage followed
by the same post-upgrade checks. On an OS hop the control planes go first and one
at a time because Talos's lifecycle upgrade does not guard etcd quorum, and the
etcd leader goes last; workers go afterwards with a short drain because a stuck
drain is an outage, not patience. The Kubernetes hop took 6 min 18 s with no user-facing
outage, and L4 moved etcd's on-disk version to 3.7.0, which makes "roll back to
1.13" a snapshot restore rather than a binary rollback.
