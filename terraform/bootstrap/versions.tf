terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # NOTE: bootstrap intentionally uses LOCAL state. It is the stack that *creates*
  # the remote backend, so it cannot depend on that backend existing yet. Keep the
  # generated `terraform.tfstate` in a secure location (or commit it — it only
  # describes the bucket + lock table and contains no secrets).
}
