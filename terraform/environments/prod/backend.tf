###############################################################################
# Remote state backend (S3 + DynamoDB)
#
# Created by terraform/bootstrap. Replace <account_id> with your real account id.
# Note the distinct state key — prod state is fully isolated from dev.
###############################################################################

terraform {
  backend "s3" {
    bucket         = "eks-gitops-platform-tfstate-<account_id>"
    key            = "environments/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "eks-gitops-platform-tf-locks"
    encrypt        = true
  }
}
