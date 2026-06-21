# S3 File Gateway in front of the existing DR bucket.
#
# The backup host writes files to an NFS share this gateway exports; the gateway
# uploads them to s3://<bucket>/core/<stamp>/. The Glacier Deep Archive step is
# the bucket lifecycle already defined in terraform/modules/dr-bup (Standard ->
# STANDARD_IA @30d -> DEEP_ARCHIVE @90d). File Gateway cannot write directly to a
# Glacier class, so the share stays on a readable class and lifecycle does the
# archiving — keeping the newest snapshots instantly readable through the share,
# while old ones age into Deep Archive.

resource "aws_iam_role" "fgw" {
  name               = "${var.name_prefix}-dr-fgw"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["storagegateway.amazonaws.com"]
    }
  }
}

# The gateway owns the namespace, so it needs full object management
# on the bucket. Note the diff from the direct-to-S3
# variant: immutability here comes from bucket Versioning, 
# NOT from a write-only principal — the gateway role *can* delete.
data "aws_iam_policy_document" "fgw_s3" {
  statement {
    sid       = "List"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
    resources = [var.bucket_arn]
  }
  statement {
    sid = "Objects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObjectVersion",
      "s3:GetObjectAcl",
      "s3:PutObjectAcl",
    ]
    resources = ["${var.bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "fgw_s3" {
  name   = "${var.name_prefix}-dr-fgw-s3"
  role   = aws_iam_role.fgw.id
  policy = data.aws_iam_policy_document.fgw_s3.json
}

# pulls the activation key from this address.
resource "aws_storagegateway_gateway" "fgw" {
  gateway_name       = "${var.name_prefix}-dr-fgw"
  gateway_timezone   = "GMT"
  gateway_type       = "FILE_S3"
  gateway_ip_address = var.gateway_ip_address
}

# NFS share mapped to the bucket root, so writes under core/<stamp>/ land at the
# same keys the direct-to-S3 variant uses (restore tooling is unchanged).
resource "aws_storagegateway_nfs_file_share" "dr" {
  gateway_arn  = aws_storagegateway_gateway.fgw.arn
  location_arn = var.bucket_arn
  role_arn     = aws_iam_role.fgw.arn
  client_list  = var.client_cidrs

  # MUST be a readable class — Glacier/Deep Archive are not valid
  default_storage_class = "S3_STANDARD"
  object_acl            = "bucket-owner-full-control"
  squash                = "RootSquash"
  read_only             = false

  cache_attributes {
    cache_stale_timeout_in_seconds = 300
  }
}
