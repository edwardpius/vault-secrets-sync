include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "aws" {
  path = find_in_parent_folders("aws.hcl")
}

locals {
  common = read_terragrunt_config(find_in_parent_folders("common.hcl")).locals
}

terraform {
  source = "${get_repo_root()}/modules//sync-lambda"
}

inputs = {
  sync_config     = local.common.sync_config
  lambda_zip_path = "${get_repo_root()}/dist/vault-secrets-sync.zip"
  vault_addr      = local.common.vault_addr
  vault_namespace = local.common.vault_namespace
  vault_audience  = local.common.vault_audience

  # First apply: false. Flip to true once live/vault/admin/sync-reader is applied.
  schedule_enabled = true

  # Reach HCP Vault privately (HVN peering/TGW) or through a NAT with a fixed EIP on its ip_allowlist.
  subnet_ids         = []
  security_group_ids = []

  alarm_sns_topic_arn = null
  tags                = { owner = "platform", service = "vault-secrets-sync" }
}
