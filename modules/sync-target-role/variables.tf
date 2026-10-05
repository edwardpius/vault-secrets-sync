variable "lambda_role_arn" {
  description = "ARN of the sync Lambda's execution role in the hub account."
  type        = string
}

variable "role_name" {
  description = "Must match target_role_name in the sync-lambda module."
  type        = string
  default     = "vault-secrets-sync"
}

variable "regions" {
  description = "Regions in this account that receive synced secrets."
  type        = list(string)
  validation {
    condition     = length(var.regions) > 0
    error_message = "At least one region is required."
  }
}

variable "secret_name_prefix" {
  description = "Prefix of synced secret names."
  type        = string
  default     = "vault/"
}

variable "kms_key_arns" {
  description = "Customer managed KMS keys used for synced secrets (empty = aws/secretsmanager)."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
