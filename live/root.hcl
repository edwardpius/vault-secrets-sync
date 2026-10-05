locals {
  common = read_terragrunt_config("${get_parent_terragrunt_dir()}/common.hcl").locals
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket       = local.common.state_bucket
    key          = "live/${path_relative_to_include()}/terraform.tfstate"
    region       = local.common.state_region
    encrypt      = true
    kms_key_id   = local.common.state_kms_key_arn
    use_lockfile = true
  }
}
