include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "vault" {
  path = find_in_parent_folders("vault_local.hcl")
}

terraform {
  source = "${get_repo_root()}/modules//vault-gitlab-jwt"
}

inputs = {
  project_path = include.root.locals.project_path
  audience     = include.root.locals.common.vault_addr # must match TERRAFORM_VAULT_AUTH_JWT aud in .gitlab-ci.yml
}
