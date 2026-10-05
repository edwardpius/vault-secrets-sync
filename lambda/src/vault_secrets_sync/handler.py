"""Sync selected Vault KV v2 secrets into AWS Secrets Manager.

Runs as a scheduled Lambda in the hub AWS account. No long-lived credentials exist anywhere:
  1. The Lambda's execution role calls sts:GetWebIdentityToken (IAM outbound identity federation).
  2. Vault's JWT auth method validates that token against the account's AWS issuer and returns a
     short-lived Vault token.
  3. For each destination account the Lambda assumes a narrowly scoped role and writes
     Secrets Manager secrets named vault/<namespace>/<mount>/<path> (secret-path granularity:
     one AWS secret per Vault secret, value = the KV data as JSON).

Change detection uses a `vault-version` tag, so the sync role never needs GetSecretValue.
Secrets removed from the config (or deleted in Vault) are deleted in AWS with a recovery window.
A secret that could not be read from Vault is never deleted in AWS.
"""

import json
import logging
import os
import urllib.error
import urllib.request
from dataclasses import dataclass, field

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

MANAGED_TAG = "managed-by"
MANAGED_VALUE = "vault-secrets-sync"
VERSION_TAG = "vault-version"


class VaultError(Exception):
    pass


class SyncFailed(Exception):
    pass


class VaultClient:
    """Minimal Vault HTTP client (stdlib only) for JWT login and KV v2 reads."""

    def __init__(self, addr, timeout=10):
        self.addr = addr.rstrip("/")
        self.timeout = timeout
        self.token = None

    def _request(self, method, path, namespace, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"{self.addr}/v1/{path}", data=data, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("X-Vault-Namespace", namespace)
        if self.token:
            req.add_header("X-Vault-Token", self.token)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            raise VaultError(f"{method} {path} (namespace {namespace}): HTTP {e.code}") from e
        except urllib.error.URLError as e:
            raise VaultError(f"{method} {path} (namespace {namespace}): {e.reason}") from e

    def login_jwt(self, namespace, mount, role, jwt):
        resp = self._request("POST", f"auth/{mount}/login", namespace, {"role": role, "jwt": jwt})
        if not resp or "auth" not in resp:
            raise VaultError(f"JWT login to auth/{mount} returned no token")
        self.token = resp["auth"]["client_token"]

    def revoke_self(self, namespace):
        if self.token:
            try:
                self._request("POST", "auth/token/revoke-self", namespace, {})
            except VaultError:
                logger.warning("could not revoke Vault token; it expires on its own TTL")
            self.token = None

    def read_kv2(self, namespace, mount, path):
        """Return (data, version), or None when the secret or its latest version is gone."""
        resp = self._request("GET", f"{mount}/data/{path}", namespace)
        if not resp or not resp.get("data") or resp["data"].get("data") is None:
            return None
        return resp["data"]["data"], resp["data"]["metadata"]["version"]


@dataclass
class Desired:
    name: str
    value: str
    version: str
    tags: dict


@dataclass
class Report:
    created: list = field(default_factory=list)
    updated: list = field(default_factory=list)
    unchanged: list = field(default_factory=list)
    deleted: list = field(default_factory=list)
    skipped: list = field(default_factory=list)
    errors: list = field(default_factory=list)


def secret_name(namespace, mount, path):
    return f"vault/{namespace}/{mount}/{path}"


def build_desired(config, vault, report):
    """Read every configured secret from Vault.

    Returns ({destination: {name: Desired}}, {destination: {protected names}}).
    Protected names failed to read and must not be deleted in AWS.
    """
    desired = {d: {} for d in config["destinations"]}
    protected = {d: set() for d in config["destinations"]}
    for src in config["sources"]:
        ns, mount = src["namespace"], src["mount"]
        for path in src["secrets"]:
            name = secret_name(ns, mount, path)
            try:
                result = vault.read_kv2(ns, mount, path)
            except VaultError as e:
                report.errors.append(f"read {name}: {e}")
                for dest in src["destinations"]:
                    protected[dest].add(name)
                continue
            if result is None:
                report.skipped.append(f"{name}: not found or deleted in Vault")
                continue
            data, version = result
            tags = {
                MANAGED_TAG: MANAGED_VALUE,
                "vault-namespace": ns,
                "vault-mount": mount,
                "vault-path": path,
                VERSION_TAG: str(version),
            }
            for dest in src["destinations"]:
                desired[dest][name] = Desired(name, json.dumps(data, sort_keys=True), str(version), tags)
    return desired, protected


def list_managed(sm):
    """Secrets Manager secrets carrying managed-by=vault-secrets-sync, keyed by name."""
    found = {}
    pages = sm.get_paginator("list_secrets").paginate(
        Filters=[
            {"Key": "tag-key", "Values": [MANAGED_TAG]},
            {"Key": "tag-value", "Values": [MANAGED_VALUE]},
        ]
    )
    for page in pages:
        for s in page["SecretList"]:
            tags = {t["Key"]: t["Value"] for t in s.get("Tags", [])}
            if tags.get(MANAGED_TAG) == MANAGED_VALUE:
                found[s["Name"]] = tags
    return found


def create_or_restore(sm, want, kms_key_id, report, dest, dry_run):
    if dry_run:
        report.created.append(f"{dest}:{want.name}")
        return
    kwargs = {
        "Name": want.name,
        "SecretString": want.value,
        "Tags": [{"Key": k, "Value": v} for k, v in want.tags.items()],
    }
    if kms_key_id:
        kwargs["KmsKeyId"] = kms_key_id
    try:
        sm.create_secret(**kwargs)
        report.created.append(f"{dest}:{want.name}")
        return
    except sm.exceptions.ResourceExistsException:
        pass
    except sm.exceptions.InvalidRequestException:
        # Raised when a secret with this name is scheduled for deletion.
        pass
    existing = sm.describe_secret(SecretId=want.name)
    tags = {t["Key"]: t["Value"] for t in existing.get("Tags", [])}
    if tags.get(MANAGED_TAG) != MANAGED_VALUE:
        report.errors.append(f"{dest}:{want.name}: exists in AWS but is not managed by this sync; refusing to overwrite")
        return
    if existing.get("DeletedDate"):
        sm.restore_secret(SecretId=want.name)
    sm.put_secret_value(SecretId=want.name, SecretString=want.value)
    sm.tag_resource(SecretId=want.name, Tags=[{"Key": VERSION_TAG, "Value": want.version}])
    report.created.append(f"{dest}:{want.name} (restored)")


def sync_destination(sm, dest, want_by_name, protected, report, kms_key_id=None, recovery_days=7, dry_run=False):
    existing = list_managed(sm)

    for name, want in sorted(want_by_name.items()):
        try:
            if name not in existing:
                create_or_restore(sm, want, kms_key_id, report, dest, dry_run)
            elif existing[name].get(VERSION_TAG) != want.version:
                if not dry_run:
                    sm.put_secret_value(SecretId=name, SecretString=want.value)
                    sm.tag_resource(SecretId=name, Tags=[{"Key": VERSION_TAG, "Value": want.version}])
                report.updated.append(f"{dest}:{name}")
            else:
                report.unchanged.append(f"{dest}:{name}")
        except Exception as e:  # keep going; one bad secret must not block the rest
            report.errors.append(f"{dest}:{name}: {e}")

    for name in sorted(set(existing) - set(want_by_name) - protected):
        try:
            if not dry_run:
                sm.delete_secret(SecretId=name, RecoveryWindowInDays=recovery_days)
            report.deleted.append(f"{dest}:{name}")
        except Exception as e:
            report.errors.append(f"{dest}:{name}: delete failed: {e}")


def run_sync(config, vault, sm_for_destination, kms_key_ids=None, recovery_days=7, dry_run=False):
    report = Report()
    desired, protected = build_desired(config, vault, report)
    for dest in sorted(config["destinations"]):
        try:
            sm = sm_for_destination(dest)
        except Exception as e:
            report.errors.append(f"{dest}: cannot assume target role: {e}")
            continue
        sync_destination(
            sm,
            dest,
            desired[dest],
            protected[dest],
            report,
            kms_key_id=(kms_key_ids or {}).get(dest),
            recovery_days=recovery_days,
            dry_run=dry_run,
        )
    return report


def validate_config(config):
    dests = config.get("destinations") or {}
    if not dests:
        raise ValueError("config has no destinations")
    for src in config.get("sources", []):
        for key in ("namespace", "mount", "secrets", "destinations"):
            if key not in src:
                raise ValueError(f"source {src} is missing {key!r}")
        unknown = set(src["destinations"]) - set(dests)
        if unknown:
            raise ValueError(f"source {src['namespace']}/{src['mount']} references unknown destinations {sorted(unknown)}")


def _sm_factory(target_role_name):
    sts = boto3.client("sts")
    cache = {}

    def sm_for_destination(config, dest):
        if dest not in cache:
            d = config["destinations"][dest]
            creds = sts.assume_role(
                RoleArn=f"arn:aws:iam::{d['account_id']}:role/{target_role_name}",
                RoleSessionName="vault-secrets-sync",
                DurationSeconds=900,
            )["Credentials"]
            cache[dest] = boto3.client(
                "secretsmanager",
                region_name=d["region"],
                aws_access_key_id=creds["AccessKeyId"],
                aws_secret_access_key=creds["SecretAccessKey"],
                aws_session_token=creds["SessionToken"],
            )
        return cache[dest]

    return sm_for_destination


def handler(event, context):
    env = os.environ
    config = json.loads(
        boto3.client("ssm").get_parameter(Name=env["SYNC_CONFIG_PARAMETER"])["Parameter"]["Value"]
    )
    validate_config(config)

    # GetWebIdentityToken is not served by the global STS endpoint; pin the regional one.
    region = env["AWS_REGION"]
    sts = boto3.client("sts", region_name=region, endpoint_url=f"https://sts.{region}.amazonaws.com")
    token = sts.get_web_identity_token(
        Audience=[env["VAULT_AUDIENCE"]],
        SigningAlgorithm="RS256",
        DurationSeconds=300,
    )["WebIdentityToken"]

    vault = VaultClient(env["VAULT_ADDR"])
    login_ns = env.get("VAULT_NAMESPACE", "admin")
    vault.login_jwt(login_ns, env.get("VAULT_AUTH_MOUNT", "aws-sts"), env["VAULT_ROLE"], token)

    factory = _sm_factory(env.get("TARGET_ROLE_NAME", "vault-secrets-sync"))
    try:
        report = run_sync(
            config,
            vault,
            lambda dest: factory(config, dest),
            kms_key_ids={k: v.get("kms_key_id") for k, v in config["destinations"].items()},
            recovery_days=int(env.get("RECOVERY_WINDOW_DAYS", "7")),
            dry_run=bool((event or {}).get("dry_run", False)),
        )
    finally:
        vault.revoke_self(login_ns)

    summary = {k: len(v) for k, v in report.__dict__.items()}
    logger.info(json.dumps({"summary": summary, "report": report.__dict__}))
    if report.errors:
        raise SyncFailed(f"{len(report.errors)} error(s): {report.errors[:5]}")
    return summary
