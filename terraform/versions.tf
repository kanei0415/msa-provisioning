terraform {
  required_version = ">=1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~>5.80"
    }
    http = {
      source  = "hashicorp/http"
      version = "~>3.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~>2.5"
    }
  }

  backend "s3" {}
}
