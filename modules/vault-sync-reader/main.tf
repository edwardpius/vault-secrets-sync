# Vault side: a JWT auth mount that trusts the hub AWS account's outbound-federation issuer,
# a role bound to the sync Lambda's IAM role, and a read-only policy limited to the configured
# secrets. The policy lives in the login namespace (admin) and reaches child namespaces by prefix,
# so one login reads secrets from admin and any namespace beneath it.

terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.12"
    }
  }
}

locals {
  # Path prefix of each source namespace relative to the login namespace:
  # "admin" -> "", "admin/team-a" -> "team-a/".
  read_paths = distinct(flatten([
    for s in var.sources : [
      for secret in s.secrets : format(
        "%s%s/data/%s",
        s.namespace == var.login_namespace ? "" : "${trimprefix(s.namespace, "${var.login_namespace}/")}/",
        s.mount,
        secret,
      )
    ]
  ]))
}

resource "vault_jwt_auth_backend" "aws" {
  path               = var.auth_mount
  type               = "jwt"
  description        = "AWS IAM outbound identity federation (sts:GetWebIdentityToken) from the hub account"
  oidc_discovery_url = var.aws_issuer_url
  bound_issuer       = var.aws_issuer_url
  jwt_supported_algs = ["RS256", "ES384"]
}

resource "vault_jwt_auth_backend_role" "sync" {
  backend           = vault_jwt_auth_backend.aws.path
  role_name         = var.role_name
  role_type         = "jwt"
  user_claim        = "sub" # one entity, so one Vault client, for the Lambda role
  bound_subject     = var.lambda_role_arn
  bound_audiences   = [var.audience]
  token_policies    = [vault_policy.reader.name]
  token_ttl         = 300
  token_max_ttl     = 600
  token_bound_cidrs = var.lambda_egress_cidrs
}

resource "vault_policy" "reader" {
  name = var.role_name
  policy = join("\n", [
    for p in local.read_paths : "path \"${p}\" {\n  capabilities = [\"read\"]\n}\n"
  ])
}
