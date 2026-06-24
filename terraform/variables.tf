variable "aws_region" {
  type        = string
  description = "AWS region for the DR bucket and (optional) File Gateway"
  default     = "us-west-2"
}

variable "name_prefix" {
  type        = string
  description = "Shared prefix for named resources, e.g. render-farm-dev"
}

variable "account_id" {
  type        = string
  description = "AWS account id — makes the bucket name globally unique"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the DR bucket"
  default     = {}
}

variable "enable_file_gateway" {
  type        = bool
  description = "Stand up the S3 File Gateway variant alongside the bucket"
  default     = false
}

#=--- only consumed when enable_file_gateway = true

variable "gateway_ip_address" {
  type        = string
  description = "Reachable IP of the running File Gateway appliance"
  default     = ""
}

variable "cache_disk_path" {
  type        = string
  description = "Block device on the gateway VM to dedicate as cache, e.g. /dev/sdb"
  default     = ""
}

variable "client_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to mount the NFS share"
  default     = []
}
