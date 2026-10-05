# Vault (admin namespace): lets GitLab.com jobs log in with their id_token.
#   vault-secrets-sync-plan  : any ref of the project; read-only on what Terraform manages
#   vault-secrets-sync-apply : protected main only; manages the aws-sts mount and the reader policy
# Neither role can read secret values. Applied once by an admin from bootstrap/.

terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.12"
    }
  }
}

resource "vault_jwt_auth_backend" "gitlab" {
  path               = var.auth_mount
  type               = "jwt"
  description        = "GitLab.com CI id_tokens"
  oidc_discovery_url = "https://gitlab.com"
  bound_issuer       = "https://gitlab.com"
}

resource "vault_policy" "plan" {
  name   = "vault-secrets-sync-plan"
  policy = <<-EOT
    path "sys/auth"                                  { capabilities = ["read"] }
    path "sys/mounts/auth/${var.managed_auth_mount}/tune" { capabilities = ["read"] }
    path "auth/${var.managed_auth_mount}/config"     { capabilities = ["read"] }
    path "auth/${var.managed_auth_mount}/role/*"     { capabilities = ["read", "list"] }
    path "sys/policies/acl/vault-secrets-sync"       { capabilities = ["read"] }
  EOT
}

resource "vault_policy" "apply" {
  name   = "vault-secrets-sync-apply"
  policy = <<-EOT
    path "sys/auth"                                  { capabilities = ["read"] }
    path "sys/auth/${var.managed_auth_mount}"        { capabilities = ["create", "read", "update", "delete", "sudo"] }
    path "sys/mounts/auth/${var.managed_auth_mount}" { capabilities = ["read", "update"] }
    path "sys/mounts/auth/${var.managed_auth_mount}/tune" { capabilities = ["read", "update"] }
    path "auth/${var.managed_auth_mount}/*"          { capabilities = ["create", "read", "update", "delete", "list"] }
    path "sys/policies/acl/vault-secrets-sync"       { capabilities = ["create", "read", "update", "delete"] }
  EOT
}

resource "vault_jwt_auth_backend_role" "plan" {
  backend           = vault_jwt_auth_backend.gitlab.path
  role_name         = "vault-secrets-sync-plan"
  role_type         = "jwt"
  user_claim        = "project_path" # one entity (one client) for every pipeline
  bound_audiences   = [var.audience]
  bound_claims_type = "string"
  bound_claims      = { project_path = var.project_path }
  token_policies    = [vault_policy.plan.name]
  token_ttl         = 1800
  token_max_ttl     = 3600
}

resource "vault_jwt_auth_backend_role" "apply" {
  backend           = vault_jwt_auth_backend.gitlab.path
  role_name         = "vault-secrets-sync-apply"
  role_type         = "jwt"
  user_claim        = "project_path"
  bound_audiences   = [var.audience]
  bound_claims_type = "string"
  bound_claims = {
    project_path  = var.project_path
    ref           = var.apply_branch
    ref_type      = "branch"
    ref_protected = "true"
  }
  token_policies = [vault_policy.apply.name]
  token_ttl      = 1800
  token_max_ttl  = 3600
}
