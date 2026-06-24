data "aws_iam_policy_document" "backup_writer" {
  statement {
    sid       = "WriteBackups"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.dr.arn}/*"]
  }
  statement {
    sid       = "ListForSanity"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.dr.arn]
  }
  # No s3:DeleteObject, no s3:PutBucketPolicy, no version operations
}

resource "aws_iam_policy" "backup_writer" {
  name   = "${var.name_prefix}-dr-backup-writer"
  policy = data.aws_iam_policy_document.backup_writer.json
}