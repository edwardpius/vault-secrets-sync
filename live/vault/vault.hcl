# Generates a Vault provider that logs in to the admin namespace with the job's id_token
# (TERRAFORM_VAULT_AUTH_JWT). MR pipelines set TG_VAULT_ROLE=vault-secrets-sync-plan.
locals {
  common = read_terragrunt_config(find_in_parent_folders("common.hcl")).locals
}

generate "provider_vault" {
  path      = "provider_vault.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "vault" {
      address          = "${local.common.vault_addr}"
      namespace        = "${local.common.vault_namespace}"
      skip_child_token = true
      auth_login_jwt {
        namespace = "${local.common.vault_namespace}"
        mount     = "gitlab-jwt"
        role      = "${get_env("TG_VAULT_ROLE", "vault-secrets-sync-apply")}"
      }
    }
  EOF
}
