terraform {
  required_version = ">= 1.16.0, < 2.0.0"
  backend "s3" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67.0"
    }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38.0" }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3.0"
    }
  }
}
