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

# Use external data sources to get bucket configurations via AWS CLI (only when not in dry run)
data "external" "source_versioning" {
  for_each = var.dry_run ? toset([]) : toset(var.source_bucket_names)
  program = ["bash", "-c", <<-EOT
    versioning_status=$(aws s3api get-bucket-versioning --bucket ${each.value} --query 'Status' --output text 2>/dev/null || echo "Disabled")
    if [ "$versioning_status" = "None" ] || [ "$versioning_status" = "" ]; then
      versioning_status="Disabled"
    fi
    echo "{\"status\": \"$versioning_status\"}"
  EOT
  ]
}

data "external" "source_encryption" {
  for_each = var.dry_run ? toset([]) : toset(var.source_bucket_names)
  program = ["bash", "-c", <<-EOT
    encryption=$(aws s3api get-bucket-encryption --bucket ${each.value} --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault' --output json 2>/dev/null || echo '{}')
    echo "{\"encryption\": $encryption}"
  EOT
  ]
}

data "external" "source_public_access_block" {
  for_each = var.dry_run ? toset([]) : toset(var.source_bucket_names)
  program = ["bash", "-c", <<-EOT
    pab=$(aws s3api get-public-access-block --bucket ${each.value} --query 'PublicAccessBlockConfiguration' --output json 2>/dev/null || echo '{"BlockPublicAcls": true, "IgnorePublicAcls": true, "BlockPublicPolicy": true, "RestrictPublicBuckets": true}')
    echo "{\"config\": $pab}"
  EOT
  ]
}

# Dry run output - shows bucket mapping and configurations
resource "null_resource" "dry_run_output" {
  count = var.dry_run ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      echo "=============================================="
      echo "DRY RUN - S3 BUCKET MIGRATION PLAN"
      echo "=============================================="
      echo ""
      echo "BUCKET MAPPING (Source -> Target):"
      echo "-----------------------------------"
      %{for source, target in local.bucket_mapping}
      echo "  ${source} -> ${target}"
      %{endfor}
      echo ""
      echo "CONFIGURATIONS TO BE COPIED:"
      echo "----------------------------"
      echo "✓ Versioning settings"
      echo "✓ Encryption settings"
      echo "✓ Public access block settings"
      echo "⚠ Lifecycle rules (manual configuration required)"
      echo "⚠ CORS rules (manual configuration required)"
      echo ""
      echo "DATA COPYING: ${var.copy_data ? "ENABLED" : "DISABLED"}"
      echo ""
      echo "To proceed with actual migration, set dry_run = false"
      echo "=============================================="
      
      # Show source bucket configurations
      echo ""
      echo "SOURCE BUCKET CONFIGURATIONS:"
      echo "=============================="
      %{for bucket in var.source_bucket_names}
      echo ""
      echo "Bucket: ${bucket}"
      echo "-------------------"
      
      # Check if bucket exists
      if aws s3 ls s3://${bucket} --region ${var.aws_region} &>/dev/null; then
        echo "✓ Bucket exists and is accessible"
        
        # Get versioning
        versioning=$(aws s3api get-bucket-versioning --bucket ${bucket} --query 'Status' --output text 2>/dev/null || echo "Disabled")
        echo "  Versioning: $versioning"
        
        # Get encryption
        encryption=$(aws s3api get-bucket-encryption --bucket ${bucket} --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>/dev/null || echo "None")
        echo "  Encryption: $encryption"
        
        # Get public access block
        pab=$(aws s3api get-public-access-block --bucket ${bucket} --output text 2>/dev/null || echo "Not configured")
        echo "  Public Access Block: $pab"
        
        # Get object count and size
        object_count=$(aws s3 ls s3://${bucket} --recursive --summarize --region ${var.aws_region} 2>/dev/null | grep "Total Objects:" | awk '{print $3}' || echo "Unknown")
        total_size=$(aws s3 ls s3://${bucket} --recursive --summarize --region ${var.aws_region} 2>/dev/null | grep "Total Size:" | awk '{print $3, $4}' || echo "Unknown")
        echo "  Objects: $object_count"
        echo "  Total Size: $total_size"
      else
        echo "✗ Bucket not accessible or doesn't exist"
      fi
      %{endfor}
      
      echo ""
      echo "=============================================="
    EOT
  }

  # Prevent any other resources from being created in dry run mode
  lifecycle {
    prevent_destroy = true
  }
}

# Create new buckets with dots replaced by hyphens
resource "aws_s3_bucket" "new_buckets" {
  for_each = var.dry_run ? {} : local.bucket_mapping
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
  for_each = var.dry_run ? {} : aws_s3_bucket.new_buckets
  bucket   = each.value.id
  
  versioning_configuration {
    status = try(data.external.source_versioning[each.key].result.status, "Disabled")
  }
}

# Copy encryption configuration
resource "aws_s3_bucket_server_side_encryption_configuration" "new_bucket_encryption" {
  for_each = var.dry_run ? {} : aws_s3_bucket.new_buckets
  bucket   = each.value.id

  dynamic "rule" {
    for_each = try(jsondecode(data.external.source_encryption[each.key].result.encryption).SSEAlgorithm, null) != null ? [1] : []
    content {
      apply_server_side_encryption_by_default {
        sse_algorithm     = try(jsondecode(data.external.source_encryption[each.key].result.encryption).SSEAlgorithm, "AES256")
        kms_master_key_id = try(jsondecode(data.external.source_encryption[each.key].result.encryption).KMSMasterKeyID, null)
      }
      bucket_key_enabled = try(jsondecode(data.external.source_encryption[each.key].result.encryption).BucketKeyEnabled, null)
    }
  }
}

# Note: Lifecycle configuration copying is complex with external data sources
# For now, we'll skip copying lifecycle rules and apply default settings
# You can manually configure lifecycle rules for the new buckets if needed

# Note: CORS configuration copying is complex with external data sources
# For now, we'll skip copying CORS rules and apply default settings
# You can manually configure CORS rules for the new buckets if needed

# Copy public access block configuration
resource "aws_s3_bucket_public_access_block" "new_bucket_pab" {
  for_each = var.dry_run ? {} : aws_s3_bucket.new_buckets
  bucket   = each.value.id

  block_public_acls       = try(jsondecode(data.external.source_public_access_block[each.key].result.config).BlockPublicAcls, true)
  block_public_policy     = try(jsondecode(data.external.source_public_access_block[each.key].result.config).BlockPublicPolicy, true)
  ignore_public_acls      = try(jsondecode(data.external.source_public_access_block[each.key].result.config).IgnorePublicAcls, true)
  restrict_public_buckets = try(jsondecode(data.external.source_public_access_block[each.key].result.config).RestrictPublicBuckets, true)
}

# Check if AWS CLI is available
resource "null_resource" "check_aws_cli" {
  count = var.copy_data && !var.dry_run ? 1 : 0

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
  for_each = var.copy_data && !var.dry_run ? local.bucket_mapping : {}

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