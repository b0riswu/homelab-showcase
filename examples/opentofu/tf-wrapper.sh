#!/bin/sh
# Excerpt from terraform/tf — the only supported way to run OpenTofu here.
#
#   terraform/tf talos plan
#   terraform/tf infra apply -target=proxmox_virtual_environment_vm.worker
#
# The full script also injects the B2 state credentials, fetches provider tokens
# from OpenBao for provider-backed commands (interactive, with a second factor), and
# passes TF_VAR_state_passphrase. This excerpt keeps the two parts that are about
# safety rather than plumbing: the apply guard, and the freeze/lock.
#
# Sanitized excerpt: paths and module names as upstream, no secrets.
set -eu

usage() {
  echo "usage: $0 <infra|talos|cloudflare> <tofu arguments...>" >&2
  exit 2
}

[ $# -ge 1 ] || usage
module=$1
shift
case $module in
  infra) passphrase=${TFSTATE_PASSPHRASE_INFRA:-} ;;
  talos) passphrase=${TFSTATE_PASSPHRASE_TALOS:-} ;;
  cloudflare) passphrase=${TFSTATE_PASSPHRASE_CLOUDFLARE:-} ;;
  *) usage ;;
esac

missing=""
[ -n "${TFSTATE_B2_KEY_ID:-}" ] || missing="$missing TFSTATE_B2_KEY_ID"
[ -n "${TFSTATE_B2_APP_KEY:-}" ] || missing="$missing TFSTATE_B2_APP_KEY"
[ -n "$passphrase" ] || missing="$missing TFSTATE_PASSPHRASE_$(echo "$module" | tr a-z A-Z)"
if [ -n "$missing" ]; then
  echo "tf: not set:$missing" >&2
  echo "tf: set these from the operator secret store" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")" && pwd)
cd "$root/$module"

command=${1:-}

# --- apply guard -------------------------------------------------------------
# apply/destroy run only from the main checkout, on main, at origin/main, with a
# clean terraform/ tree. The code being applied is then exactly what was merged,
# and talos writes generated/ where KUBECONFIG and TALOSCONFIG point.
# TF_ALLOW_BRANCH_APPLY=1 is for the rare change that must be applied before it
# can merge (a rollback); secret rotations use the freeze below instead.
case $command in
  apply | destroy)
    if [ -z "${TF_ALLOW_BRANCH_APPLY:-}" ]; then
      branch=$(git rev-parse --abbrev-ref HEAD)
      gitdir=$(git rev-parse --path-format=absolute --git-dir)
      common=$(git rev-parse --path-format=absolute --git-common-dir)
      reason=""
      if [ "$gitdir" != "$common" ]; then
        reason="this is a worktree ($branch), not the main checkout"
      elif [ "$branch" != main ]; then
        reason="the main checkout is on $branch, not main"
      elif [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
        reason="main is not at origin/main (git pull first)"
      elif [ -n "$(git status --porcelain -- "$root")" ]; then
        reason="terraform/ has uncommitted changes"
      fi
      if [ -n "$reason" ]; then
        echo "tf: refusing to $command: $reason." >&2
        echo "tf: merge the change and run it from the main checkout, or set TF_ALLOW_BRANCH_APPLY=1." >&2
        exit 2
      fi
    fi
    ;;
esac

# --- freeze ------------------------------------------------------------------
# While ~/.cache/homelab-tofu/<module>.frozen exists, apply/destroy of that module
# is refused and plan prints a warning. A secret rotation creates it for talos
# before staging the new etcd CA: until the new bundle is imported, the state
# still holds the old secrets, and an ordinary apply would push them back onto
# the nodes. The file's first line is printed as the reason.
# TF_ALLOW_FROZEN_APPLY=1 is for the rotation's own apply right after import.
freeze="$HOME/.cache/homelab-tofu/$module.frozen"
if [ -f "$freeze" ]; then
  why=$(head -n 1 "$freeze")
  case $command in
    apply | destroy)
      if [ -z "${TF_ALLOW_FROZEN_APPLY:-}" ]; then
        echo "tf: refusing to $command $module: frozen ($freeze): ${why:-no reason given}" >&2
        echo "tf: remove the file when the operation is finished, or set TF_ALLOW_FROZEN_APPLY=1." >&2
        exit 2
      fi
      ;;
    plan) echo "tf: warning: $module is frozen ($freeze): ${why:-no reason given}" >&2 ;;
  esac
fi

# --- lock --------------------------------------------------------------------
# B2 rejects the conditional writes OpenTofu's S3 lockfile needs
# (If-None-Match -> 501, tested 2026-11-07), so runs are serialised with a
# per-module lockf(1) lock. It protects every worktree on this machine and
# nothing else — a second operator would still race.
AWS_ACCESS_KEY_ID=$TFSTATE_B2_KEY_ID
AWS_SECRET_ACCESS_KEY=$TFSTATE_B2_APP_KEY
TF_VAR_state_passphrase=$passphrase
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TF_VAR_state_passphrase

lockdir="$HOME/.cache/homelab-tofu"
mkdir -p "$lockdir"
lock="$lockdir/$module.lock"
status=0
lockf -s -t 0 "$lock" tofu "$@" || status=$?
if [ "$status" -eq 75 ]; then
  echo "tf: another '$module' run holds $lock; wait for it to finish" >&2
fi
exit "$status"
