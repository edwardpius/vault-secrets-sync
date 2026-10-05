import json

import pytest

from vault_secrets_sync.handler import (
    MANAGED_TAG,
    MANAGED_VALUE,
    VERSION_TAG,
    VaultError,
    run_sync,
    validate_config,
)

CONFIG = {
    "destinations": {
        "prod-use1": {"account_id": "222222222222", "region": "us-east-1"},
        "nonprod-use1": {"account_id": "333333333333", "region": "us-east-1"},
    },
    "sources": [
        {"namespace": "admin", "mount": "app-kv", "secrets": ["payments/db"], "destinations": ["prod-use1"]},
        {
            "namespace": "admin/team-a",
            "mount": "kv",
            "secrets": ["api/stripe"],
            "destinations": ["prod-use1", "nonprod-use1"],
        },
    ],
}


class FakeVault:
    def __init__(self, secrets, failing=()):
        self.secrets = secrets  # {(ns, mount, path): (data, version)}
        self.failing = set(failing)

    def read_kv2(self, ns, mount, path):
        if (ns, mount, path) in self.failing:
            raise VaultError("HTTP 503")
        return self.secrets.get((ns, mount, path))


class _Exceptions:
    class ResourceExistsException(Exception):
        pass

    class InvalidRequestException(Exception):
        pass


class FakeSM:
    exceptions = _Exceptions

    def __init__(self):
        self.store = {}  # name -> {"value", "tags", "deleted"}
        self.calls = []

    def get_paginator(self, op):
        assert op == "list_secrets"
        fake = self

        class P:
            def paginate(self, **kw):
                yield {
                    "SecretList": [
                        {"Name": n, "Tags": [{"Key": k, "Value": v} for k, v in s["tags"].items()]}
                        for n, s in fake.store.items()
                        if not s["deleted"]
                    ]
                }

        return P()

    def create_secret(self, Name, SecretString, Tags, KmsKeyId=None):
        self.calls.append(("create", Name))
        if Name in self.store:
            if self.store[Name]["deleted"]:
                raise self.exceptions.InvalidRequestException("scheduled for deletion")
            raise self.exceptions.ResourceExistsException(Name)
        self.store[Name] = {"value": SecretString, "tags": {t["Key"]: t["Value"] for t in Tags}, "deleted": False}

    def describe_secret(self, SecretId):
        s = self.store[SecretId]
        out = {"Name": SecretId, "Tags": [{"Key": k, "Value": v} for k, v in s["tags"].items()]}
        if s["deleted"]:
            out["DeletedDate"] = "2026-10-01"
        return out

    def restore_secret(self, SecretId):
        self.calls.append(("restore", SecretId))
        self.store[SecretId]["deleted"] = False

    def put_secret_value(self, SecretId, SecretString):
        self.calls.append(("put", SecretId))
        self.store[SecretId]["value"] = SecretString

    def tag_resource(self, SecretId, Tags):
        self.store[SecretId]["tags"].update({t["Key"]: t["Value"] for t in Tags})

    def delete_secret(self, SecretId, RecoveryWindowInDays):
        self.calls.append(("delete", SecretId, RecoveryWindowInDays))
        self.store[SecretId]["deleted"] = True


def vault_secrets(db_version=1, stripe_version=3):
    return {
        ("admin", "app-kv", "payments/db"): ({"user": "app", "password": "p1"}, db_version),
        ("admin/team-a", "kv", "api/stripe"): ({"key": "sk_live"}, stripe_version),
    }


def run(vault, sms, **kw):
    return run_sync(CONFIG, vault, lambda d: sms[d], **kw)


def test_creates_missing_secrets_with_tags_and_json_value():
    sms = {"prod-use1": FakeSM(), "nonprod-use1": FakeSM()}
    report = run(FakeVault(vault_secrets()), sms)

    assert not report.errors
    prod = sms["prod-use1"].store
    assert set(prod) == {"vault/admin/app-kv/payments/db", "vault/admin/team-a/kv/api/stripe"}
    assert json.loads(prod["vault/admin/app-kv/payments/db"]["value"]) == {"user": "app", "password": "p1"}
    tags = prod["vault/admin/team-a/kv/api/stripe"]["tags"]
    assert tags[MANAGED_TAG] == MANAGED_VALUE and tags[VERSION_TAG] == "3"
    assert set(sms["nonprod-use1"].store) == {"vault/admin/team-a/kv/api/stripe"}


def test_updates_only_when_vault_version_changes():
    sms = {"prod-use1": FakeSM(), "nonprod-use1": FakeSM()}
    run(FakeVault(vault_secrets()), sms)
    sms["prod-use1"].calls.clear()

    report = run(FakeVault(vault_secrets(db_version=2)), sms)

    assert report.updated == ["prod-use1:vault/admin/app-kv/payments/db"]
    assert ("put", "vault/admin/app-kv/payments/db") in sms["prod-use1"].calls
    assert sms["prod-use1"].store["vault/admin/app-kv/payments/db"]["tags"][VERSION_TAG] == "2"
    assert "prod-use1:vault/admin/team-a/kv/api/stripe" in report.unchanged


def test_deletes_secret_removed_from_vault_with_recovery_window():
    sms = {"prod-use1": FakeSM(), "nonprod-use1": FakeSM()}
    run(FakeVault(vault_secrets()), sms)
    secrets = vault_secrets()
    del secrets[("admin", "app-kv", "payments/db")]

    report = run(FakeVault(secrets), sms, recovery_days=7)

    assert report.deleted == ["prod-use1:vault/admin/app-kv/payments/db"]
    assert ("delete", "vault/admin/app-kv/payments/db", 7) in sms["prod-use1"].calls


def test_vault_read_error_never_deletes_and_is_reported():
    sms = {"prod-use1": FakeSM(), "nonprod-use1": FakeSM()}
    run(FakeVault(vault_secrets()), sms)

    report = run(FakeVault(vault_secrets(), failing=[("admin", "app-kv", "payments/db")]), sms)

    assert report.errors and "payments/db" in report.errors[0]
    assert not report.deleted
    assert not sms["prod-use1"].store["vault/admin/app-kv/payments/db"]["deleted"]


def test_refuses_to_overwrite_unmanaged_secret():
    sm = FakeSM()
    sm.store["vault/admin/app-kv/payments/db"] = {"value": "x", "tags": {"owner": "someone"}, "deleted": False}
    sms = {"prod-use1": sm, "nonprod-use1": FakeSM()}

    report = run(FakeVault(vault_secrets()), sms)

    assert any("not managed" in e for e in report.errors)
    assert sm.store["vault/admin/app-kv/payments/db"]["value"] == "x"


def test_restores_secret_pending_deletion():
    sms = {"prod-use1": FakeSM(), "nonprod-use1": FakeSM()}
    run(FakeVault(vault_secrets()), sms)
    sms["prod-use1"].store["vault/admin/app-kv/payments/db"]["deleted"] = True

    report = run(FakeVault(vault_secrets(db_version=5)), sms)

    assert not report.errors
    assert ("restore", "vault/admin/app-kv/payments/db") in sms["prod-use1"].calls
    assert sms["prod-use1"].store["vault/admin/app-kv/payments/db"]["tags"][VERSION_TAG] == "5"


def test_dry_run_changes_nothing():
    sms = {"prod-use1": FakeSM(), "nonprod-use1": FakeSM()}
    report = run(FakeVault(vault_secrets()), sms, dry_run=True)
    assert len(report.created) == 3
    assert not sms["prod-use1"].store and not sms["nonprod-use1"].store


def test_validate_config_rejects_unknown_destination():
    bad = {**CONFIG, "sources": [{**CONFIG["sources"][0], "destinations": ["nope"]}]}
    with pytest.raises(ValueError, match="unknown destinations"):
        validate_config(bad)
