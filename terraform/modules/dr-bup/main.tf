variable "name_prefix" { type = string }
variable "account_id"  { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_s3_bucket" "dr" {
  bucket = "${var.name_prefix}-dr-${var.account_id}"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-dr" })
}

# Versioning is the ransomware/oops protection: overwrites and deletes
# create new versions instead of destroying history.
resource "aws_s3_bucket_versioning" "dr" {
  bucket = aws_s3_bucket.dr.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dr" {
  bucket = aws_s3_bucket.dr.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "dr" {
  bucket                  = aws_s3_bucket.dr.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Tiering: recent backups stay hot; older ones get cheap; all else expire after a retention window.
resource "aws_s3_bucket_lifecycle_configuration" "dr" {
  bucket = aws_s3_bucket.dr.id

  rule {
    id     = "tier-and-retain"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "DEEP_ARCHIVE"
    }
    noncurrent_version_expiration {
      noncurrent_days = 180
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

output "bucket" { value = aws_s3_bucket.dr.id }