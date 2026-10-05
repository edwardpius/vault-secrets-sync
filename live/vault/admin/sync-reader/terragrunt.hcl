include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "vault" {
  path = find_in_parent_folders("vault.hcl")
}

locals {
  common = read_terragrunt_config(find_in_parent_folders("common.hcl")).locals
}

terraform {
  source = "${get_repo_root()}/modules//vault-sync-reader"
}

dependency "sync_lambda" {
  config_path = "../../../aws/security/us-east-1/sync-lambda"
  mock_outputs = {
    lambda_role_arn = "arn:aws:iam::111111111111:role/vault-secrets-sync-lambda"
    issuer_url      = "https://00000000-0000-0000-0000-000000000000.tokens.sts.global.api.aws"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
}

inputs = {
  login_namespace = local.common.vault_namespace
  aws_issuer_url  = dependency.sync_lambda.outputs.issuer_url
  lambda_role_arn = dependency.sync_lambda.outputs.lambda_role_arn
  audience        = local.common.vault_audience
  sources         = local.common.sync_config.sources

  # NAT EIP(s) or VPC CIDR the Lambda reaches Vault from; empty = any source address.
  lambda_egress_cidrs = []
}
