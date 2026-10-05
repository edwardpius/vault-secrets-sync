output "policy" {
  description = "Rendered read policy, for review in plans."
  value       = vault_policy.reader.policy
}

output "auth_mount" {
  value = vault_jwt_auth_backend.aws.path
}
