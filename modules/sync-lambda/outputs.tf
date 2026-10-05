output "lambda_role_arn" {
  description = "Principal trusted by the target roles and bound as the Vault JWT subject."
  value       = aws_iam_role.lambda.arn
}

output "issuer_url" {
  description = "This account's AWS token issuer; Vault's JWT auth uses it for OIDC discovery."
  value       = local.issuer_url
}

output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "config_parameter" {
  value = aws_ssm_parameter.config.name
}
