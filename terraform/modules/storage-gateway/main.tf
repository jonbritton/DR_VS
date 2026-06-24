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

# The full set of bucket/object actions AWS requires for an S3 File Gateway role,
# including the multipart-upload actions the gateway uses for large files (a
# multi-GB mongodump is uploaded in parts — without these, big uploads fail).
# Two deliberate notes on the immutability story:
#   - it comes from bucket Versioning, NOT a write-only principal: the gateway
#     *can* DeleteObject, but on a versioned bucket that only writes a delete
#     marker, so prior versions survive and a snapshot is recoverable.
#   - we deliberately OMIT s3:DeleteObjectVersion (it is in AWS's sample policy):
#     granting it would let this principal permanently destroy version history
#     and defeat the one mechanism protecting these backups.
data "aws_iam_policy_document" "fgw_s3" {
  statement {
    sid = "List"
    actions = [
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [var.bucket_arn]
  }
  statement {
    sid = "Objects"
    actions = [
      "s3:GetObject",
      "s3:GetObjectAcl",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
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

# A File Gateway must have a local disk allocated as cache before it can serve a
# file share — without this, share creation fails. The disk is a block device
# attached to the gateway VM (var.cache_disk_path, e.g. /dev/sdb).
data "aws_storagegateway_local_disk" "cache" {
  gateway_arn = aws_storagegateway_gateway.fgw.arn
  disk_path   = var.cache_disk_path
}

resource "aws_storagegateway_cache" "cache" {
  gateway_arn = aws_storagegateway_gateway.fgw.arn
  disk_id     = data.aws_storagegateway_local_disk.cache.disk_id
}

# NFS share mapped to the bucket root, so writes under core/<stamp>/ land at the
# same keys the direct-to-S3 variant uses (restore tooling is unchanged).
resource "aws_storagegateway_nfs_file_share" "dr" {
  # the cache must be allocated and the role must carry its S3 policy before the
  # gateway will accept (and validate) a new share.
  depends_on   = [aws_storagegateway_cache.cache, aws_iam_role_policy.fgw_s3]
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
