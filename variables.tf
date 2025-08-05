variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "source_bucket_names" {
  description = "List of source bucket names (dots will be replaced with hyphens in new buckets)"
  type        = list(string)
  validation {
    condition     = length(var.source_bucket_names) > 0
    error_message = "At least one source bucket name must be provided."
  }
}

variable "copy_data" {
  description = "Whether to copy data from source buckets to new buckets"
  type        = bool
  default     = true
}

variable "dry_run" {
  description = "When true, only shows bucket mapping and configurations without creating resources"
  type        = bool
  default     = false
}

variable "default_tags" {
  description = "Default tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "production"
    ManagedBy   = "terraform"
    Project     = "s3-bucket-migration"
  }
}