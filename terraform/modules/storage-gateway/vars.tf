variable "name_prefix" {
  type        = string
  description = "Shared prefix for named resources, e.g. render-farm-dev"
}

variable "bucket_id" {
  type        = string
  description = "Name of the existing DR bucket (output `bucket` from the dr-bup module)"
}

variable "bucket_arn" {
  type        = string
  description = "ARN of the existing DR bucket"
}

variable "gateway_ip_address" {
  type        = string
  description = "Reachable IP of the running File Gateway"
}

variable "client_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to mount the NFS share"
}

output "file_share_arn" {
  description = "Pass to the backup host as FILE_SHARE_ARN"
  value       = aws_storagegateway_nfs_file_share.dr.arn
}

output "nfs_export" {
  description = "Mount target for the backup host: <gateway-ip>:/<bucket>"
  value       = "${var.gateway_ip_address}:/${var.bucket_id}"
}
