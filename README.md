# S3 Bucket Migration with Dot-to-Hyphen Replacement

This Terraform configuration creates new S3 buckets from a list of existing buckets, replacing dots (.) with hyphens (-) in the bucket names, and optionally copies all data while preserving bucket settings.

## Features

- **Dot-to-Hyphen Replacement**: Automatically replaces dots with hyphens in bucket names
- **Settings Preservation**: Copies all bucket configurations from source buckets:
  - Versioning
  - Encryption
  - Lifecycle policies
  - CORS configuration
  - Public access block settings
- **Data Migration**: Optionally copies all objects from source to new buckets
- **Clear Mapping**: Outputs show original vs new bucket names

## Example

Original buckets → New buckets:
- `my.company.logs` → `my-company-logs`
- `dev.application.data` → `dev-application-data`
- `prod.backup.files` → `prod-backup-files`

## Prerequisites

### 1. Terraform Installation
Download and install Terraform from [terraform.io](https://www.terraform.io/downloads)

### 2. AWS CLI Installation and Configuration
Install AWS CLI v2:
```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Windows
# Download from: https://awscli.amazonaws.com/AWSCLIV2.msi
```

Configure AWS CLI with your credentials:
```bash
aws configure
# Enter your:
# - AWS Access Key ID
# - AWS Secret Access Key
# - Default region (e.g., us-east-1)
# - Default output format (json)
```

Verify AWS CLI setup:
```bash
aws sts get-caller-identity
aws s3 ls  # Should list your existing buckets
```

### 3. AWS Console Setup Alternative

If you prefer using AWS Console credentials:

1. **Create IAM User** (AWS Console):
   - Go to IAM → Users → Create User
   - Enable "Programmatic access"
   - Attach the required policies (see IAM Policies section below)
   - Download the Access Key ID and Secret Access Key

2. **Configure with AWS CLI**:
   ```bash
   aws configure
   # Or use environment variables:
   export AWS_ACCESS_KEY_ID="your-access-key"
   export AWS_SECRET_ACCESS_KEY="your-secret-key"
   export AWS_DEFAULT_REGION="us-east-1"
   ```

3. **Alternative: AWS Profile Setup**:
   ```bash
   aws configure --profile s3-migration
   # Then use: export AWS_PROFILE=s3-migration
   ```

## Usage

1. **Configure variables**:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your bucket names
   ```

2. **Initialize and apply**:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

## Required AWS IAM Permissions

### Option 1: IAM Policy JSON (Recommended)

Create an IAM policy with these permissions:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ReadSourceBuckets",
            "Effect": "Allow",
            "Action": [
                "s3:GetBucketLocation",
                "s3:GetBucketVersioning",
                "s3:GetEncryptionConfiguration",
                "s3:GetBucketLifecycleConfiguration",
                "s3:GetBucketCors",
                "s3:GetBucketPublicAccessBlock",
                "s3:GetBucketPolicy",
                "s3:GetBucketAcl",
                "s3:GetBucketNotification",
                "s3:GetBucketTagging"
            ],
            "Resource": [
                "arn:aws:s3:::*"
            ]
        },
        {
            "Sid": "CreateAndManageNewBuckets",
            "Effect": "Allow",
            "Action": [
                "s3:CreateBucket",
                "s3:PutBucketVersioning",
                "s3:PutEncryptionConfiguration",
                "s3:PutBucketLifecycleConfiguration",
                "s3:PutBucketCors",
                "s3:PutBucketPublicAccessBlock",
                "s3:PutBucketTagging",
                "s3:PutBucketPolicy",
                "s3:PutBucketAcl"
            ],
            "Resource": [
                "arn:aws:s3:::*"
            ]
        },
        {
            "Sid": "CopyBucketData",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:PutObjectAcl",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::*",
                "arn:aws:s3:::*/*"
            ]
        }
    ]
}
```

### Option 2: AWS Managed Policies (Less Secure)

Alternatively, attach these AWS managed policies to your IAM user:
- `AmazonS3FullAccess` (gives full S3 access)

### Option 3: Create IAM User via AWS Console

1. **Go to AWS Console** → IAM → Users → Create User
2. **User Details**: 
   - Username: `terraform-s3-migration`
   - Access type: ✅ Programmatic access
3. **Permissions**:
   - Create policy using the JSON above
   - Or attach `AmazonS3FullAccess` policy
4. **Download Credentials**: Save the Access Key ID and Secret Access Key

### Option 4: Use Existing IAM Role (EC2/Lambda)

If running from EC2 or Lambda, attach the above policy to the instance/function role.

## Variables

- `source_bucket_names`: List of existing bucket names (required)
- `copy_data`: Whether to copy data (default: true)
- `aws_region`: AWS region (default: us-east-1)
- `default_tags`: Tags for all resources

## Outputs

- `bucket_mapping`: Shows original → new name mapping
- `bucket_details`: Detailed transformation information
- `new_bucket_names`: List of created bucket names
- `new_bucket_arns`: ARNs of new buckets

## Troubleshooting

### Common Issues

1. **"Access Denied" errors**:
   ```bash
   # Check your AWS credentials
   aws sts get-caller-identity
   
   # Verify you can list existing buckets
   aws s3 ls
   
   # Check specific bucket access
   aws s3 ls s3://your-bucket-name
   ```

2. **"AWS CLI not found" during data copy**:
   ```bash
   # Install AWS CLI (see Prerequisites section)
   # Or disable data copying:
   copy_data = false
   ```

3. **"Bucket already exists" error**:
   - Check if target buckets (with hyphens) already exist
   - S3 bucket names must be globally unique
   - Consider adding a prefix/suffix to new bucket names

4. **Region mismatch issues**:
   ```bash
   # Ensure consistent region configuration
   aws configure get region
   # Should match your terraform.tfvars aws_region
   ```

5. **Large data transfer timeouts**:
   - For very large buckets, consider running data copy separately
   - Set `copy_data = false` and run manual sync:
   ```bash
   aws s3 sync s3://source.bucket s3://source-bucket --region us-east-1
   ```

### Verification Steps

After running `terraform apply`:

1. **Check new buckets created**:
   ```bash
   aws s3 ls | grep -E "(your-pattern)"
   ```

2. **Verify bucket settings copied**:
   ```bash
   aws s3api get-bucket-versioning --bucket new-bucket-name
   aws s3api get-bucket-encryption --bucket new-bucket-name
   ```

3. **Check data copy status**:
   ```bash
   aws s3 ls s3://new-bucket-name --recursive --summarize
   ```

### Getting Help

- Check Terraform logs: `TF_LOG=DEBUG terraform apply`
- AWS CLI debug: `aws s3 ls --debug`
- Validate your IAM permissions using AWS Policy Simulator