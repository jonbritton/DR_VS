variable "name_prefix" { type = string }
variable "account_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_s3_bucket" "dr" {
  bucket = "${var.name_prefix}-dr-${var.account_id}"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-dr" })
}

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

# Backups cross the public internet (no VPN / Direct Connect), so refuse any
# request that arrives over plain HTTP. A Deny-only policy, so it composes with
# the identity policies rather than granting anything.
data "aws_iam_policy_document" "tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    resources = [
      aws_s3_bucket.dr.arn,
      "${aws_s3_bucket.dr.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tls_only" {
  bucket     = aws_s3_bucket.dr.id
  policy     = data.aws_iam_policy_document.tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.dr]
}

# Rrecent backups stay hot; older ones get cheap; all else expire after the retention window
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
output "bucket_arn" { value = aws_s3_bucket.dr.arn }
