# Local-apply only, with the node's cluster-admin kubeconfig: see README.
provider "kubernetes" {
  config_path = pathexpand("~/.kube/k3s-node-1.yaml")
}

# Ambient auth: roll-out.sh exports the k3s-bootstrap-local key for the backend anyway.
provider "aws" {
  region = "eu-central-1"
}
