# /// script
# requires-python = ">=3.10"
# dependencies = ["typesafe-sdk>=0.7.2"]
# ///
"""Assess mechanisms for syncing HCP Vault secrets to AWS Secrets Manager with TypeSafe System One.

Each candidate mechanism is judged against your requirements profile:
  - Nouls act as hard gates (any failing gate disqualifies a candidate).
  - Scores rate independent dimensions; code combines them with explicit weights.

Usage:
  export TYPESAFE_API_KEY=...
  uv run assess_sync.py [requirements.json]

uv reads the inline metadata above and installs dependencies into a cached, isolated environment.
"""

import asyncio
import json
import sys
from pathlib import Path

from typesafe_sdk import AsyncTypeSafeClient, Noul, Score

# Edit to match your environment, or pass a JSON file with the same keys.
DEFAULT_REQUIREMENTS = {
    "vault_product": "HCP Vault Dedicated, Standard tier, Vault 2.0.x",
    "source_engine": "KV v2 in several namespaces (admin and its children)",
    "direction": "one-way, Vault is the system of record; AWS Secrets Manager is a read replica for AWS-native consumers (Lambda, ECS, RDS proxies)",
    "freshness": "changes should appear in AWS within minutes",
    "aws_footprint": "multiple AWS accounts; IAM users and long-lived access keys are not allowed anywhere",
    "security": "no secret values or credentials persisted in intermediate stores (Terraform state, CI logs, Kubernetes etcd); least-privilege IAM",
    "granularity": "secret-path: one AWS secret per Vault secret",
    "ci": "Terraform, Terragrunt and GitLab.com CI with OIDC",
    "operations": "small platform team; prefer managed features over custom code",
    "kubernetes": "EKS exists but not every consumer runs on it",
    "today": "2026-10-04",
}

# Fact sheets from vendor docs (verified 2026-10-04). Keep them factual; the model judges from these.
MECHANISMS = {
    "vault_secrets_sync": {
        "name": "Vault Secrets Sync (native aws-sm destination) on HCP Vault Dedicated",
        "facts": [
            "Built-in Vault feature: sys/sync/destinations/aws-sm plus associations of KV v2 secrets.",
            "Available on HCP Vault Dedicated Standard tier only (not Development or Essentials).",
            "One-way, asynchronous, event-based; HashiCorp says changes propagate in a handful of seconds.",
            "Deleting the secret or association in Vault deletes it in AWS; retries plus periodic reconciliation.",
            "Reconciliation does not protect against out-of-band edits made directly in AWS; last write wins.",
            "HCP Vault Dedicated does not support workload identity federation, including for Secrets Sync (HCP constraints page, 2026-10-04); WIF works only on self-managed Vault Enterprise 2.0+.",
            "On HCP the destination therefore needs a static IAM user access key pair (optionally plus role_arn and external_id); there is no session-token field, so short-lived STS credentials cannot be used.",
            "The vault provider stores the destination's access key in Terraform state; setting it any other way still requires an IAM user.",
            "Synced secrets are tagged hashicorp:vault so IAM conditions can restrict writes to Vault-managed secrets.",
            "secret_name_template, granularity (secret-path or secret-key) and custom_tags configurable.",
            "Each synced secret counts as a distinct Vault client for billing (HCP lists about $73 per client per month).",
            "One destination per AWS account/region; multi-account means several destinations.",
        ],
    },
    "hcp_vault_secrets_integration": {
        "name": "HCP Vault Secrets (SaaS) AWS Secrets Manager integration",
        "facts": [
            "Separate SaaS product from HCP Vault Dedicated with a point-and-click AWS Secrets Manager sync.",
            "End of sale 2025-06-30; end of life the earlier of Flex contract expiry or 2026-07-01, when apps are deleted.",
            "HashiCorp directs users to migrate to HCP Vault Dedicated; it is a full migration, not an upgrade.",
        ],
    },
    "lambda_outbound_federation": {
        "name": "Scheduled Lambda in AWS: IAM outbound identity federation to Vault JWT auth, then writes Secrets Manager",
        "facts": [
            "Lambda execution role calls sts:GetWebIdentityToken (AWS IAM outbound identity federation, GA since late 2025) to get a short-lived signed JWT.",
            "Vault JWT auth in the admin namespace trusts the hub account's issuer URL and binds the role ARN (sub) and audience; Vault needs no AWS credentials.",
            "One Vault policy in admin grants read on exact KV v2 paths in admin and child namespaces; one Vault entity, so one billed client in total.",
            "Lambda assumes a role in each destination account that may only create/modify secrets tagged managed-by=vault-secrets-sync under vault/*, and cannot read values.",
            "Runs every minute via EventBridge Scheduler; updates only when the KV version tag changes; deletes removed secrets with a 7-day recovery window; never deletes when a Vault read fails.",
            "No IAM users, access keys or static Vault tokens anywhere; Terraform state holds only ARNs, issuer URL and policies.",
            "About 300 lines of team-owned Python; 8 unit tests cover create, update on version change, delete with recovery window, restore of pending-deletion secrets, refusal to overwrite unmanaged secrets, no delete on Vault read failure, and dry run.",
            "Every run is a full reconcile of all configured secrets, so a failed run is retried by the next one a minute later; alarms fire on 3 failures in 5 minutes or 15 minutes without a run.",
            "Runs on managed services only (Lambda, EventBridge Scheduler, SSM, CloudWatch); no servers, clusters, or operators, and no credentials to rotate.",
            "Needs network reachability from Lambda to Vault (HVN peering/TGW or fixed NAT egress on the ip_allowlist).",
        ],
    },
    "lambda_aws_auth_method": {
        "name": "Scheduled Lambda using Vault's AWS IAM auth method, then writes Secrets Manager",
        "facts": [
            "Vault's AWS iam auth method must call AWS STS/IAM with its own credentials to validate logins.",
            "On HCP those credentials can only be an IAM user access key, because HCP does not support plugin WIF or an instance role.",
            "Otherwise the same as any scheduled Lambda sync: minute-level freshness, one Vault client, team-owned code.",
        ],
    },
    "eso_pushsecret": {
        "name": "External Secrets Operator: ExternalSecret from Vault, then PushSecret to AWS Secrets Manager",
        "facts": [
            "Two hops: Vault -> Kubernetes Secret (ExternalSecret) -> AWS Secrets Manager (PushSecret).",
            "Secret values are materialized as Kubernetes Secrets in etcd on the EKS cluster.",
            "Uses IRSA/Pod Identity for AWS and the Vault Kubernetes auth method; refreshInterval controls freshness.",
            "Open-source CNCF project; requires running and upgrading the operator; ties sync availability to the cluster.",
            "Deletion policy on PushSecret is configurable; works on any Vault tier.",
        ],
    },
    "terraform_pipeline": {
        "name": "Terraform/CI pipeline: vault provider reads KV, aws_secretsmanager_secret_version writes it",
        "facts": [
            "Runs only when the pipeline runs (on merge or on a schedule); no event-driven propagation.",
            "Classic data sources and secret_string persist values in Terraform state.",
            "Terraform 1.10+ ephemeral resources and write-only arguments (secret_string_wo) can keep values out of state, but need careful version pinning.",
            "Uses existing IaC tooling and review workflows; works on any Vault tier.",
            "Drift from out-of-band AWS edits is detected only on plan.",
        ],
    },
}

GATES = {
    "supported": Noul(
        instructions=(
            "Given `requirements.today`, will `mechanism` still be a supported, available product or feature "
            "for the setup described in `requirements.vault_product`? Treat end-of-life products as unsupported."
        ),
        criteria={"true": "Supported and usable today", "false": "End of life, retired, or unavailable"},
    ),
    "no_long_lived_credentials": Noul(
        instructions=(
            "Can `mechanism`, as described in `mechanism.facts`, run in the setup of `requirements.vault_product` "
            "without any IAM user, long-lived access key, or static token, as `requirements.aws_footprint` demands?"
        ),
        criteria={"true": "Only short-lived, federated credentials", "false": "Needs an IAM user, access key, or static token"},
    ),
    "no_intermediate_plaintext": Noul(
        instructions=(
            "Can `mechanism`, as described in `mechanism.facts`, be operated without persisting secret values in an "
            "intermediate store such as Terraform state, CI logs, or Kubernetes etcd, as `requirements.security` demands?"
        ),
    ),
}

DIMENSIONS = {
    "freshness": Score(
        instructions="How well does `mechanism` meet `requirements.freshness`?",
        criteria=[
            "Manual or ad-hoc runs only",
            "Batch runs hours apart or only on deploys",
            "Scheduled polling every few minutes",
            "Near real-time, event-driven within seconds",
        ],
    ),
    "operational_burden": Score(
        instructions=(
            "How little ongoing engineering and operational work does `mechanism` require from the team in "
            "`requirements.operations`? Higher means less work."
        ),
        criteria=[
            "Team builds and maintains significant custom code and infrastructure",
            "Team runs and upgrades third-party components (operators, clusters) plus glue configuration",
            "Team owns a small, tested function on managed services, with no credentials to rotate",
            "Mostly configuration with some supporting automation to own",
            "Managed, built-in feature configured declaratively",
        ],
    ),
    "security_posture": Score(
        instructions=(
            "How strong is the credential and access model of `mechanism` against `requirements.security` and "
            "`requirements.aws_footprint`?"
        ),
        criteria=[
            "Long-lived credentials and secret copies in extra systems",
            "Short-lived credentials but secrets copied through an extra system",
            "Short-lived role-based credentials, no extra copies, coarse IAM scoping",
            "Federated short-lived credentials, no extra copies, IAM scoped to only the managed secrets",
        ],
    ),
    "lifecycle_correctness": Score(
        instructions=(
            "How completely does `mechanism`, as described in `mechanism.facts`, keep AWS consistent with Vault "
            "across creates, updates, deletes, failures, and retries? Judge only the behaviour, whether it is built "
            "in or written by the team; who maintains it is judged separately as operational burden."
        ),
        criteria=[
            "No deletion handling or retry; drift accumulates",
            "Updates only; deletes, failures, or retries are not handled",
            "Updates and deletes handled, but failures can leave drift or cause wrong deletions",
            "Updates, deletes, retries, and reconciliation all handled; failed reads never delete",
        ],
    ),
    "cost_fit": Score(
        instructions=(
            "How economical is `mechanism` for a medium estate of a few hundred synced secrets, considering licensing, "
            "per-client billing, tier upgrades, and compute?"
        ),
        criteria=[
            "Requires a costly tier upgrade plus per-secret licensing",
            "Noticeable per-secret or tier cost",
            "Modest infrastructure or engineering cost",
            "Negligible incremental cost",
        ],
    ),
}

# Policy lives in code: change weights without rerunning inference.
WEIGHTS = {
    "freshness": 0.20,
    "operational_burden": 0.25,
    "security_posture": 0.25,
    "lifecycle_correctness": 0.20,
    "cost_fit": 0.10,
}
GATE_THRESHOLD = 0.5


async def judge(client, key, mechanism, requirements):
    state = {"requirements": requirements, "mechanism": mechanism}
    response = await client.system_one(state=state, questions={**GATES, **DIMENSIONS})
    gates = {g: response.nouls[g].noul for g in GATES}
    dims = {}
    for d in DIMENSIONS:
        answer = response.scores[d]
        dims[d] = {"norm": answer.score / (len(DIMENSIONS[d].criteria) - 1), "confidence": answer.confidence}
    composite = sum(WEIGHTS[d] * dims[d]["norm"] for d in DIMENSIONS)
    passed = all(p >= GATE_THRESHOLD for p in gates.values())
    return {"key": key, "name": mechanism["name"], "gates": gates, "dims": dims,
            "composite": composite, "passed": passed, "model": response.model,
            "input_tokens": response.usage.input_tokens or 0, "output_tokens": response.usage.output_tokens or 0}


async def main():
    requirements = DEFAULT_REQUIREMENTS
    if len(sys.argv) > 1:
        requirements = json.loads(Path(sys.argv[1]).read_text())

    async with AsyncTypeSafeClient() as client:
        results = await asyncio.gather(
            *(judge(client, k, m, requirements) for k, m in MECHANISMS.items())
        )

    results.sort(key=lambda r: (r["passed"], r["composite"]), reverse=True)
    header = f"{'mechanism':32} {'gates':6} {'score':>5}  " + "  ".join(f"{d[:10]:>10}" for d in DIMENSIONS)
    print(header)
    print("-" * len(header))
    for r in results:
        dims = "  ".join(
            f"{r['dims'][d]['norm']:>5.2f}({r['dims'][d]['confidence']:.2f})" for d in DIMENSIONS
        )
        print(f"{r['key']:32} {'PASS' if r['passed'] else 'FAIL':6} {r['composite']:>5.2f}  {dims}")
        for g, p in r["gates"].items():
            if p < GATE_THRESHOLD:
                print(f"{'':32}   gate {g} failed (p={p:.2f})")

    best = next((r for r in results if r["passed"]), None)
    print(f"\nRecommended: {best['name'] if best else 'no candidate passed the gates'}")
    tokens_in = sum(r["input_tokens"] for r in results)
    tokens_out = sum(r["output_tokens"] for r in results)
    models = ", ".join(sorted({r["model"] for r in results}))
    print(f"TypeSafe usage: {len(results)} requests, {tokens_in:,} input + {tokens_out:,} output tokens (model: {models})")
    low = [d for d in DIMENSIONS if best and best["dims"][d]["confidence"] < 0.6]
    if low:
        print(f"Low-confidence dimensions to review by hand: {', '.join(low)}")


if __name__ == "__main__":
    asyncio.run(main())
