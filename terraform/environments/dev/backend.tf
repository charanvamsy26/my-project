###############################################################################
# Remote state backend (S3 + DynamoDB)
#
# Created by terraform/bootstrap. The bucket name embeds the account id; replace
# <account_id> with your real account id (the same value bootstrap printed).
# Backend config can't use variables, so this is the one place you hardcode it.
###############################################################################

terraform {
  backend "s3" {
    bucket         = "my-project-tfstate-<account_id>"
    key            = "environments/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "my-project-tf-locks"
    encrypt        = true
  }
}
