#!/usr/bin/env bash
# Mimics what a real CI pipeline would do for this repo's own apply,
# run locally: set up the SSH tunnel + kubeconfig + secrets this root's
# Terraform needs, run it, then tear back down whatever this script
# itself stood up -- so a tunnel this script started doesn't outlive
# the run, but a tunnel that was already open before it started (e.g.
# from an unrelated kubectl session) is left alone either way.
#
#   scripts/roll-out.sh plan
#   scripts/roll-out.sh apply
#
# Needs, none of which this script sets up on its own:
# - AWS credentials for this root's own S3 state backend -- still a
#   manual `aws login` as root/an admin-equivalent identity first
#   (this root has no scoped, non-root identity today, unlike
#   github/repo-infra's own repo-infra-local -- julian's own policy
#   doesn't grant it k3s-bootstrap/* state access at all).
# - The node's own admin kubeconfig at ~/.kube/k3s-node-1.yaml -- a
#   one-time `scp` pull, see infra/k3s-apps' own README.

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
k3s_apps_dir="${K3S_APPS_DIR:-$(cd "${repo_root}/../../infra/k3s-apps" 2>/dev/null && pwd || true)}"
[ -n "${k3s_apps_dir}" ] && [ -f "${k3s_apps_dir}/scripts/export-tf-vars.sh" ] \
  || fail "can't find infra/k3s-apps' scripts/export-tf-vars.sh (looked in '${k3s_apps_dir:-<unset>}') -- set K3S_APPS_DIR if your checkout layout differs"

kubeconfig="${HOME}/.kube/k3s-node-1.yaml"
[ -f "${kubeconfig}" ] || fail "${kubeconfig} is missing -- one-time setup: see infra/k3s-apps' own README for the scp command that pulls it"

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

# Sourced *inside this script's own process*, not the caller's
# interactive shell (this script is executed, not sourced) -- so
# nothing it exports outlives this run either, same as the AWS/GITHUB_TOKEN
# exports in github/repo-infra's own roll-out.sh.
# shellcheck source=/dev/null
source "${k3s_apps_dir}/scripts/export-tf-vars.sh"

cd "${repo_root}"

terraform init -input=false
terraform fmt -check -recursive
terraform validate
terraform plan

if [ "${mode}" = "apply" ]; then
  # Interactive on purpose -- terraform's own plan-and-confirm prompt is
  # the review step, not -auto-approve.
  terraform apply
fi
