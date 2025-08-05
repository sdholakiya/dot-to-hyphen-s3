output "bucket_mapping" {
  description = "Mapping of original bucket names to new bucket names (dots replaced with hyphens)"
  value       = local.bucket_mapping
}

output "new_bucket_names" {
  description = "List of new bucket names with hyphens"
  value       = var.dry_run ? values(local.bucket_mapping) : [for bucket in aws_s3_bucket.new_buckets : bucket.bucket]
}

output "new_bucket_arns" {
  description = "ARNs of the newly created buckets"
  value       = var.dry_run ? [for new in values(local.bucket_mapping) : "arn:aws:s3:::${new}"] : [for bucket in aws_s3_bucket.new_buckets : bucket.arn]
}

output "bucket_details" {
  description = "Detailed information about bucket transformation"
  value = {
    for original, new in local.bucket_mapping : original => {
      original_name = original
      new_name      = new
      new_arn       = var.dry_run ? "arn:aws:s3:::${new}" : aws_s3_bucket.new_buckets[original].arn
      new_id        = var.dry_run ? new : aws_s3_bucket.new_buckets[original].id
      region        = var.dry_run ? var.aws_region : aws_s3_bucket.new_buckets[original].region
      dots_replaced = length(regexall("\\.", original))
    }
  }
}