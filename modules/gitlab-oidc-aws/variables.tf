variable "project_path" {
  description = "GitLab.com project path, e.g. platform/vault-secrets-sync."
  type        = string
}

variable "apply_branch" {
  type    = string
  default = "main"
}

variable "role_prefix" {
  type    = string
  default = "gitlab-vault-secrets-sync"
}

variable "create_oidc_provider" {
  description = "False if the account already has an IAM OIDC provider for gitlab.com."
  type        = bool
  default     = true
}

variable "state_bucket_arn" {
  type = string
}

variable "state_kms_key_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
