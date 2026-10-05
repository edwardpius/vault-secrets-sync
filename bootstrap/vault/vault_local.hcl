# Uses VAULT_TOKEN from the environment (an admin token generated in the HCP portal).
locals {
  common = read_terragrunt_config("${get_repo_root()}/live/common.hcl").locals
}

generate "provider_vault" {
  path      = "provider_vault.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "vault" {
      address   = "${local.common.vault_addr}"
      namespace = "${local.common.vault_namespace}"
    }
  EOF
}
