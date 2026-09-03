terraform {
  required_version = ">= 1.16.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }

  backend "s3" {
    bucket       = "jkandler-terraform-state"
    key          = "k3s-apps-bootstrap/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
