output "bucket_mapping" {
  description = "Mapping of original bucket names to new bucket names (dots replaced with hyphens)"
  value       = local.bucket_mapping
}

output "new_bucket_names" {
  description = "List of new bucket names with hyphens"
  value       = [for bucket in aws_s3_bucket.new_buckets : bucket.bucket]
}

output "new_bucket_arns" {
  description = "ARNs of the newly created buckets"
  value       = [for bucket in aws_s3_bucket.new_buckets : bucket.arn]
}

output "bucket_details" {
  description = "Detailed information about bucket transformation"
  value = {
    for original, new in local.bucket_mapping : original => {
      original_name = original
      new_name      = new
      new_arn       = aws_s3_bucket.new_buckets[original].arn
      new_id        = aws_s3_bucket.new_buckets[original].id
      region        = aws_s3_bucket.new_buckets[original].region
      dots_replaced = length(regexall("\\.", original))
    }
  }
}