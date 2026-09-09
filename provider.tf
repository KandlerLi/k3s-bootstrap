# This root stays local-apply-only, cluster-admin, by design -- see
# README.md. Same kubeconfig/tunnel setup infra/k3s-apps' own README
# documents (the SSH tunnel to the k3s API server + scp'ing its admin
# kubeconfig) -- this root just needs it far more rarely than that
# repo's own CI-applied app root does.
provider "kubernetes" {
  config_path = pathexpand("~/.kube/k3s-node-1.yaml")
}

# Reads secrets.tf's own home-infra/github-runner secret (the SOPS-to-
# Secrets-Manager cutover, PARKED.md). Auth is ambient -- the
# k3s-bootstrap-local IAM identity's access key, already exported by
# scripts/roll-out.sh for the S3 backend.
provider "aws" {
  region = "eu-central-1"
}
