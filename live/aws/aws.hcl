# Generates an AWS provider that assumes this account's GitLab CI role with the job's id_token
# (TF_AWS_WEB_IDENTITY_TOKEN). MR pipelines set TG_AWS_ROLE_SUFFIX=plan.
locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
  region  = try(read_terragrunt_config(find_in_parent_folders("region.hcl")).locals.region, "us-east-1")
  role    = "gitlab-vault-secrets-sync-${get_env("TG_AWS_ROLE_SUFFIX", "apply")}"
}

generate "provider_aws" {
  path      = "provider_aws.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region              = "${local.region}"
      allowed_account_ids = ["${local.account.account_id}"]
      assume_role_with_web_identity {
        role_arn     = "arn:aws:iam::${local.account.account_id}:role/${local.role}"
        session_name = "gitlab-${get_env("CI_PIPELINE_ID", "local")}"
      }
      default_tags {
        tags = { managed-by = "terraform", repo = "vault-secrets-sync" }
      }
    }
  EOF
}
