###############################################################################
# Remote state backend bootstrap
#
# Creates the S3 bucket + DynamoDB lock table that EVERY other Terraform root
# module in this repo uses as its backend. Run this exactly once per AWS account.
###############################################################################

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        Project   = var.project
        ManagedBy = "terraform"
        Component = "tf-backend-bootstrap"
      },
      var.tags,
    )
  }
}

# Resolve the account id at plan time so the bucket name is globally unique and
# self-documenting (which account it belongs to) without hardcoding it.
data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
  lock_table_name   = "${var.project}-tf-locks"
}

###############################################################################
# S3 — state storage
###############################################################################

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # Guardrail: refuse to delete a bucket that still holds state unless explicitly
  # opted in. State history is precious; losing it is unrecoverable.
  force_destroy = var.state_bucket_force_destroy

  tags = {
    Name = local.state_bucket_name
  }
}

# Versioning lets us recover from a corrupted/bad state push.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt every object at rest. SSE-S3 (AES256) keeps bootstrap dependency-free;
# switch to aws:kms with a CMK if your compliance posture requires key rotation
# you control.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# State is sensitive — block ALL forms of public access unconditionally.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Reject any plaintext (HTTP) request and any unencrypted PUT.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  # The policy references the public-access-block; create it after so we never
  # have a transient window with a permissive bucket.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# Expire old non-current versions so the bucket does not grow unbounded, while
# still keeping a generous recovery window.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {} # apply to all objects

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

###############################################################################
# DynamoDB — state locking
###############################################################################

resource "aws_dynamodb_table" "locks" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST" # locking traffic is tiny and bursty
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Recover the table if it's accidentally deleted.
  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name = local.lock_table_name
  }
}
