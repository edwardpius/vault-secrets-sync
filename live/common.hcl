# Edit these once. Every unit reads them.
locals {
  state_bucket      = "CHANGE-ME-tfstate-vault-secrets-sync"
  state_region      = "us-east-1"
  state_kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/CHANGE-ME"

  vault_addr      = "https://CHANGE-ME.vault.xxxx.aws.hashicorp.cloud:8200"
  vault_namespace = "admin"
  # aud of the AWS web identity token the Lambda presents to Vault
  vault_audience = "vault-secrets-sync"

  hub_account_id = "111111111111"
  hub_region     = "us-east-1"

  sync_config = jsondecode(file("${get_repo_root()}/config/sync-targets.json"))
}
