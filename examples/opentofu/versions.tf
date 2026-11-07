# OpenTofu backend and state encryption — one file per module, same shape in
# terraform/{infra,talos,cloudflare}. Sanitized excerpt; the bucket name and the
# repository layout below are placeholders.
#
# Layout:
#
#   terraform/
#     tf                     the only entry point: injects credentials, takes the
#                            lock, enforces the apply guard and freeze
#     infra/
#       versions.tf          backend key "infra/terraform.tfstate"
#       controlplane.tf      three control-plane VMs
#       workers.tf           two worker VMs
#       haproxy.tf           API-VIP LXC
#       cloudflared.tf       tunnel LXC
#       windows.tf           GPU-passthrough VM (onboot: 0)
#       images.tf            Talos image, LXC template, virtio-win ISO
#     talos/
#       versions.tf          this file, backend key "talos/terraform.tfstate"
#       talos.tf             talos_machine_secrets, machine config, bootstrap
#       patches.tf           per-node config documents (see examples/talos)
#       check_apply.py       reports pending machine-config changes only
#     cloudflare/
#       versions.tf          backend key "cloudflare/terraform.tfstate"
#       access.tf, tunnel.tf, zone.tf, rules.tf, waf.tf
#     docs/state.md          authoritative procedure (location, lock, recovery)
#
# Why not Terraform: it has no state encryption (hashicorp/terraform#9556), and
# this state contains the cluster's identity, not just resource bookkeeping.
# See docs/decisions/0001-opentofu-encrypted-state-in-b2.md.

terraform {
  required_version = ">= 1.13.0"

  # State: one B2 bucket, one key per module, encrypted by OpenTofu before upload.
  # Run everything through ../tf, which supplies the B2 key, the passphrase and
  # the lock (B2 cannot do OpenTofu's S3 lockfile).
  backend "s3" {
    bucket = "example-homelab-tfstate"
    key    = "talos/terraform.tfstate"
    region = "us-west-004"
    endpoints = {
      s3 = "https://s3.us-west-004.backblazeb2.com"
    }
    use_path_style = true
    # B2 speaks the S3 API but is not AWS: no STS, no IMDS, no AWS region list,
    # no S3 checksum headers.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }

  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    # enforced: refuse to read or write anything unencrypted, so a plaintext
    # state put into the bucket is rejected rather than trusted. The plan file
    # is covered too: it contains the same values.
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
  }
}

variable "state_passphrase" {
  description = "State encryption passphrase; ../tf sets it from TFSTATE_PASSPHRASE_<MODULE>."
  type        = string
  sensitive   = true
}
