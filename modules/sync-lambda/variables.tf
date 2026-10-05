variable "name" {
  description = "Name for the Lambda function and related resources."
  type        = string
  default     = "vault-secrets-sync"
}

variable "sync_config" {
  description = "Contents of config/sync-targets.json: destinations and sources."
  type = object({
    destinations = map(object({
      account_id = string
      region     = string
      kms_key_id = optional(string)
    }))
    sources = list(object({
      namespace    = string
      mount        = string
      secrets      = list(string)
      destinations = list(string)
    }))
  })

  validation {
    condition = alltrue(flatten([
      for s in var.sync_config.sources : [for d in s.destinations : contains(keys(var.sync_config.destinations), d)]
    ]))
    error_message = "Every source destination must be defined under destinations."
  }
}

variable "lambda_zip_path" {
  description = "Path to dist/vault-secrets-sync.zip built by scripts/build_lambda.sh."
  type        = string
}

variable "vault_addr" {
  description = "HCP Vault Dedicated address, e.g. https://vault-cluster.vault.xxxx.aws.hashicorp.cloud:8200."
  type        = string
}

variable "vault_namespace" {
  description = "Namespace that holds the JWT auth mount."
  type        = string
  default     = "admin"
}

variable "vault_auth_mount" {
  description = "Path of the Vault JWT auth mount that trusts this AWS account's issuer."
  type        = string
  default     = "aws-sts"
}

variable "vault_role" {
  description = "Vault JWT role the Lambda logs in with."
  type        = string
  default     = "vault-secrets-sync"
}

variable "vault_audience" {
  description = "Audience for the AWS web identity token; must match the Vault role's bound_audiences."
  type        = string
}

variable "target_role_name" {
  description = "Name of the role in each destination account."
  type        = string
  default     = "vault-secrets-sync"
}

variable "enable_outbound_federation" {
  description = "Create the account-level outbound identity federation switch. Set false if another stack owns it."
  type        = bool
  default     = true
}

variable "schedule_expression" {
  description = "EventBridge Scheduler expression."
  type        = string
  default     = "rate(1 minute)"
}

variable "schedule_enabled" {
  description = "Turn the schedule on. Keep false until the Vault reader unit is applied."
  type        = bool
  default     = true
}

variable "timeout_seconds" {
  description = "Lambda timeout. Keep below the schedule interval."
  type        = number
  default     = 55
}

variable "recovery_window_days" {
  description = "Recovery window when a synced secret is deleted in AWS (7-30)."
  type        = number
  default     = 7
  validation {
    condition     = var.recovery_window_days >= 7 && var.recovery_window_days <= 30
    error_message = "Secrets Manager accepts 7 to 30 days."
  }
}

variable "subnet_ids" {
  description = "Private subnets for the Lambda when Vault is reached privately (HVN peering/TGW) or via a NAT with a fixed EIP."
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "Security groups for the Lambda when subnet_ids is set."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic for alarms; null disables notifications."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
