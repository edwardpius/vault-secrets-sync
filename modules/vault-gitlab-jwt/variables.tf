variable "project_path" {
  description = "GitLab.com project path, e.g. platform/vault-secrets-sync."
  type        = string
}

variable "audience" {
  description = "aud of the TERRAFORM_VAULT_AUTH_JWT id_token in .gitlab-ci.yml."
  type        = string
}

variable "apply_branch" {
  type    = string
  default = "main"
}

variable "auth_mount" {
  type    = string
  default = "gitlab-jwt"
}

variable "managed_auth_mount" {
  description = "The auth mount the pipeline manages (vault-sync-reader auth_mount)."
  type        = string
  default     = "aws-sts"
}
