include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "aws" {
  path = find_in_parent_folders("aws.hcl")
}

locals {
  common  = read_terragrunt_config(find_in_parent_folders("common.hcl")).locals
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
  # Regions this account receives secrets in, derived from config/sync-targets.json.
  regions = distinct([
    for d in values(local.common.sync_config.destinations) : d.region if d.account_id == local.account.account_id
  ])
  kms_key_arns = compact([
    for d in values(local.common.sync_config.destinations) : try(d.kms_key_id, "") if d.account_id == local.account.account_id
  ])
}

terraform {
  source = "${get_repo_root()}/modules//sync-target-role"
}

dependency "sync_lambda" {
  config_path = "../../../security/us-east-1/sync-lambda"
  mock_outputs = {
    lambda_role_arn = "arn:aws:iam::111111111111:role/vault-secrets-sync-lambda"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

inputs = {
  lambda_role_arn = dependency.sync_lambda.outputs.lambda_role_arn
  regions         = local.regions
  kms_key_arns    = local.kms_key_arns
  tags            = { owner = "platform", service = "vault-secrets-sync" }
}
