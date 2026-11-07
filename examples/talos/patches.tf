# Excerpt from terraform/talos/patches.tf — machine-configuration patches, one
# list per node, in the Talos 1.14 document form (`UnattendedInstallConfig`,
# `KubeNodeConfig`, ...). Sanitized: cluster CIDRs are placeholders, values that
# were interpolated remain HCL.
#
# These only work together with the 1.14 contract (`talos_version`): the base
# config rendered for an older contract still carries `.machine.install`,
# `.cluster.network`, `.machine.nodeLabels`, etc., and a base document plus its
# replacement document is rejected by the node.
locals {
  # Labels that drive CSI topology. Shared by control planes and workers; this is
  # the only part of the label set they are allowed to share.
  csi_node_labels = {
    "topology.kubernetes.io/region" = "homelab"
    "topology.kubernetes.io/zone"   = "pve-1"
  }

  # Control-plane labels/taint are part of the generated KubeNodeConfig, but the
  # document contents are authoritative. Stating them here keeps that independent
  # of merge behaviour.
  controlplane_node_labels = merge(local.csi_node_labels, {
    "node-role.kubernetes.io/control-plane"                   = ""
    "node.kubernetes.io/exclude-from-external-load-balancers" = ""
  })
  controlplane_node_taints = {
    "node-role.kubernetes.io/control-plane" = "NoSchedule"
  }

  # No `node.kubernetes.io/exclude-from-external-load-balancers` here: the 1.14
  # renderer puts it on control planes only (the stock worker KubeNodeConfig has
  # no labels at all), and MetalLB excludes a node whenever the label is
  # *present*, whatever its value. Adding it to workers made every L2 VIP
  # unannounceable (2026-11-04 outage).
  worker_node_labels = local.csi_node_labels

  controlplane_patches = {
    for i, _ in var.controlplane_ips :
    "k8s-control-${i + 1}" => concat(
      [
        # Service logs carry extraTags, so one destination can identify the node.
        yamlencode({
          machine = {
            logging = {
              destinations = [
                {
                  endpoint  = local.service_logs_endpoint
                  format    = "json_lines"
                  extraTags = { node = "k8s-control-${i + 1}" }
                }
              ]
            }
          }
          cluster = {
            etcd = {
              extraArgs = {
                # Talos binds localhost by default; scrape control-plane metrics.
                # Cost: this is open to the whole lab LAN — the 1.14 ingress
                # firewall blocks by default but allows all lab-LAN ports — an
                # accepted risk recorded in the monitoring notes.
                "listen-metrics-urls" = "http://0.0.0.0:2381"
              }
            }
          }
        }),
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "KubeNodeConfig"
          labels     = local.controlplane_node_labels
          annotations = {
            "proxmox.sinextra.dev/instance-id" = tostring(var.node_vmids["k8s-control-${i + 1}"])
          }
          taints = local.controlplane_node_taints
        }),
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "KubeNetworkConfig"
          dnsDomain  = var.cluster_domain
          # Required, and stated explicitly so a renderer default cannot drift the
          # cluster CIDRs. Placeholders in this excerpt.
          podSubnets     = ["10.200.0.0/16"]
          serviceSubnets = ["10.201.0.0/16"]
        }),
        # The 1.14 renderer turns workload isolation on by default (sandboxd adds
        # PID/mount namespaces for kubelet, CRI and pods). That is a behaviour
        # change, not a representation one: applying it restarts the runtime plane
        # on its own, and upstream lists in-tree iSCSI among the things it breaks.
        # The contract switch must be behaviour-neutral, so pin it off and enable
        # it deliberately later, with the CSI drivers and privileged pods tested.
        yamlencode({
          apiVersion        = "v1alpha1"
          kind              = "SecurityProfileConfig"
          workloadIsolation = false
        }),
        # Kernel logs, unlike service logs, cannot carry extraTags, so each node
        # has its own destination port and the relay attributes by port. A
        # KmsgLogConfig takes effect on config apply; adding talos.logging.kernel
        # as a kernel argument would only take effect on a Talos upgrade.
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "KmsgLogConfig"
          name       = "victorialogs"
          url        = local.kernel_logs_endpoints["k8s-control-${i + 1}"]
        }),
      ],
    )
  }
}
