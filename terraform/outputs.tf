output "bucket" {
  description = "Name of the DR bucket"
  value       = module.dr_bup.bucket
}

output "file_share_arn" {
  description = "FILE_SHARE_ARN for the backup host (null unless enable_file_gateway)"
  value       = try(module.storage_gateway[0].file_share_arn, null)
}

output "nfs_export" {
  description = "NFS mount target for the backup host (null unless enable_file_gateway)"
  value       = try(module.storage_gateway[0].nfs_export, null)
}
