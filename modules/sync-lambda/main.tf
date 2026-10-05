# Hub account: the scheduled Lambda that pulls from Vault and pushes to Secrets Manager.
# Identity chain: Lambda role -> sts:GetWebIdentityToken -> Vault JWT auth -> short-lived Vault token.

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
data "aws_region" "this" {}

locals {
  config_json = jsonencode(var.sync_config)
  target_role_arns = distinct([
    for d in values(var.sync_config.destinations) : "arn:aws:iam::${d.account_id}:role/${var.target_role_name}"
  ])
  issuer_url = var.enable_outbound_federation ? aws_iam_outbound_web_identity_federation.this[0].issuer_identifier : data.aws_iam_outbound_web_identity_federation.existing[0].issuer_identifier
}

# Account-level switch. Deleting this resource disables outbound federation for the whole account,
# so set enable_outbound_federation = false if another stack already owns it.
resource "aws_iam_outbound_web_identity_federation" "this" {
  count = var.enable_outbound_federation ? 1 : 0

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_outbound_web_identity_federation" "existing" {
  count = var.enable_outbound_federation ? 0 : 1
}

resource "aws_ssm_parameter" "config" {
  name        = "/${var.name}/config"
  description = "Which Vault secrets sync to which AWS destinations (no secret values)"
  type        = "String"
  tier        = length(local.config_json) > 4096 ? "Advanced" : "Standard"
  value       = local.config_json
  tags        = var.tags
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.this.account_id]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name                 = "${var.name}-lambda"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  max_session_duration = 3600
  tags                 = var.tags
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "VaultLoginToken"
    actions   = ["sts:GetWebIdentityToken"]
    resources = ["*"]
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "sts:IdentityTokenAudience"
      values   = [var.vault_audience]
    }
    condition {
      test     = "NumericLessThanEquals"
      variable = "sts:DurationSeconds"
      values   = ["300"]
    }
  }

  statement {
    sid       = "AssumeTargetRoles"
    actions   = ["sts:AssumeRole"]
    resources = local.target_role_arns
  }

  statement {
    sid       = "ReadConfig"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.config.arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.name}-lambda"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_iam_role_policy_attachment" "vpc" {
  count      = length(var.subnet_ids) > 0 ? 1 : 0
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "this" {
  function_name    = var.name
  description      = "Sync Vault KV v2 secrets to AWS Secrets Manager"
  role             = aws_iam_role.lambda.arn
  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)
  handler          = "vault_secrets_sync.handler.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = var.timeout_seconds
  # One run at a time: overlapping runs could race on create/delete.
  reserved_concurrent_executions = 1

  environment {
    variables = {
      VAULT_ADDR            = var.vault_addr
      VAULT_NAMESPACE       = var.vault_namespace
      VAULT_AUTH_MOUNT      = var.vault_auth_mount
      VAULT_ROLE            = var.vault_role
      VAULT_AUDIENCE        = var.vault_audience
      SYNC_CONFIG_PARAMETER = aws_ssm_parameter.config.name
      TARGET_ROLE_NAME      = var.target_role_name
      RECOVERY_WINDOW_DAYS  = tostring(var.recovery_window_days)
    }
  }

  dynamic "vpc_config" {
    for_each = length(var.subnet_ids) > 0 ? [1] : []
    content {
      subnet_ids         = var.subnet_ids
      security_group_ids = var.security_group_ids
    }
  }

  depends_on = [aws_cloudwatch_log_group.this, aws_iam_role_policy.lambda]
  tags       = var.tags
}

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.this.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "scheduler" {
  name = "invoke-${var.name}"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.this.arn
    }]
  })
}

resource "aws_scheduler_schedule" "this" {
  name                = var.name
  schedule_expression = var.schedule_expression
  state               = var.schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.this.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "schedule" })

    retry_policy {
      maximum_retry_attempts = 0 # the next scheduled run is the retry
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${var.name}-errors"
  alarm_description   = "Vault to Secrets Manager sync failed 3 times in 5 minutes"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.this.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_sns_topic_arn == null ? [] : [var.alarm_sns_topic_arn]
  ok_actions          = var.alarm_sns_topic_arn == null ? [] : [var.alarm_sns_topic_arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "not_running" {
  alarm_name          = "${var.name}-not-running"
  alarm_description   = "Vault to Secrets Manager sync has not run for 15 minutes"
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = aws_lambda_function.this.function_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = var.schedule_enabled ? "breaching" : "notBreaching"
  alarm_actions       = var.alarm_sns_topic_arn == null ? [] : [var.alarm_sns_topic_arn]
  tags                = var.tags
}
