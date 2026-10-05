# Uses the admin's local AWS profile for the account (aws sso login --profile <profile>).
locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
}

generate "provider_aws" {
  path      = "provider_aws.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region              = "us-east-1"
      profile             = "${local.account.profile}"
      allowed_account_ids = ["${local.account.account_id}"]
    }
  EOF
}
