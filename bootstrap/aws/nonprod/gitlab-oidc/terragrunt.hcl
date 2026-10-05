include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "aws" {
  path = find_in_parent_folders("aws_local.hcl")
}

terraform {
  source = "${get_repo_root()}/modules//gitlab-oidc-aws"
}

inputs = {
  project_path         = include.root.locals.project_path
  create_oidc_provider = true # false if the account already trusts gitlab.com
  state_bucket_arn     = "arn:aws:s3:::${include.root.locals.common.state_bucket}"
  state_kms_key_arn    = include.root.locals.common.state_kms_key_arn
  tags                 = { owner = "platform", service = "vault-secrets-sync" }
}
