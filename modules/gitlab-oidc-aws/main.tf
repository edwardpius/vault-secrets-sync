# One per AWS account the pipeline touches. Lets GitLab.com jobs assume:
#   <prefix>-plan  : any branch of the project, read-only (+ state lock files)
#   <prefix>-apply : protected main branch only, scoped write
# Applied once by an admin from bootstrap/ (CI cannot create its own trust).

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
  issuer_host = "gitlab.com"
  account_id  = data.aws_caller_identity.this.account_id
}

resource "aws_iam_openid_connect_provider" "gitlab" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://${local.issuer_host}"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.gitlab[0].arn : "arn:aws:iam::${local.account_id}:oidc-provider/${local.issuer_host}"
}

data "aws_iam_policy_document" "trust" {
  for_each = {
    plan  = "project_path:${var.project_path}:ref_type:*"
    apply = "project_path:${var.project_path}:ref_type:branch:ref:${var.apply_branch}"
  }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "${local.issuer_host}:sub"
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "ci" {
  for_each             = data.aws_iam_policy_document.trust
  name                 = "${var.role_prefix}-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
  tags                 = var.tags
}

# State access for both roles: plan needs to write the S3 lock file.
data "aws_iam_policy_document" "state" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [var.state_bucket_arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.state_bucket_arn}/*"]
  }
  statement {
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [var.state_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "state" {
  for_each = aws_iam_role.ci
  name     = "terraform-state"
  role     = each.value.id
  policy   = data.aws_iam_policy_document.state.json
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.ci["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess" # does not include secretsmanager:GetSecretValue
}

# Apply: only what the sync-lambda and sync-target-role modules manage.
data "aws_iam_policy_document" "apply" {
  statement {
    sid = "IamForSyncRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:ListInstanceProfilesForRole", "iam:PassRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/vault-secrets-sync*"]
  }
  statement {
    sid = "OutboundFederation"
    actions = [
      "iam:EnableOutboundWebIdentityFederation",
      "iam:DisableOutboundWebIdentityFederation",
      "iam:GetOutboundWebIdentityFederationInfo",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "Lambda"
    actions   = ["lambda:*"]
    resources = ["arn:aws:lambda:*:${local.account_id}:function:vault-secrets-sync*"]
  }
  statement {
    sid       = "Scheduler"
    actions   = ["scheduler:*"]
    resources = ["arn:aws:scheduler:*:${local.account_id}:schedule/default/vault-secrets-sync*"]
  }
  statement {
    sid       = "ConfigParameter"
    actions   = ["ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource"]
    resources = ["arn:aws:ssm:*:${local.account_id}:parameter/vault-secrets-sync/*"]
  }
  statement {
    sid       = "SsmDescribe"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource"]
    resources = ["arn:aws:logs:*:${local.account_id}:log-group:/aws/lambda/vault-secrets-sync*"]
  }
  statement {
    sid       = "LogsDescribe"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
  statement {
    sid       = "Alarms"
    actions   = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:TagResource", "cloudwatch:UntagResource"]
    resources = ["arn:aws:cloudwatch:*:${local.account_id}:alarm:vault-secrets-sync*"]
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "vault-secrets-sync-apply"
  role   = aws_iam_role.ci["apply"].id
  policy = data.aws_iam_policy_document.apply.json
}

resource "aws_iam_role_policy_attachment" "apply_readonly" {
  role       = aws_iam_role.ci["apply"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
