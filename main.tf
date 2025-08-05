terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Local values to transform bucket names (dots to hyphens)
locals {
  bucket_mapping = {
    for bucket in var.source_bucket_names : 
    bucket => replace(bucket, ".", "-")
  }
}

# Data source to get existing bucket properties
data "aws_s3_bucket" "source_buckets" {
  for_each = toset(var.source_bucket_names)
  bucket   = each.value
}

data "aws_s3_bucket_versioning" "source_versioning" {
  for_each = toset(var.source_bucket_names)
  bucket   = each.value
}

data "aws_s3_bucket_encryption" "source_encryption" {
  for_each = toset(var.source_bucket_names)
  bucket   = each.value
}

data "aws_s3_bucket_lifecycle_configuration" "source_lifecycle" {
  for_each = toset(var.source_bucket_names)
  bucket   = each.value
}

data "aws_s3_bucket_cors_configuration" "source_cors" {
  for_each = toset(var.source_bucket_names)
  bucket   = each.value
}

data "aws_s3_bucket_public_access_block" "source_pab" {
  for_each = toset(var.source_bucket_names)
  bucket   = each.value
}

# Create new buckets with dots replaced by hyphens
resource "aws_s3_bucket" "new_buckets" {
  for_each = local.bucket_mapping
  bucket   = each.value  # This is the transformed name (dots -> hyphens)
  
  tags = merge(
    var.default_tags,
    {
      SourceBucket = each.key  # This is the original name with dots
      NewBucket    = each.value # This is the new name with hyphens
      CreatedBy    = "terraform"
    }
  )
}

# Copy versioning configuration
resource "aws_s3_bucket_versioning" "new_bucket_versioning" {
  for_each = aws_s3_bucket.new_buckets
  bucket   = each.value.id
  
  versioning_configuration {
    status = try(data.aws_s3_bucket_versioning.source_versioning[each.key].versioning_configuration[0].status, "Disabled")
  }
}

# Copy encryption configuration
resource "aws_s3_bucket_server_side_encryption_configuration" "new_bucket_encryption" {
  for_each = aws_s3_bucket.new_buckets
  bucket   = each.value.id

  dynamic "rule" {
    for_each = try(data.aws_s3_bucket_encryption.source_encryption[each.key].rule, [])
    content {
      apply_server_side_encryption_by_default {
        sse_algorithm     = rule.value.apply_server_side_encryption_by_default[0].sse_algorithm
        kms_master_key_id = try(rule.value.apply_server_side_encryption_by_default[0].kms_master_key_id, null)
      }
      bucket_key_enabled = try(rule.value.bucket_key_enabled, null)
    }
  }
}

# Copy lifecycle configuration
resource "aws_s3_bucket_lifecycle_configuration" "new_bucket_lifecycle" {
  for_each = aws_s3_bucket.new_buckets
  bucket   = each.value.id

  dynamic "rule" {
    for_each = try(data.aws_s3_bucket_lifecycle_configuration.source_lifecycle[each.key].rule, [])
    content {
      id     = rule.value.id
      status = rule.value.status

      dynamic "filter" {
        for_each = try([rule.value.filter], [])
        content {
          prefix = try(filter.value.prefix, null)
          
          dynamic "tag" {
            for_each = try(filter.value.tag, [])
            content {
              key   = tag.value.key
              value = tag.value.value
            }
          }
        }
      }

      dynamic "expiration" {
        for_each = try([rule.value.expiration], [])
        content {
          date                         = try(expiration.value.date, null)
          days                         = try(expiration.value.days, null)
          expired_object_delete_marker = try(expiration.value.expired_object_delete_marker, null)
        }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = try([rule.value.noncurrent_version_expiration], [])
        content {
          noncurrent_days = try(noncurrent_version_expiration.value.noncurrent_days, null)
        }
      }

      dynamic "transition" {
        for_each = try(rule.value.transition, [])
        content {
          date          = try(transition.value.date, null)
          days          = try(transition.value.days, null)
          storage_class = transition.value.storage_class
        }
      }

      dynamic "noncurrent_version_transition" {
        for_each = try(rule.value.noncurrent_version_transition, [])
        content {
          noncurrent_days = try(noncurrent_version_transition.value.noncurrent_days, null)
          storage_class   = noncurrent_version_transition.value.storage_class
        }
      }
    }
  }
}

# Copy CORS configuration
resource "aws_s3_bucket_cors_configuration" "new_bucket_cors" {
  for_each = aws_s3_bucket.new_buckets
  bucket   = each.value.id

  dynamic "cors_rule" {
    for_each = try(data.aws_s3_bucket_cors_configuration.source_cors[each.key].cors_rule, [])
    content {
      allowed_headers = try(cors_rule.value.allowed_headers, null)
      allowed_methods = cors_rule.value.allowed_methods
      allowed_origins = cors_rule.value.allowed_origins
      expose_headers  = try(cors_rule.value.expose_headers, null)
      max_age_seconds = try(cors_rule.value.max_age_seconds, null)
    }
  }
}

# Copy public access block configuration
resource "aws_s3_bucket_public_access_block" "new_bucket_pab" {
  for_each = aws_s3_bucket.new_buckets
  bucket   = each.value.id

  block_public_acls       = try(data.aws_s3_bucket_public_access_block.source_pab[each.key].block_public_acls, true)
  block_public_policy     = try(data.aws_s3_bucket_public_access_block.source_pab[each.key].block_public_policy, true)
  ignore_public_acls      = try(data.aws_s3_bucket_public_access_block.source_pab[each.key].ignore_public_acls, true)
  restrict_public_buckets = try(data.aws_s3_bucket_public_access_block.source_pab[each.key].restrict_public_buckets, true)
}

# Check if AWS CLI is available
resource "null_resource" "check_aws_cli" {
  count = var.copy_data ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      if ! command -v aws &> /dev/null; then
        echo "ERROR: AWS CLI is required for data copying but not found."
        echo "Please install AWS CLI or set copy_data = false"
        echo "Installation guide: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
        exit 1
      fi
      
      echo "AWS CLI found: $(aws --version)"
      
      # Verify AWS credentials
      if ! aws sts get-caller-identity &> /dev/null; then
        echo "ERROR: AWS credentials not configured or invalid."
        echo "Please run: aws configure"
        exit 1
      fi
      
      echo "AWS credentials verified: $(aws sts get-caller-identity --query 'Account' --output text)"
    EOT
  }
}

# Null resource to copy data using AWS CLI
resource "null_resource" "copy_bucket_data" {
  for_each = var.copy_data ? local.bucket_mapping : {}

  provisioner "local-exec" {
    command = <<-EOT
      echo "=============================================="
      echo "Copying data from ${each.key} to ${each.value}"
      echo "=============================================="
      
      # Check if source bucket exists and is accessible
      if ! aws s3 ls s3://${each.key} --region ${var.aws_region} &> /dev/null; then
        echo "ERROR: Cannot access source bucket s3://${each.key}"
        echo "Please verify bucket exists and you have read permissions"
        exit 1
      fi
      
      # Check if destination bucket is ready
      if ! aws s3 ls s3://${each.value} --region ${var.aws_region} &> /dev/null; then
        echo "ERROR: Destination bucket s3://${each.value} not accessible"
        echo "This should not happen - bucket creation may have failed"
        exit 1
      fi
      
      # Perform the sync with progress and error handling
      echo "Starting sync operation..."
      if aws s3 sync s3://${each.key} s3://${each.value} \
          --region ${var.aws_region} \
          --no-progress \
          --only-show-errors; then
        echo "✓ Successfully copied data from ${each.key} to ${each.value}"
      else
        echo "✗ Failed to copy data from ${each.key} to ${each.value}"
        exit 1
      fi
      
      echo "=============================================="
    EOT
  }

  depends_on = [
    null_resource.check_aws_cli,
    aws_s3_bucket.new_buckets,
    aws_s3_bucket_versioning.new_bucket_versioning,
    aws_s3_bucket_server_side_encryption_configuration.new_bucket_encryption,
    aws_s3_bucket_public_access_block.new_bucket_pab
  ]
}