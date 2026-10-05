# ADR-001: How HCP Vault secrets reach AWS Secrets Manager

- **Status:** Accepted, 2026-10-04
- **Supersedes:** the earlier draft that used native Secrets Sync with an IAM user access key

## Decision

A scheduled Lambda in a hub AWS account pulls selected KV v2 secrets from HCP Vault Dedicated and writes them to Secrets Manager in each destination account. It logs in to Vault with an **AWS IAM outbound identity federation** token (`sts:GetWebIdentityToken`), checked by Vault's **JWT auth method**. It writes through a narrowly scoped **assumed role** in each destination account.

No IAM users, access keys or static Vault tokens exist anywhere, and Terraform state contains no secret values or credentials.

## Constraints that drove it

| Constraint | Source |
| --- | --- |
| No IAM users or access keys, not even in encrypted Terraform state | Project requirement |
| HCP Vault Dedicated does not support WIF, which "includes all Vault WIF functionality, including auth methods, secrets engines, and Secrets Sync" | [HCP constraints and limitations](https://developer.hashicorp.com/vault/cloud/get-started/deployment-considerations/constraints-and-limitations) |
| Without WIF, the Secrets Sync `aws-sm` destination accepts only `access_key_id` and `secret_access_key`, optionally with `role_arn`. It has no session-token field. | [Vault provider docs](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/secrets_sync_aws_destination), [Secrets Sync API](https://developer.hashicorp.com/vault/api-docs/system/secrets-sync) |
| Vault's AWS `iam` auth method also needs AWS credentials on the Vault side, and on HCP those can only be access keys | [AWS auth method](https://developer.hashicorp.com/vault/docs/auth/aws) |
| Sources live in several namespaces (admin and its children); granularity is secret-path | Project requirement |

So **every Vault-pushes-to-AWS design on HCP needs an IAM user today**. Reversing the direction removes that need: AWS proves its identity to Vault, which Vault can verify with public keys alone.

## Options considered

| Option | IAM user needed | Secrets in state or etcd | Freshness | Vault clients billed | Verdict |
| --- | --- | --- | --- | --- | --- |
| Native Secrets Sync, access keys | Yes | Key in state | Seconds | 1 per synced secret | Rejected: IAM user |
| Native Secrets Sync, WIF | No | No | Seconds | 1 per synced secret | Not available on HCP yet (see below) |
| **Lambda + outbound federation + Vault JWT auth** | **No** | **No** | **≤ 1 min** | **1 in total** | **Chosen** |
| Lambda + Vault AWS auth method | Yes (Vault side) | Key in Vault config | ≤ 1 min | 1 in total | Rejected: IAM user |
| External Secrets Operator PushSecret | No (IRSA) | Values in etcd | refreshInterval | 1 | Rejected: etcd copy |
| Terraform writes secret values | No | Values in state unless write-only | Per pipeline | 1 | Rejected: freshness, state |
| HCP Vault Secrets integration | n/a | n/a | n/a | n/a | End of life 2026-07-01 |

The TypeSafe assessment (`assess_sync.py`) agrees: this is the only option that passes all three checks, with a weighted score of 0.75. See [assessment-results.md](assessment-results.md).

## Consequences

- **Good:** no stored credentials anywhere. The Vault read policy lists exact paths. The AWS role cannot read secret values. Only one Vault client is billed instead of one per secret, which is roughly $73 a month saved per synced secret at [published HCP rates](https://infisical.com/ai/blog/hashicorp-vault-pricing) (approximate, third-party figure).
- **Cost:** your team owns about 300 lines of Python, with unit tests in `lambda/tests`. Freshness is up to one minute instead of a few seconds.
- **Network:** both the Lambda and the CI runner must reach the Vault API. Vault must reach the AWS issuer's public discovery and JWKS endpoints (`*.tokens.sts.global.api.aws`).
- **Out-of-band edits in AWS** are blocked by `policies/scp-protect-synced-secrets.json`, not detected.

## Revisit WIF

Re-evaluate native Secrets Sync with WIF when **both** of these are true:

1. The [HCP constraints page](https://developer.hashicorp.com/vault/cloud/get-started/deployment-considerations/constraints-and-limitations) no longer lists WIF for Secrets Sync. HashiCorp has [said it plans to bring WIF to HCP Vault Dedicated](https://www.hashicorp.com/en/blog/advancing-secret-sync-with-workload-identity-federation). Self-managed Vault Enterprise 2.0 already has it.
2. The per-secret client cost is acceptable. For example, 200 synced secrets is about $14,600 a month at the published per-client rate, against one client for the Lambda.

What a switch would involve, per destination:

- Create an IAM OIDC provider for Vault's Secrets Sync issuer (`https://<vault>/v1/<namespace>/identity/oidc/secrets-sync`). Add a trust statement to `modules/sync-target-role` for `sts:AssumeRoleWithWebIdentity`, matching `sub = secrets-sync:<namespace_path>:aws-sm:<destination>` and the chosen audience ([docs](https://developer.hashicorp.com/vault/docs/sync/awssm)).
- Create `vault_secrets_sync_aws_destination` with `role_arn`, `identity_token_audience_wo` and `granularity = "secret-path"`, and one `vault_secrets_sync_association` per secret.
- Native sync tags secrets `hashicorp:vault` and names them from `secret_name_template`. Check that a template can reproduce `vault/<namespace>/<mount>/<path>`. If it can't, plan a rename and move consumers over.
- The Lambda deletes only secrets tagged `managed-by=vault-secrets-sync`. Removing a destination from `config/sync-targets.json` schedules its copies for deletion, with a 7-day recovery window. So move consumers to the natively synced names first, then remove the destination.
