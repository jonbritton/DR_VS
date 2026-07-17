terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# The immutable DR bucket — destination for BOTH the 
# direct-to-S3 backup and the File Gateway variant
module "dr_bup" {
  source               = "./modules/dr-bup"
  name_prefix          = var.name_prefix
  account_id           = var.account_id
  tags                 = var.tags
  allowed_source_cidrs = var.allowed_source_cidrs
}

# The File Gateway variant's infrastructure. Off by default: the direct-to-S3
# path needs only the bucket above. Flip enable_file_gateway=true (and set the
# gateway_ip_address / cache_disk_path / client_cidrs vars) to stand up the NFS
# share in front of the same bucket.
module "storage_gateway" {
  source = "./modules/storage-gateway"
  count  = var.enable_file_gateway ? 1 : 0

  name_prefix        = var.name_prefix
  bucket_id          = module.dr_bup.bucket
  bucket_arn         = module.dr_bup.bucket_arn
  gateway_ip_address = var.gateway_ip_address
  cache_disk_path    = var.cache_disk_path
  client_cidrs       = var.client_cidrs
}
