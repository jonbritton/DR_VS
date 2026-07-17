variable "name_prefix" { type = string }
variable "account_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

variable "allowed_source_cidrs" {
  type        = list(string)
  description = "Site egress CIDRs the write-only backup identity may call from; empty disables the restriction. With long-lived keys on an on-prem host and no VPN, pin this to the site's public IPs."
  default     = []
}

data "aws_iam_policy_document" "backup_writer" {
  statement {
    sid       = "WriteBackups"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.dr.arn}/*"]

    dynamic "condition" {
      for_each = length(var.allowed_source_cidrs) > 0 ? [1] : []
      content {
        test     = "IpAddress"
        variable = "aws:SourceIp"
        values   = var.allowed_source_cidrs
      }
    }
  }
  statement {
    sid       = "ListForSanity"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.dr.arn]

    dynamic "condition" {
      for_each = length(var.allowed_source_cidrs) > 0 ? [1] : []
      content {
        test     = "IpAddress"
        variable = "aws:SourceIp"
        values   = var.allowed_source_cidrs
      }
    }
  }
  # No s3:DeleteObject, no s3:PutBucketPolicy, no version operations
}

resource "aws_iam_policy" "backup_writer" {
  name   = "${var.name_prefix}-dr-backup-writer"
  policy = data.aws_iam_policy_document.backup_writer.json
}

# Read-only restore identity — a different principal from the writer, so the
# host doing backups can never read (or exfiltrate) the archive, and the
# identity doing restores can never write to it. Deliberately NOT IP-pinned:
# a real disaster may take the site (and its egress IPs) with it, and restore
# must still work from wherever recovery happens.
data "aws_iam_policy_document" "restore_reader" {
  statement {
    sid    = "ReadBackups"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:RestoreObject", # thaw snapshots that have aged into Deep Archive
    ]
    resources = ["${aws_s3_bucket.dr.arn}/*"]
  }
  statement {
    sid       = "ListForResolve"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.dr.arn]
  }
}

resource "aws_iam_policy" "restore_reader" {
  name   = "${var.name_prefix}-dr-restore-reader"
  policy = data.aws_iam_policy_document.restore_reader.json
}
