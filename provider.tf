# This root stays local-apply-only, cluster-admin, by design -- see
# README.md. Same kubeconfig/tunnel setup infra/k3s-apps' own README
# documents (the SSH tunnel to the k3s API server + scp'ing its admin
# kubeconfig) -- this root just needs it far more rarely than that
# repo's own CI-applied app root does.
provider "kubernetes" {
  config_path = pathexpand("~/.kube/k3s-node-1.yaml")
}
