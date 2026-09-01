#!/usr/bin/env python3
"""Validate backup YAML and emit shell assignments for macOS Bash 3.2."""

from __future__ import annotations

import os
import shlex
import sys
from pathlib import Path
from typing import Any, Dict, List, Set, Union

try:
    import yaml
except ModuleNotFoundError:
    print(
        "ERROR: PyYAML is required. Install it with: "
        "python3 -m pip install -r requirements.txt",
        file=sys.stderr,
    )
    raise SystemExit(2)


class ConfigError(ValueError):
    pass


def mapping(value: Any, label: str) -> Dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ConfigError(f"{label} must be a mapping")
    return value


def check_keys(value: Dict[str, Any], allowed: Set[str], label: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise ConfigError(f"unknown key(s) in {label}: {', '.join(unknown)}")


def text(value: Any, label: str, default: str = "") -> str:
    if value is None:
        return default
    if not isinstance(value, str):
        raise ConfigError(f"{label} must be a string")
    return value


def boolean(value: Any, label: str, default: bool) -> bool:
    if value is None:
        return default
    if not isinstance(value, bool):
        raise ConfigError(f"{label} must be true or false")
    return value


def integer(value: Any, label: str, default: int, minimum: int, maximum: int) -> int:
    if value is None:
        return default
    if isinstance(value, bool) or not isinstance(value, int):
        raise ConfigError(f"{label} must be an integer")
    if not minimum <= value <= maximum:
        raise ConfigError(f"{label} must be between {minimum} and {maximum}")
    return value


def string_list(value: Any, label: str) -> List[str]:
    if value is None:
        return []
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise ConfigError(f"{label} must be a list of strings")
    return value


def expand_path(value: str, label: str) -> str:
    expanded = os.path.expanduser(os.path.expandvars(value))
    if not expanded.startswith("/"):
        raise ConfigError(f"{label} must resolve to an absolute path: {value}")
    return os.path.normpath(expanded)


def path_list(value: Any, label: str) -> List[str]:
    return [expand_path(item, label) for item in string_list(value, label)]


def choice(value: Any, label: str, default: str, allowed: Set[str]) -> str:
    result = text(value, label, default)
    if result not in allowed:
        raise ConfigError(f"{label} must be one of: {', '.join(sorted(allowed))}")
    return result


def shell_scalar(name: str, value: Union[str, int]) -> None:
    print(f"{name}={shlex.quote(str(value))}")


def shell_array(name: str, values: List[str]) -> None:
    print(f"{name}=(")
    for value in values:
        print(f"  {shlex.quote(value)}")
    print(")")


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: load-config.py BACKUP.yaml", file=sys.stderr)
        return 2

    config_path = Path(sys.argv[1])
    try:
        with config_path.open("r", encoding="utf-8") as stream:
            document = yaml.safe_load(stream)
    except OSError as exc:
        print(f"ERROR: cannot read YAML config: {exc}", file=sys.stderr)
        return 2
    except yaml.YAMLError as exc:
        print(f"ERROR: invalid YAML: {exc}", file=sys.stderr)
        return 2

    try:
        root = mapping(document, "document")
        check_keys(root, {"version", "destination", "files", "git", "secrets", "backup", "schedule"}, "document")
        version = integer(root.get("version"), "version", 1, 1, 1)

        destination = mapping(root.get("destination"), "destination")
        check_keys(destination, {"root", "id"}, "destination")
        destination_root = expand_path(text(destination.get("root"), "destination.root"), "destination.root")
        destination_id = text(destination.get("id"), "destination.id")

        files = mapping(root.get("files"), "files")
        check_keys(files, {"mirror"}, "files")
        mirror_paths = path_list(files.get("mirror"), "files.mirror")

        git = mapping(root.get("git"), "git")
        check_keys(
            git,
            {"roots", "default_mode", "url_only", "full", "skip", "exclude_names", "dirty_mode", "lfs_mode", "verify"},
            "git",
        )
        git_roots = path_list(git.get("roots"), "git.roots")
        git_url_only = path_list(git.get("url_only"), "git.url_only")
        git_full = path_list(git.get("full"), "git.full")
        git_skip = path_list(git.get("skip"), "git.skip")
        exclude_names = string_list(
            git.get("exclude_names", ["node_modules", ".venv", "DerivedData", ".build", "build", "dist", ".cache"]),
            "git.exclude_names",
        )
        git_default_mode = choice(
            git.get("default_mode"), "git.default_mode", "git-mirror", {"git-mirror", "git-url", "git-full", "skip"}
        )
        git_dirty_mode = choice(git.get("dirty_mode"), "git.dirty_mode", "backup", {"backup", "warn", "fail"})
        git_lfs_mode = choice(git.get("lfs_mode"), "git.lfs_mode", "local", {"local", "warn", "skip"})
        git_verify = boolean(git.get("verify"), "git.verify", True)

        secrets = mapping(root.get("secrets"), "secrets")
        check_keys(secrets, {"paths", "encryption"}, "secrets")
        secret_paths = path_list(secrets.get("paths"), "secrets.paths")
        encryption = mapping(secrets.get("encryption"), "secrets.encryption")
        check_keys(encryption, {"enabled", "allow_plaintext", "keychain"}, "secrets.encryption")
        encryption_enabled = boolean(encryption.get("enabled"), "secrets.encryption.enabled", True)
        allow_plaintext = boolean(encryption.get("allow_plaintext"), "secrets.encryption.allow_plaintext", False)
        keychain = mapping(encryption.get("keychain"), "secrets.encryption.keychain")
        check_keys(keychain, {"account", "service"}, "secrets.encryption.keychain")
        keychain_account = text(keychain.get("account"), "secrets.encryption.keychain.account", "pc-backup")
        keychain_service = text(keychain.get("service"), "secrets.encryption.keychain.service", "pc-backup-gpg")

        backup = mapping(root.get("backup"), "backup")
        check_keys(backup, {"rsync_delete", "retention_days", "brew"}, "backup")
        rsync_delete = boolean(backup.get("rsync_delete"), "backup.rsync_delete", True)
        retention_days = integer(backup.get("retention_days"), "backup.retention_days", 30, 1, 3650)
        brew = boolean(backup.get("brew"), "backup.brew", True)

        schedule = mapping(root.get("schedule"), "schedule")
        check_keys(schedule, {"hour", "minute"}, "schedule")
        launch_hour = integer(schedule.get("hour"), "schedule.hour", 7, 0, 23)
        launch_minute = integer(schedule.get("minute"), "schedule.minute", 30, 0, 59)
    except ConfigError as exc:
        print(f"ERROR: {config_path}: {exc}", file=sys.stderr)
        return 2

    shell_scalar("PC_BACKUP_CONFIG_VERSION", version)
    shell_scalar("PC_BACKUP_ROOT", destination_root)
    shell_scalar("PC_BACKUP_DESTINATION_ID", destination_id)

    shell_array("PC_BACKUP_MIRROR_PATHS", mirror_paths)
    shell_array("PC_BACKUP_GIT_ROOTS", git_roots)
    shell_array("PC_BACKUP_GIT_URL_ONLY_PATHS", git_url_only)
    shell_array("PC_BACKUP_GIT_FULL_PATHS", git_full)
    shell_array("PC_BACKUP_GIT_SKIP_PATHS", git_skip)
    shell_array("PC_BACKUP_SECRET_PATHS", secret_paths)
    shell_array("PC_BACKUP_EXCLUDE_NAMES", exclude_names)

    shell_scalar("PC_BACKUP_GIT_DEFAULT_MODE", git_default_mode)
    shell_scalar("PC_BACKUP_GIT_DIRTY_MODE", git_dirty_mode)
    shell_scalar("PC_BACKUP_GIT_LFS_MODE", git_lfs_mode)
    shell_scalar("PC_BACKUP_GIT_VERIFY", int(git_verify))
    shell_scalar("PC_BACKUP_ENCRYPT_SECRETS", int(encryption_enabled))
    shell_scalar("PC_BACKUP_ALLOW_PLAINTEXT_SECRETS", int(allow_plaintext))
    shell_scalar("PC_BACKUP_GPG_KEYCHAIN_ACCOUNT", keychain_account)
    shell_scalar("PC_BACKUP_GPG_KEYCHAIN_SERVICE", keychain_service)
    shell_scalar("PC_BACKUP_RSYNC_DELETE", int(rsync_delete))
    shell_scalar("PC_BACKUP_RETENTION_DAYS", retention_days)
    shell_scalar("PC_BACKUP_BREW", int(brew))
    shell_scalar("PC_BACKUP_LAUNCH_HOUR", launch_hour)
    shell_scalar("PC_BACKUP_LAUNCH_MINUTE", launch_minute)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
