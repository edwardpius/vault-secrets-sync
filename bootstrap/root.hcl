# One-time setup an admin applies from a laptop with their own credentials.
# CI never runs this tree: it creates the identities CI itself uses.
locals {
  common = read_terragrunt_config("${get_repo_root()}/live/common.hcl").locals
  # GitLab.com project path that may deploy
  project_path = "CHANGE-ME-group/vault-secrets-sync"
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket       = local.common.state_bucket
    key          = "bootstrap/${path_relative_to_include()}/terraform.tfstate"
    region       = local.common.state_region
    encrypt      = true
    kms_key_id   = local.common.state_kms_key_arn
    use_lockfile = true
  }
}
