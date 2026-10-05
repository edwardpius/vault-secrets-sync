variable "login_namespace" {
  description = "Namespace the provider and the auth mount live in (HCP: admin)."
  type        = string
  default     = "admin"
}

variable "auth_mount" {
  type    = string
  default = "aws-sts"
}

variable "role_name" {
  type    = string
  default = "vault-secrets-sync"
}

variable "aws_issuer_url" {
  description = "issuer_url output of the sync-lambda unit."
  type        = string
}

variable "lambda_role_arn" {
  description = "lambda_role_arn output of the sync-lambda unit; matched against the token's sub claim."
  type        = string
}

variable "audience" {
  description = "Must equal vault_audience in the sync-lambda unit."
  type        = string
}

variable "sources" {
  description = "The sources list from config/sync-targets.json."
  type = list(object({
    namespace    = string
    mount        = string
    secrets      = list(string)
    destinations = list(string)
  }))

  validation {
    condition = alltrue([
      for s in var.sources : s.namespace == var.login_namespace || startswith(s.namespace, "${var.login_namespace}/")
    ])
    error_message = "Every source namespace must be the login namespace or one of its children."
  }
}

variable "lambda_egress_cidrs" {
  description = "Optional CIDRs the Lambda reaches Vault from (NAT EIP or VPC range); empty allows any."
  type        = list(string)
  default     = []
}
