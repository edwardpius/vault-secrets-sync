# Destination account: the role the sync Lambda assumes. It can only create secrets under
# vault/* that carry managed-by=vault-secrets-sync, and only touch secrets with that tag.
# It cannot read secret values.

terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_caller_identity" "this" {}

locals {
  managed_tag      = "managed-by"
  managed_value    = "vault-secrets-sync"
  allowed_tag_keys = ["managed-by", "vault-namespace", "vault-mount", "vault-path", "vault-version"]
  secret_arns = [
    for r in var.regions : "arn:aws:secretsmanager:${r}:${data.aws_caller_identity.this.account_id}:secret:${var.secret_name_prefix}*"
  ]
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.lambda_role_arn]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.role_name
  description          = "Assumed by the Vault secrets sync Lambda in the hub account"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
  tags                 = var.tags
}

data "aws_iam_policy_document" "this" {
  statement {
    sid       = "CreateOnlyTaggedSecrets"
    actions   = ["secretsmanager:CreateSecret"]
    resources = local.secret_arns
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.managed_tag}"
      values   = [local.managed_value]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = local.allowed_tag_keys
    }
  }

  statement {
    sid       = "TagOnCreate"
    actions   = ["secretsmanager:TagResource"]
    resources = local.secret_arns
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.managed_tag}"
      values   = [local.managed_value]
    }
  }

  statement {
    sid = "ManageOnlyTaggedSecrets"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:TagResource",
      "secretsmanager:DeleteSecret",
      "secretsmanager:RestoreSecret",
    ]
    resources = local.secret_arns
    condition {
      test     = "StringEquals"
      variable = "secretsmanager:ResourceTag/${local.managed_tag}"
      values   = [local.managed_value]
    }
  }

  # Lets the Lambda see an existing untagged secret and refuse to overwrite it.
  statement {
    sid       = "DescribeForSafetyCheck"
    actions   = ["secretsmanager:DescribeSecret"]
    resources = local.secret_arns
  }

  statement {
    sid       = "ListSecrets"
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = length(var.kms_key_arns) > 0 ? [1] : []
    content {
      sid       = "UseCustomerManagedKeys"
      actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
      resources = var.kms_key_arns
      condition {
        test     = "StringLike"
        variable = "kms:ViaService"
        values   = [for r in var.regions : "secretsmanager.${r}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = var.role_name
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}

output "role_arn" {
  value = aws_iam_role.this.arn
}
