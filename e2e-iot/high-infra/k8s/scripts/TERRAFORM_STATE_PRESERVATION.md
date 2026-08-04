# Terraform State Preservation in 00-deploy-infra.sh

## Problem

The `00-deploy-infra.sh` script was not preserving Terraform state, which could lead to:
- Loss of infrastructure management capability if state file is deleted
- Inability to track existing resources
- Risk of orphaned resources or accidental recreation

## Solution

The script has been updated to:
1. **Detect backend configuration** - Checks if remote backend is configured in `main.tf`
2. **Backup local state** - Automatically backs up state file before and after operations
3. **Warn about state preservation** - Provides clear warnings and instructions
4. **Verify backend status** - Confirms backend configuration after `terraform init`

## How It Works

### 1. Pre-Init State Check

Before running `terraform init`, the script:
- Checks if backend block is configured in `main.tf`
- If no backend is configured:
  - Warns that state will be stored locally
  - Creates a timestamped backup of existing state file (if it exists)
  - Provides instructions for configuring remote backend

### 2. Post-Init Verification

After `terraform init`, the script:
- Verifies if backend is actually being used
- Checks `.terraform/terraform.tfstate` for backend configuration
- Updates `USE_LOCAL_STATE` flag accordingly
- Provides migration instructions if needed

### 3. Post-Apply Backup

After successful `terraform apply`:
- If using local state, creates a timestamped backup
- Backup filename format: `terraform.tfstate.backup.YYYYMMDD_HHMMSS`

### 4. Final Reminder

At the end of the script:
- If using local state, displays important reminders:
  - Location of state file
  - Warning not to delete it
  - Instructions for configuring remote backend

## State File Locations

### Local State (Default)
- **State file**: `terraform/terraform.tfstate`
- **Backups**: `terraform/terraform.tfstate.backup.*`
- **Backend config**: `.terraform/terraform.tfstate` (if backend configured)

### Remote State (S3 Backend)
- **State file**: Stored in S3 bucket
- **Local cache**: `.terraform/terraform.tfstate`
- **Backend config**: `.terraform/terraform.tfstate`

## Configuring Remote State

To configure S3 backend for state preservation:

### Step 1: Create S3 Bucket

```bash
aws s3 mb s3://your-terraform-state-bucket --region us-west-2
aws s3api put-bucket-versioning \
  --bucket your-terraform-state-bucket \
  --versioning-configuration Status=Enabled
```

### Step 2: Update main.tf

Uncomment and configure the backend block in `terraform/main.tf`:

```terraform
terraform {
  # ... existing configuration ...

  backend "s3" {
    bucket = "your-terraform-state-bucket"
    key    = "fluss-e2e-platform-aws/terraform.tfstate"
    region = "us-west-2"
    
    # Optional: Enable state locking with DynamoDB
    # dynamodb_table = "terraform-state-lock"
    # encrypt        = true
  }
}
```

### Step 3: Migrate Existing State

If you have existing local state:

```bash
cd terraform
terraform init -migrate-state
```

This will:
1. Detect existing local state
2. Prompt to migrate to S3 backend
3. Copy state to S3
4. Update local backend configuration

## Backup Files

The script creates backups with timestamps:
- Format: `terraform.tfstate.backup.YYYYMMDD_HHMMSS`
- Example: `terraform.tfstate.backup.20240115_143022`

### Manual Backup

You can also manually backup state:

```bash
cd terraform
cp terraform.tfstate terraform.tfstate.backup.$(date +%Y%m%d_%H%M%S)
```

### Restore from Backup

If state file is lost:

```bash
cd terraform
cp terraform.tfstate.backup.YYYYMMDD_HHMMSS terraform.tfstate
terraform init
```

## Best Practices

1. **Use Remote Backend**: Configure S3 backend for production deployments
2. **Enable Versioning**: Enable S3 bucket versioning for state files
3. **Enable Encryption**: Use S3 server-side encryption
4. **State Locking**: Use DynamoDB for state locking (prevents concurrent modifications)
5. **Regular Backups**: Even with remote backend, keep periodic backups
6. **Never Commit State**: Add `terraform.tfstate*` to `.gitignore`

## Example .gitignore

```gitignore
# Terraform state files
terraform.tfstate
terraform.tfstate.*
*.tfstate
*.tfstate.backup

# Terraform directories
.terraform/
.terraform.lock.hcl

# Terraform plan files
*.tfplan
tfplan*
```

## Troubleshooting

### State File Not Found

If you see "state file not found" errors:

1. Check if backups exist:
   ```bash
   ls -la terraform/terraform.tfstate.backup.*
   ```

2. Restore from backup (see above)

3. If no backup exists, you may need to re-import resources

### Backend Migration Issues

If migration fails:

1. Ensure S3 bucket exists and is accessible
2. Check IAM permissions for S3 access
3. Verify backend configuration in `main.tf`
4. Try manual migration:
   ```bash
   terraform init -backend-config="bucket=your-bucket" -migrate-state
   ```

### Concurrent State Access

If multiple users are running terraform:

1. Configure DynamoDB table for state locking
2. Use remote backend (S3 + DynamoDB)
3. Coordinate deployments to avoid conflicts

## Script Output Example

When running the script with local state:

```
==========================================
Checking Terraform State Configuration
==========================================
⚠ WARNING: No remote backend configured in main.tf
  Terraform state will be stored locally in: .../terraform/terraform.tfstate
  This state file is critical - if lost, Terraform cannot manage existing infrastructure

  To preserve state, consider:
    1. Configure S3 backend in main.tf (uncomment backend block)
    2. Or backup terraform.tfstate file regularly

  Creating backup of existing state file...
  ✓ State backed up to: .../terraform.tfstate.backup.20240115_143022
```

After successful apply:

```
Backing up Terraform state after successful apply...
✓ State backed up to: .../terraform.tfstate.backup.20240115_143045
```

At the end:

```
==========================================
⚠ IMPORTANT: Terraform State Preservation
==========================================

Your Terraform state is stored locally at:
  .../terraform/terraform.tfstate

⚠ CRITICAL: This file is essential for managing your infrastructure!
  - DO NOT delete this file
  - DO NOT commit it to version control (contains sensitive data)
  - Backup this file regularly

To configure remote state storage (recommended):
  1. Create an S3 bucket for Terraform state
  2. Uncomment and configure the backend block in main.tf
  3. Run: terraform init -migrate-state
```

## Summary

The updated script now:
- ✅ Detects backend configuration
- ✅ Backs up state before operations
- ✅ Backs up state after successful apply
- ✅ Provides clear warnings and instructions
- ✅ Verifies backend status after init
- ✅ Reminds users about state preservation

This ensures Terraform state is preserved and users are aware of the importance of state management.

