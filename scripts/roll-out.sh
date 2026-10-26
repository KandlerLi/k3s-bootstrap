#!/usr/bin/env bash
# Local plan/apply including the SSH tunnel and kubeconfig check: see README, "Deploy".

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") plan|apply" >&2
  exit 1
}

[ $# -eq 1 ] || usage
mode="$1"
case "$mode" in
  plan | apply) ;;
  *) usage ;;
esac

fail() {
  echo "roll-out.sh: $1" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "${script_dir}")"

kubeconfig="${HOME}/.kube/k3s-node-1.yaml"
[ -f "${kubeconfig}" ] || fail "${kubeconfig} is missing -- one-time setup: see KandlerLi/k3s-apps' own README for the scp command that pulls it"

access_key_id="$(pass show aws/k3s-bootstrap-local/access-key-id 2>/dev/null | head -1 || true)"
[ -n "${access_key_id}" ] || fail "pass entry aws/k3s-bootstrap-local/access-key-id is empty or missing -- see KandlerLi/terraform-state/README.md's 'k3s-bootstrap-local Identity' section"

secret_access_key="$(pass show aws/k3s-bootstrap-local/secret-access-key 2>/dev/null | head -1 || true)"
[ -n "${secret_access_key}" ] || fail "pass entry aws/k3s-bootstrap-local/secret-access-key is empty or missing -- see KandlerLi/terraform-state/README.md's 'k3s-bootstrap-local Identity' section"

export AWS_ACCESS_KEY_ID="${access_key_id}"
export AWS_SECRET_ACCESS_KEY="${secret_access_key}"

tunnel_pattern="ssh.*-L 6443:192.168.101.10:6443"
tunnel_started_by_this_script=0

if pgrep -f "${tunnel_pattern}" >/dev/null 2>&1; then
  echo "roll-out.sh: SSH tunnel already open, leaving it alone"
else
  echo "roll-out.sh: starting SSH tunnel"
  ssh -f -N -L 6443:192.168.101.10:6443 julian@192.168.178.100
  tunnel_started_by_this_script=1
fi

cleanup() {
  if [ "${tunnel_started_by_this_script}" -eq 1 ]; then
    echo "roll-out.sh: closing the SSH tunnel this script started"
    pkill -f "${tunnel_pattern}" || true
  fi
}
trap cleanup EXIT

cd "${repo_root}"

terraform init -input=false
terraform fmt -check -recursive
terraform validate
# -input=false: fail on a missing variable instead of prompting for it.
if [ "${mode}" = "plan" ]; then
  terraform plan -input=false
else
  # Interactive on purpose: apply prints the plan itself and its confirm prompt is the review step.
  terraform apply -input=false
fi
