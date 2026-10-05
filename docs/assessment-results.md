# TypeSafe assessment results

**Recommendation:** Scheduled Lambda in AWS that uses IAM outbound identity federation to log in to Vault's JWT auth, then writes Secrets Manager (`lambda_outbound_federation`). It is the only mechanism that passes all three checks. Its weighted score is 0.75; the next best, native Secrets Sync, scores 0.58 and fails two checks.

- **Run:** 2026-10-05, `uv run assess_sync.py` (rubric v2: lifecycle judged on behaviour only, 5-level operational burden)
- **Model:** TypeSafe System One. Each mechanism was judged against the requirements in `DEFAULT_REQUIREMENTS` and its fact sheet in `MECHANISMS`.
- **Rule:** a mechanism fails if any check has p < 0.50. The weighted score ranks mechanisms only among those that pass.

## Pass/fail checks

The value is the probability that the condition holds. Bold marks a failure (below 0.50); a dash means the value was not printed because the check passed.

| Mechanism | Supported today | No long-lived credentials | Nothing stored in between | Result |
| --- | --- | --- | --- | --- |
| `lambda_outbound_federation` | – | – | – | **PASS** |
| `vault_secrets_sync` | – | **0.03** | **0.07** | FAIL |
| `eso_pushsecret` | – | – | **0.04** | FAIL |
| `terraform_pipeline` | – | – | **0.46** | FAIL |
| `hcp_vault_secrets_integration` | **0.05** | **0.23** | – | FAIL |
| `lambda_aws_auth_method` | – | **0.04** | – | FAIL |

"Nothing stored in between" means no secret values or credentials in Terraform state, CI logs or Kubernetes etcd.

## Dimension scores

Each score is scaled to 0–1. Confidence is in brackets: below 0.6 means the model split its answer between levels. Sorted by weighted score.

| Mechanism | Checks | Weighted score | Freshness (20%) | Operational burden (25%) | Security posture (25%) | Lifecycle correctness (20%) | Cost fit (10%) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `lambda_outbound_federation` | PASS | **0.75** | 0.67 (1.00) | 0.50 (0.99) | 0.89 (0.67) | 1.00 (1.00) | 0.69 (0.61) |
| `vault_secrets_sync` | FAIL | 0.58 | 1.00 (1.00) | 0.79 (0.82) | 0.00 (0.99) | 0.84 (0.52) | 0.16 (0.52) |
| `eso_pushsecret` | FAIL | 0.50 | 0.67 (0.98) | 0.25 (0.99) | 0.33 (0.97) | 0.83 (0.49) | 0.60 (0.75) |
| `terraform_pipeline` | FAIL | 0.49 | 0.37 (0.88) | 0.64 (0.63) | 0.53 (0.09) | 0.29 (0.12) | 0.67 (0.52) |
| `hcp_vault_secrets_integration` | FAIL | 0.49 | 0.58 (0.64) | 0.76 (0.20) | 0.25 (0.24) | 0.43 (0.00) | 0.29 (0.13) |
| `lambda_aws_auth_method` | FAIL | 0.27 | 0.66 (0.99) | 0.18 (0.40) | 0.04 (0.88) | 0.14 (0.57) | 0.56 (0.51) |

## Reading the results

- **The checks decide it.** Native Secrets Sync is faster (1.00 against 0.67) and less work to run (0.79 against 0.50). But on HCP it needs an IAM user key, which fails the credentials check and also puts that key in Terraform state.
- **Security is the widest gap among the viable designs:** 0.89 for the Lambda against 0.00 for native sync on HCP.
- **Cost fit favours the Lambda** (0.69 against 0.16). It is one billed Vault client in total, while native sync bills one client per synced secret.
- **Operational burden of 0.50** is the Lambda's real cost. The model placed it, with high confidence, on the new middle level: "Team owns a small, tested function on managed services, with no credentials to rotate".
- **Borderline:** `terraform_pipeline` failed "nothing stored in between" at 0.46, close to a coin flip, because write-only arguments partly address it. It ranks below the Lambda on every dimension except operational burden, so the outcome doesn't change.
- **Ignore low-confidence scores on failed options**, such as `hcp_vault_secrets_integration` lifecycle at 0.43 (0.00). They don't affect the decision.

## Change from the first run (rubric v1)

| Lambda dimension | v1 | v2 | Why it changed |
| --- | --- | --- | --- |
| Lifecycle correctness | 0.38 (0.87) | 1.00 (1.00) | v1 asked "without custom code", which capped team-written handling |
| Operational burden | 0.30 (0.11) | 0.50 (0.99) | v2 added a level that fits a small tested function on managed services |
| Weighted score | 0.57 | 0.75 | |

The pass/fail results and the recommendation were the same in both runs.

## Repeat run (rubric v2, run 3)

A third run with the same rubric reproduced the outcome: the same check results, the same ranking, and the Lambda again at **0.75**. Its token usage was 6 requests, 9,097 input + 858 output tokens on `jev-1.13.0`. Scores moved by at most 0.05 between runs, shown here for any dimension that moved by 0.03 or more:

| Mechanism and dimension | Run 2 | Run 3 |
| --- | --- | --- |
| `vault_secrets_sync` lifecycle correctness | 0.84 | 0.81 |
| `terraform_pipeline` security posture | 0.53 | 0.58 |
| `hcp_vault_secrets_integration` operational burden | 0.76 | 0.79 |
| `eso_pushsecret` lifecycle correctness | 0.83 | 0.81 |
| `terraform_pipeline` "nothing stored in between" check | 0.46 | 0.47 |

Differences this small don't change any decision. `terraform_pipeline` stays just under the 0.50 threshold on that check in both runs.

## Raw output

```text
mechanism                        gates  score   freshness  operationa  security_p  lifecycle_    cost_fit
---------------------------------------------------------------------------------------------------------
lambda_outbound_federation       PASS    0.75   0.67(1.00)   0.50(0.99)   0.89(0.67)   1.00(1.00)   0.69(0.61)
vault_secrets_sync               FAIL    0.58   1.00(1.00)   0.79(0.82)   0.00(0.99)   0.84(0.52)   0.16(0.52)
                                   gate no_long_lived_credentials failed (p=0.03)
                                   gate no_intermediate_plaintext failed (p=0.07)
eso_pushsecret                   FAIL    0.50   0.67(0.98)   0.25(0.99)   0.33(0.97)   0.83(0.49)   0.60(0.75)
                                   gate no_intermediate_plaintext failed (p=0.04)
terraform_pipeline               FAIL    0.49   0.37(0.88)   0.64(0.63)   0.53(0.09)   0.29(0.12)   0.67(0.52)
                                   gate no_intermediate_plaintext failed (p=0.46)
hcp_vault_secrets_integration    FAIL    0.49   0.58(0.64)   0.76(0.20)   0.25(0.24)   0.43(0.00)   0.29(0.13)
                                   gate supported failed (p=0.05)
                                   gate no_long_lived_credentials failed (p=0.23)
lambda_aws_auth_method           FAIL    0.27   0.66(0.99)   0.18(0.40)   0.04(0.88)   0.14(0.57)   0.56(0.51)
                                   gate no_long_lived_credentials failed (p=0.04)

Recommended: Scheduled Lambda in AWS: IAM outbound identity federation to Vault JWT auth, then writes Secrets Manager
```
