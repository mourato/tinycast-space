#!/usr/bin/env python3
"""Materialize and drive Tinycast from the locked upstream and fork inputs."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
MINE = ROOT / ".mine"
BUILD = ROOT / ".build"
SOURCE = BUILD / "source"
DERIVED_DATA = BUILD / "DerivedData"
LOG_DIR = BUILD / "logs"
LOCK_PATH = MINE / "sources.lock.json"
PATCH_DIR = MINE / "patches"
RECIPE_PATH = Path(__file__).resolve()
RECEIPT_NAME = "tinycast-recipe-receipt.json"
SPACE_RADAR_PATH = MINE / "space-radar.json"
DEFAULT_SIGN_IDENTITY = "Apple Development"
RELEASE_PRODUCT = "Tinycast.app"
DEBUG_PRODUCT = "Tinycast Dev.app"
TOOL_COMMANDS = ("build", "build-debug", "install", "test", "lint")
RECEIPT_SCHEMA = 2
MAX_SPACE_PATCH_CHANGES = 40
SAVE_JOURNAL_SCHEMA = 1
SAVE_JOURNAL_STATES = {
    "prepared",
    "old-patches-moved",
    "patches-published",
    "lock-published",
    "receipt-published",
}
SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
PATCH_NAME_RE = re.compile(r"^[0-9]{4}-[A-Za-z0-9][A-Za-z0-9._-]*\.patch$")
REWRITTEN_REF_RE = re.compile(r"^refs/tinycast/rewritten/([0-9a-f]{40})$")
STAGE_PREFIX = ".source-stage-"
OLD_PREFIX = ".source-old-"
BACKUP_PREFIX = ".source-backup-"
SAVE_PREFIX = ".source-save-"
OPERATION_PREFIX = ".recipe-operation-"
SAVE_JOURNAL = BUILD / ".source-save-journal.json"
GIT_ROUTING_ENV = {
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_OBJECT_DIRECTORY_RELATIVE",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_QUARANTINE_PATH",
    "GIT_NAMESPACE",
}


class RecipeError(RuntimeError):
    """A user-actionable recipe admission or materialization failure."""


def fail(message: str) -> None:
    raise RecipeError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_bytes(path: Path, label: str) -> bytes:
    if path.is_symlink():
        fail(f"{label} is a symlink")
    try:
        return path.read_bytes()
    except OSError as error:
        fail(f"cannot read {label}: {error}")
    raise AssertionError("unreachable")


def parse_json(data: bytes, label: str) -> Any:
    try:
        return json.loads(
            data.decode("utf-8"),
            object_pairs_hook=lambda pairs: _reject_duplicate_keys(pairs, label),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"malformed {label}: {error}")
    raise AssertionError("unreachable")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]], label: str) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"malformed {label}: duplicate key {key!r}")
        result[key] = value
    return result


def require_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        fail(f"malformed {label}: expected keys {sorted(expected)}")
    return value


def require_sha(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA1_RE.fullmatch(value):
        fail(f"malformed {label}: expected a lowercase 40-character SHA")
    return value


def require_url(value: Any, label: str) -> str:
    if not isinstance(value, str):
        fail(f"malformed {label}: expected URL")
    parts = urlsplit(value)
    if parts.scheme == "https":
        if not parts.netloc or parts.username or parts.password or parts.fragment:
            fail(f"malformed {label}: expected an https URL without credentials or fragment")
    elif parts.scheme == "file":
        if parts.netloc not in ("", "localhost") or not parts.path.startswith("/"):
            fail(f"malformed {label}: expected an absolute file URL")
    else:
        fail(f"malformed {label}: unsupported URL scheme {parts.scheme!r}")
    if parts.query:
        fail(f"malformed {label}: query parameters are not allowed")
    return value


def load_lock() -> tuple[dict[str, Any], bytes, str]:
    data = read_bytes(LOCK_PATH, "sources.lock.json")
    parsed = parse_json(data, "sources.lock.json")
    if isinstance(parsed, dict) and parsed.get("schema") == 1:
        fail("malformed sources.lock.json: schema 1 is no longer supported; remove the space block and use schema 2")
    lock = require_keys(
        parsed,
        {"schema", "original_reference_revision", "upstream", "expected_source"},
        "sources.lock.json",
    )
    if lock["schema"] != 2:
        fail("malformed sources.lock.json: unsupported schema")
    require_sha(lock["original_reference_revision"], "original_reference_revision")

    upstream = require_keys(
        lock["upstream"], {"url", "commit", "release_tag", "release_version"}, "upstream"
    )
    require_url(upstream["url"], "upstream.url")
    require_sha(upstream["commit"], "upstream.commit")
    if (
        not isinstance(upstream["release_tag"], str)
        or not upstream["release_tag"].startswith("v")
        or not VERSION_RE.fullmatch(upstream["release_tag"][1:])
    ):
        fail("malformed upstream.release_tag: expected v<semantic-version>")
    if not isinstance(upstream["release_version"], str) or not VERSION_RE.fullmatch(
        upstream["release_version"]
    ):
        fail("malformed upstream.release_version: expected a semantic version")
    if upstream["release_tag"][1:] != upstream["release_version"]:
        fail("malformed upstream: release_tag and release_version disagree")

    expected = require_keys(
        lock["expected_source"], {"fingerprint", "record_format", "excluded_paths"}, "expected_source"
    )
    if not isinstance(expected["fingerprint"], str) or not SHA256_RE.fullmatch(expected["fingerprint"]):
        fail("malformed expected_source.fingerprint: expected sha256:<hex>")
    if expected["record_format"] != "git-ls-tree-z-v1":
        fail("malformed expected_source.record_format")
    if expected["excluded_paths"] != [".mine/", "Makefile"]:
        fail("malformed expected_source.excluded_paths")
    return lock, data, sha256_bytes(data)


def patch_files() -> list[Path]:
    if PATCH_DIR.is_symlink() or not PATCH_DIR.is_dir():
        fail("patch directory is missing or is a symlink")
    result = sorted(PATCH_DIR.glob("*.patch"), key=lambda path: path.name)
    if [path.name for path in result] != sorted(path.name for path in result):
        fail("patch ordering is not deterministic")
    for path in result:
        if path.is_symlink() or not path.is_file():
            fail(f"patch is not a regular file: {path.name}")
        if not PATCH_NAME_RE.fullmatch(path.name):
            fail(f"malformed patch filename: {path.name}")
    return result


def patch_digest(paths: list[Path]) -> tuple[str, list[dict[str, Any]]]:
    digest = hashlib.sha256()
    records: list[dict[str, Any]] = []
    for path in paths:
        data = read_bytes(path, f"patch {path.name}")
        name = path.name.encode("utf-8")
        digest.update(len(name).to_bytes(8, "big"))
        digest.update(name)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
        records.append({"name": path.name, "sha256": sha256_bytes(data), "size": len(data)})
    return digest.hexdigest(), records


def input_digest(lock_bytes: bytes, patch_sha: str, recipe_sha: str) -> str:
    return sha256_bytes(
        b"tinycast-recipe-inputs-v1\0"
        + lock_bytes
        + b"\0"
        + patch_sha.encode("ascii")
        + b"\0"
        + recipe_sha.encode("ascii")
    )


def load_inputs() -> dict[str, Any]:
    lock, lock_bytes, lock_sha = load_lock()
    patches = patch_files()
    patch_sha, patch_records = patch_digest(patches)
    recipe_sha = sha256_bytes(read_bytes(RECIPE_PATH, "recipe.py"))
    input_digest_value = input_digest(lock_bytes, patch_sha, recipe_sha)
    return {
        "lock": lock,
        "lock_sha256": lock_sha,
        "patches": patches,
        "patch_records": patch_records,
        "patch_digest": patch_sha,
        "recipe_sha256": recipe_sha,
        "input_digest": input_digest_value,
    }


def command_env() -> dict[str, str]:
    env = os.environ.copy()
    for name in tuple(env):
        if name in GIT_ROUTING_ENV or name.startswith("GIT_CONFIG_"):
            env.pop(name, None)
    return env


def git_env(*, commit_identity: bool = False) -> dict[str, str]:
    env = command_env()
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_TERMINAL_PROMPT"] = "0"
    if commit_identity:
        env["GIT_AUTHOR_NAME"] = "Tinycast Recipe"
        env["GIT_AUTHOR_EMAIL"] = "recipe@localhost"
        env["GIT_COMMITTER_NAME"] = "Tinycast Recipe"
        env["GIT_COMMITTER_EMAIL"] = "recipe@localhost"
    return env


def run_git(repo: Path, args: list[str], *, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        env=git_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"git {' '.join(args)} failed: {detail}")
    return result.stdout


def configure_repository(repo: Path) -> None:
    for key, value in (
        ("core.hooksPath", "/dev/null"),
        ("commit.gpgSign", "false"),
        ("tag.gpgSign", "false"),
        ("user.name", "Tinycast Recipe"),
        ("user.email", "recipe@localhost"),
    ):
        run_git(repo, ["config", key, value])


def verify_commit(repo: Path, commit: str, label: str) -> None:
    actual = run_git(repo, ["rev-parse", "--verify", f"{commit}^{{commit}}"] ).strip()
    if actual != commit:
        fail(f"{label} resolved to {actual}, expected locked {commit}")


def safe_git_tree(repo: Path, revision: str = "HEAD") -> list[tuple[str, str, str, str]]:
    raw = subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "ls-tree",
            "-r",
            "-z",
            "--abbrev=40",
            "--full-tree",
            revision,
            "--",
            ".",
        ],
        check=False,
        env=git_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if raw.returncode:
        fail(f"cannot inspect generated source tree: {raw.stderr.decode(errors='replace').strip()}")
    records: list[tuple[str, str, str, str]] = []
    for record in raw.stdout.split(b"\0"):
        if not record:
            continue
        try:
            metadata, path_bytes = record.split(b"\t", 1)
            mode, kind, object_id = metadata.decode("ascii").split(" ")
            path = path_bytes.decode("utf-8")
        except (UnicodeDecodeError, ValueError):
            fail("generated source tree has a malformed Git record")
        records.append((mode, kind, object_id, path))
    return records


def source_fingerprint(repo: Path, revision: str = "HEAD") -> str:
    records = []
    for mode, kind, object_id, path in safe_git_tree(repo, revision):
        if path == "Makefile" or path.startswith(".mine/"):
            continue
        records.append(f"{mode} {kind} {object_id}\t{path}".encode("utf-8") + b"\0")
    return "sha256:" + sha256_bytes(b"".join(records))


def source_receipt_path(source: Path) -> Path:
    git_dir = source / ".git"
    if git_dir.is_symlink() or not git_dir.is_dir():
        fail("generated source is not an independent nested Git repository")
    return git_dir / RECEIPT_NAME


def validate_receipt(source: Path, inputs: dict[str, Any]) -> dict[str, Any]:
    receipt_path = source_receipt_path(source)
    if receipt_path.is_symlink() or not receipt_path.is_file():
        fail(f"recipe receipt is missing: {receipt_path}")
    receipt = require_keys(
        parse_json(read_bytes(receipt_path, "recipe receipt"), "recipe receipt"),
        {
            "schema",
            "input",
            "locked",
            "patches",
            "source_only_base_checkpoint",
            "managed_tip",
            "source_fingerprint",
        },
        "recipe receipt",
    )
    if receipt["schema"] != RECEIPT_SCHEMA:
        fail("malformed recipe receipt: unsupported schema")
    input_record = require_keys(
        receipt["input"], {"lock_sha256", "patch_digest", "recipe_sha256", "input_digest"}, "receipt.input"
    )
    for key in input_record:
        if not isinstance(input_record[key], str) or not re.fullmatch(r"[0-9a-f]{64}", input_record[key]):
            fail(f"malformed recipe receipt: receipt.input.{key}")
    require_keys(receipt["locked"], {"upstream", "release_version"}, "receipt.locked")
    require_sha(receipt["locked"]["upstream"], "receipt.locked.upstream")
    if receipt["locked"]["release_version"] != inputs["lock"]["upstream"]["release_version"] and input_record[
        "lock_sha256"
    ] == inputs["lock_sha256"]:
        fail("malformed recipe receipt: release version disagrees with the locked input")
    if not isinstance(receipt["patches"], list):
        fail("malformed recipe receipt: patches is not a list")
    names = []
    for record in receipt["patches"]:
        item = require_keys(record, {"name", "sha256", "size"}, "receipt patch")
        if not isinstance(item["name"], str) or not PATCH_NAME_RE.fullmatch(item["name"]):
            fail("malformed recipe receipt: patch name")
        if not isinstance(item["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"]):
            fail("malformed recipe receipt: patch digest")
        if not isinstance(item["size"], int) or item["size"] < 0:
            fail("malformed recipe receipt: patch size")
        names.append(item["name"])
    if names != sorted(names) or len(names) != len(set(names)):
        fail("malformed recipe receipt: patch order")
    for key in ("source_only_base_checkpoint", "managed_tip"):
        require_sha(receipt[key], f"receipt.{key}")
    if not isinstance(receipt["source_fingerprint"], str) or not SHA256_RE.fullmatch(
        receipt["source_fingerprint"]
    ):
        fail("malformed recipe receipt: source fingerprint")
    input_matches = all(
        receipt["input"][key] == inputs[key]
        for key in ("lock_sha256", "patch_digest", "recipe_sha256", "input_digest")
    )
    if input_matches:
        expected_locked = {
            "upstream": inputs["lock"]["upstream"]["commit"],
            "release_version": inputs["lock"]["upstream"]["release_version"],
        }
        if receipt["locked"] != expected_locked:
            fail("malformed recipe receipt: locked identity disagrees with sources.lock.json")
        if receipt["patches"] != inputs["patch_records"]:
            fail("malformed recipe receipt: patch records disagree with the patch stack")
    return receipt


def is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    result = subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", ancestor, descendant],
        check=False,
        env=git_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode not in (0, 1):
        detail = result.stderr.decode(errors="replace").strip()
        fail(f"cannot inspect generated source lineage: {detail}")
    return result.returncode == 0


def revision_commit(repo: Path, revision: str) -> str | None:
    value = run_git(repo, ["rev-parse", "--verify", f"{revision}^{{commit}}"], check=False).strip()
    return value or None


def ensure_rewrite_backup(repo: Path, managed_tip: str) -> None:
    ref = f"refs/tinycast/rewritten/{managed_tip}"
    existing = revision_commit(repo, ref)
    if existing is not None:
        if existing != managed_tip:
            fail(f"generated source rewrite backup ref does not preserve {managed_tip}")
        return
    run_git(repo, ["update-ref", ref, managed_tip])


def stash_is_represented(repo: Path, stash: str, head_fingerprint: str, head: str) -> bool:
    if source_fingerprint(repo, stash) != head_fingerprint:
        return False
    parents = []
    for suffix in ("^1", "^2", "^3"):
        parent = revision_commit(repo, f"{stash}{suffix}")
        if parent is not None:
            parents.append(parent)
    if not parents or not is_ancestor(repo, parents[0], head):
        return False
    return all(source_fingerprint(repo, parent) == head_fingerprint for parent in parents)


def represented_refs(repo: Path, refs: list[str], head: str, head_fingerprint: str) -> list[str]:
    unrepresented: list[str] = []
    for ref in refs:
        backup = REWRITTEN_REF_RE.fullmatch(ref)
        if backup is not None:
            represented = revision_commit(repo, ref) == backup.group(1)
        elif ref == "refs/stash":
            represented = stash_is_represented(repo, ref, head_fingerprint, head)
        else:
            tip = revision_commit(repo, ref)
            represented = tip is not None and is_ancestor(repo, tip, head)
        if not represented:
            unrepresented.append(ref)
    return unrepresented


def inspect_existing(
    source: Path, inputs: dict[str, Any], *, allow_rewrite: bool = False
) -> tuple[dict[str, Any], bool, dict[str, Any]]:
    if source.is_symlink():
        fail("generated source path is a symlink")
    receipt = validate_receipt(source, inputs)
    if (source / ".git" / "objects" / "info" / "alternates").exists():
        fail("generated source depends on an external Git alternates object store")
    git_dir_text = Path(run_git(source, ["rev-parse", "--git-dir"]).strip())
    git_dir = (source / git_dir_text).resolve() if not git_dir_text.is_absolute() else git_dir_text.resolve()
    if git_dir != (source / ".git").resolve():
        fail("generated source does not own its Git directory")
    common_dir_text = Path(run_git(source, ["rev-parse", "--git-common-dir"]).strip())
    common_dir = (source / common_dir_text).resolve() if not common_dir_text.is_absolute() else common_dir_text.resolve()
    if common_dir != git_dir:
        fail("generated source shares a Git common directory")
    worktrees = run_git(source, ["worktree", "list", "--porcelain"]).strip().splitlines()
    if len([line for line in worktrees if line.startswith("worktree ")]) != 1:
        fail("generated source has additional Git worktrees")
    status = run_git(source, ["status", "--porcelain=v1", "--untracked-files=all"]).strip()
    ignored_status = run_git(source, ["status", "--porcelain=v1", "--untracked-files=all", "--ignored"]).strip()
    ignored = [line[3:] for line in ignored_status.splitlines() if line.startswith("!! ")]
    refs = [line for line in run_git(source, ["for-each-ref", "--format=%(refname)"]).splitlines() if line]
    head: str | None = None
    head_is_descendant: bool | None = None
    if allow_rewrite:
        head = run_git(source, ["rev-parse", "--verify", "HEAD^{commit}"]).strip()
        for commit_key in ("source_only_base_checkpoint", "managed_tip"):
            verify_commit(source, receipt[commit_key], f"receipt.{commit_key}")
        head_is_descendant = is_ancestor(source, receipt["managed_tip"], head)
        if not head_is_descendant:
            if not is_ancestor(source, receipt["source_only_base_checkpoint"], head):
                fail(f"generated source HEAD is outside source-only lineage: {head}")
            ensure_rewrite_backup(source, receipt["managed_tip"])
            refs = [line for line in run_git(source, ["for-each-ref", "--format=%(refname)"]).splitlines() if line]
    unreachable = run_git(source, ["fsck", "--no-reflogs", "--unreachable", "--cache", "HEAD", *refs], check=False).strip()
    if any(line.startswith(("unreachable commit ", "unreachable tree ", "unreachable tag ")) for line in unreachable.splitlines()):
        fail("generated source has unreachable Git objects that may contain unexported work")
    if head is None:
        head = run_git(source, ["rev-parse", "--verify", "HEAD^{commit}"]).strip()
        for commit_key in ("source_only_base_checkpoint", "managed_tip"):
            verify_commit(source, receipt[commit_key], f"receipt.{commit_key}")
        head_is_descendant = is_ancestor(source, receipt["managed_tip"], head)
    if not head_is_descendant and not allow_rewrite:
        fail(f"generated source HEAD is outside managed lineage: {head}")
    managed_fingerprint = source_fingerprint(source, receipt["managed_tip"])
    if managed_fingerprint != receipt["source_fingerprint"]:
        fail("generated source fingerprint disagrees with its receipt")
    actual_fingerprint = source_fingerprint(source)
    unrepresented = represented_refs(source, refs, head, actual_fingerprint)
    current = inputs["input_digest"] == receipt["input"]["input_digest"]
    current = current and inputs["lock_sha256"] == receipt["input"]["lock_sha256"]
    current = current and inputs["patch_digest"] == receipt["input"]["patch_digest"]
    current = current and inputs["recipe_sha256"] == receipt["input"]["recipe_sha256"]
    local_state = {
        "head": head,
        "head_is_managed": head == receipt["managed_tip"],
        "head_is_descendant": head_is_descendant,
        "worktree_dirty": bool(status),
        "ignored_paths": ignored,
        "refs": refs,
        "unrepresented_refs": unrepresented,
        "unexported_changes": bool(status or unrepresented or head != receipt["managed_tip"]),
        "source_fingerprint": actual_fingerprint,
    }
    return receipt, current, local_state


def repository_commit(repo: Path, message: str) -> str:
    run_git(repo, ["add", "-A", "--", "."], check=True)
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgSign=false",
            "commit",
            "-q",
            "--no-verify",
            "--allow-empty",
            "-m",
            message,
        ],
        check=False,
        env=git_env(commit_identity=True),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        fail(f"generated Git commit failed: {result.stderr.strip()}")
    return run_git(repo, ["rev-parse", "HEAD"]).strip()


def ensure_independent_source(repo: Path) -> None:
    if (repo / ".git" / "objects" / "info" / "alternates").exists():
        fail("generated source has a Git alternates dependency")
    refs = run_git(repo, ["for-each-ref", "--format=%(refname)"]).strip()
    if refs:
        fail("generated source unexpectedly contains refs")
    remotes = run_git(repo, ["remote"]).strip()
    if remotes:
        fail("generated source retains a source remote")


def build_stage(
    inputs: dict[str, Any], stage: Path, *, expected_fingerprint: str | None
) -> tuple[str, str, str]:
    marker = stage / ".recipe-stage-owner"
    marker.write_text("tinycast-recipe\n", encoding="utf-8")
    stage.mkdir(exist_ok=True)
    run_git(stage, ["init", "--quiet"])
    configure_repository(stage)
    upstream = inputs["lock"]["upstream"]
    run_git(stage, ["remote", "add", "upstream", upstream["url"]])
    run_git(stage, ["fetch", "--no-tags", "--no-prune", "upstream", upstream["commit"]])
    verify_commit(stage, upstream["commit"], "upstream")
    run_git(stage, ["checkout", "--quiet", "--detach", upstream["commit"]])
    run_git(stage, ["remote", "remove", "upstream"])

    if (stage / ".mine").exists() or (stage / "Makefile").exists():
        fail("generated source contains recipe tooling")
    marker.unlink()
    base = repository_commit(stage, "tinycast: materialize source-only base")

    patches = [str(path.resolve()) for path in inputs["patches"]]
    if patches:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(stage),
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgSign=false",
                "am",
                "--3way",
                "--no-verify",
                "--whitespace=nowarn",
                *patches,
            ],
            check=False,
            env=git_env(commit_identity=True),
            stdout=sys.stderr,
        )
        if result.returncode:
            subprocess.run(
                ["git", "-C", str(stage), "am", "--abort"],
                check=False,
                env=git_env(commit_identity=True),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            fail("fork patch replay failed; the previous published source was retained")
    if run_git(stage, ["status", "--porcelain=v1", "--untracked-files=all"]).strip():
        fail("generated source is dirty after patch replay")
    ensure_independent_source(stage)
    managed_tip = run_git(stage, ["rev-parse", "HEAD"]).strip()
    fingerprint = source_fingerprint(stage)
    if expected_fingerprint is not None and fingerprint != expected_fingerprint:
        fail(f"generated source fingerprint {fingerprint} does not match locked {expected_fingerprint}")
    receipt = {
        "schema": RECEIPT_SCHEMA,
        "input": {
            "lock_sha256": inputs["lock_sha256"],
            "patch_digest": inputs["patch_digest"],
            "recipe_sha256": inputs["recipe_sha256"],
            "input_digest": inputs["input_digest"],
        },
        "locked": {
            "upstream": inputs["lock"]["upstream"]["commit"],
            "release_version": inputs["lock"]["upstream"]["release_version"],
        },
        "patches": inputs["patch_records"],
        "source_only_base_checkpoint": base,
        "managed_tip": managed_tip,
        "source_fingerprint": fingerprint,
    }
    receipt_path = stage / ".git" / RECEIPT_NAME
    temporary_receipt = receipt_path.with_name(receipt_path.name + ".tmp")
    temporary_receipt.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary_receipt, receipt_path)
    return base, managed_tip, fingerprint


def encode_lock(lock: dict[str, Any]) -> bytes:
    return (json.dumps(lock, indent=2, sort_keys=False) + "\n").encode("utf-8")


def inputs_for_lock(base: dict[str, Any], lock: dict[str, Any], lock_bytes: bytes) -> dict[str, Any]:
    return {
        "lock": lock,
        "lock_sha256": sha256_bytes(lock_bytes),
        "patches": base["patches"],
        "patch_records": base["patch_records"],
        "patch_digest": base["patch_digest"],
        "recipe_sha256": base["recipe_sha256"],
        "input_digest": input_digest(lock_bytes, base["patch_digest"], base["recipe_sha256"]),
    }


def semantic_version_key(version: str) -> tuple[Any, ...]:
    core, separator, prerelease = version.partition("-")
    numbers = tuple(int(part) for part in core.split("."))
    if not separator:
        return numbers + ((1, ()),)
    identifiers: list[tuple[int, Any]] = []
    for identifier in prerelease.split("."):
        if identifier.isdigit():
            identifiers.append((0, int(identifier)))
        else:
            identifiers.append((1, identifier))
    return numbers + ((0, tuple(identifiers)),)


def discover_repository(workspace: Path, url: str, label: str) -> tuple[Path, str]:
    repository = workspace / f"{label}.git"
    repository.mkdir()
    run_git(repository, ["init", "--bare", "--quiet"])
    configure_repository(repository)
    run_git(repository, ["remote", "add", "origin", url])
    lines = run_git(repository, ["ls-remote", "--exit-code", "origin", "refs/heads/main"]).splitlines()
    records = [line.split() for line in lines if line.split() and line.split()[-1] == "refs/heads/main"]
    if len(records) != 1 or len(records[0]) != 2:
        fail(f"{label} discovery did not return exactly one main commit")
    head = require_sha(records[0][0], f"{label} main")
    run_git(repository, ["fetch", "--no-tags", "--no-prune", "origin", head])
    verify_commit(repository, head, f"{label} main")
    return repository, head


def fetch_discovered_commit(repository: Path, commit: str, label: str, *, remote: str = "origin") -> None:
    run_git(repository, ["fetch", "--no-tags", "--no-prune", remote, commit])
    verify_commit(repository, commit, label)


def fetch_discovered_tags(repository: Path) -> None:
    run_git(repository, ["fetch", "--no-prune", "origin", "refs/tags/*:refs/tags/*"])


def reachable_release(repository: Path, commit: str, label: str) -> tuple[str, str]:
    candidates: list[tuple[tuple[Any, ...], str, str]] = []
    for tag in run_git(repository, ["tag", "--merged", commit, "--list", "v*"]).splitlines():
        if not isinstance(tag, str) or not tag.startswith("v") or not VERSION_RE.fullmatch(tag[1:]):
            continue
        tag_commit = revision_commit(repository, tag)
        if tag_commit is None or not is_ancestor(repository, tag_commit, commit):
            continue
        candidates.append((semantic_version_key(tag[1:]), tag, tag_commit))
    if not candidates:
        fail(f"{label} has no reachable semantic release tag")
    _, tag, _ = max(candidates, key=lambda item: (item[0], item[1]))
    return tag, tag[1:]


def selected_lock(current: dict[str, Any], upstream_commit: str, release_tag: str) -> dict[str, Any]:
    lock = json.loads(json.dumps(current["lock"]))
    lock["upstream"]["commit"] = upstream_commit
    lock["upstream"]["release_tag"] = release_tag
    lock["upstream"]["release_version"] = release_tag[1:]
    return lock


def source_state_token(inputs: dict[str, Any]) -> tuple[Any, ...] | None:
    if not SOURCE.exists() and not SOURCE.is_symlink():
        return None
    _, _, state = inspect_existing(SOURCE, inputs)
    if state["unexported_changes"]:
        fail("generated source has unexported local changes; save or preserve them before update")
    return (
        state["head"],
        state["worktree_dirty"],
        tuple(state["refs"]),
        tuple(state["unrepresented_refs"]),
    )


def reject_pending_update_state() -> None:
    if SAVE_JOURNAL.exists() or source_save_artifacts():
        fail("source save recovery is pending; resolve it before update")
    for prefix in (STAGE_PREFIX, OLD_PREFIX):
        pending = sorted(BUILD.glob(prefix + "*"))
        if pending:
            fail(f"source preparation recovery is pending: {pending[0]}")


def lock_has_unstaged_edits() -> bool:
    if staged_export_paths(ROOT):
        fail("root has staged lock or patch edits; preserve them and retry update")
    status = run_git(
        ROOT,
        ["status", "--porcelain=v1", "--untracked-files=all", "--", ".mine/sources.lock.json"],
    ).splitlines()
    return any(line and not line.startswith("?? ") for line in status)


def update_preflight(inputs: dict[str, Any]) -> tuple[str, tuple[Any, ...] | None]:
    reject_pending_update_state()
    lock_has_unstaged_edits()
    token = source_state_token(inputs)
    return inputs["lock_sha256"], token


def recheck_update_state(
    inputs: dict[str, Any], old_lock_sha: str, old_patch_sha: str, source_token: tuple[Any, ...] | None
) -> dict[str, Any]:
    reject_pending_update_state()
    lock_has_unstaged_edits()
    current = load_inputs()
    if current["lock_sha256"] != old_lock_sha or current["patch_digest"] != old_patch_sha:
        fail("locked recipe inputs changed during update; previous lock was retained")
    current_token = source_state_token(current)
    if current_token != source_token:
        fail("generated source ownership changed during update; previous lock was retained")
    return current


def select_sources(current: dict[str, Any], workspace: Path) -> tuple[str, str, str]:
    upstream_repository, upstream_head = discover_repository(workspace, current["lock"]["upstream"]["url"], "upstream")
    fetch_discovered_tags(upstream_repository)
    release_tag, _release_version = reachable_release(upstream_repository, upstream_head, "official Tinycast upstream")
    return (
        current["lock"]["upstream"]["url"],
        upstream_head,
        release_tag,
    )


def update() -> dict[str, Any]:
    ensure_build_root()
    with RecipeLock(BUILD / ".recipe.lock", "update"):
        current = load_inputs()
        old_lock_sha, source_token = update_preflight(current)
        operation_root = Path(tempfile.mkdtemp(prefix=OPERATION_PREFIX, dir=BUILD))
        (operation_root / ".recipe-operation-owner").write_text("tinycast-recipe\n", encoding="utf-8")
        try:
            upstream_url, upstream_commit, release_tag = select_sources(current, operation_root)
            lock = selected_lock(current, upstream_commit, release_tag)
            lock["upstream"]["url"] = upstream_url
            candidate_lock_bytes = encode_lock(lock)
            candidate_inputs = inputs_for_lock(current, lock, candidate_lock_bytes)
            stage = operation_root / "candidate"
            stage.mkdir()
            _, _, fingerprint = build_stage(candidate_inputs, stage, expected_fingerprint=None)
            lock["expected_source"]["fingerprint"] = fingerprint
            new_lock_bytes = encode_lock(lock)
            current = recheck_update_state(current, old_lock_sha, current["patch_digest"], source_token)
            if lock == current["lock"] and fingerprint == current["lock"]["expected_source"]["fingerprint"]:
                return {
                    "operation": "update",
                    "changed": False,
                    "upstream_commit": upstream_commit,
                    "release_tag": release_tag,
                    "release_version": release_tag[1:],
                    "expected_source": fingerprint,
                    "cache": "unchanged",
                }
            if lock_has_unstaged_edits():
                fail("sources.lock.json has pre-existing edits; preserve them and retry update")
            atomic_write(LOCK_PATH, new_lock_bytes)
            return {
                "operation": "update",
                "changed": True,
                "upstream_commit": upstream_commit,
                "release_tag": release_tag,
                "release_version": release_tag[1:],
                "expected_source": fingerprint,
                "cache": "stale; run make prepare",
            }
        finally:
            remove_owned(operation_root)


def load_space_radar() -> dict[str, str]:
    radar = require_keys(
        parse_json(read_bytes(SPACE_RADAR_PATH, "space-radar.json"), "space-radar.json"),
        {"url", "adopted_commit"},
        "space-radar.json",
    )
    require_url(radar["url"], "space-radar.url")
    require_sha(radar["adopted_commit"], "space-radar.adopted_commit")
    return radar


def space_recorded_upstream(repository: Path, commit: str) -> str:
    try:
        value = run_git(repository, ["show", f"{commit}:.space/UPSTREAM"]).strip()
    except RecipeError:
        fail("Space head has no readable .space/UPSTREAM")
    return require_sha(value, "Space .space/UPSTREAM")


def space_patch_changes(
    repository: Path, adopted_commit: str, head: str
) -> tuple[dict[str, list[str]], bool]:
    raw = run_git(
        repository,
        [
            "diff",
            "--name-status",
            "--no-renames",
            "-z",
            adopted_commit,
            head,
            "--",
            ".space/patches",
        ],
    )
    changes = {"added": [], "modified": [], "removed": []}
    status_names = {"A": "added", "M": "modified", "D": "removed"}
    records = [record for record in raw.split("\0") if record]
    if len(records) % 2:
        fail("Space .space/patches diff has a malformed Git record")
    pairs = zip(records[::2], records[1::2])
    for status, path in list(pairs)[:MAX_SPACE_PATCH_CHANGES]:
        category = status_names.get(status)
        if category is None:
            fail(f"Space .space/patches diff has unsupported status {status!r}")
        changes[category].append(path)
    return changes, len(records) > MAX_SPACE_PATCH_CHANGES


def check_space() -> dict[str, Any]:
    ensure_build_root()
    with RecipeLock(BUILD / ".recipe.lock", "check-space"):
        radar = load_space_radar()
        workspace = Path(tempfile.mkdtemp(prefix="tinycast-space-radar-", dir=BUILD))
        try:
            repository, head = discover_repository(workspace, radar["url"], "space-radar")
            fetch_discovered_commit(repository, radar["adopted_commit"], "adopted Space commit")
            patches, patches_truncated = space_patch_changes(repository, radar["adopted_commit"], head)
            return {
                **radar,
                "head": head,
                "upstream": space_recorded_upstream(repository, head),
                "patches": patches,
                "patches_truncated": patches_truncated,
            }
        finally:
            remove_owned(workspace)


def open_owned_regular(path: Path, label: str, flags: int) -> int:
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    if not no_follow:
        fail(f"{label} cannot be opened without following symlinks")
    try:
        descriptor = os.open(
            path,
            flags | no_follow | getattr(os, "O_CLOEXEC", 0) | os.O_NONBLOCK,
            0o600,
        )
    except OSError as error:
        fail(f"cannot open {label} safely: {error}")
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            fail(f"{label} is not a private regular file: {path}")
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


class RecipeLock:
    def __init__(self, path: Path, operation: str, *, blocking: bool = True) -> None:
        self.path = path
        self.operation = operation
        self.blocking = blocking
        self.handle: Any = None

    def __enter__(self) -> "RecipeLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = open_owned_regular(self.path, "recipe lock", os.O_RDWR | os.O_CREAT)
        self.handle = os.fdopen(descriptor, "r+", encoding="utf-8")
        flags = fcntl.LOCK_EX
        if not self.blocking:
            flags |= fcntl.LOCK_NB
        try:
            fcntl.flock(self.handle.fileno(), flags)
        except BlockingIOError:
            self.handle.close()
            self.handle = None
            raise
        except OSError as error:
            self.handle.close()
            self.handle = None
            fail(f"cannot lock recipe lock: {error}")
        self.handle.seek(0)
        self.handle.truncate()
        self.handle.write(json.dumps({"owner": "tinycast-recipe", "operation": self.operation}) + "\n")
        self.handle.flush()
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        if self.handle is not None:
            self.handle.seek(0)
            self.handle.truncate()
            self.handle.flush()
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
            self.handle.close()


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with temporary.open("wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def remove_owned(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def directory_digest(path: Path) -> str | None:
    if path.is_symlink() or not path.is_dir():
        return None
    digest = hashlib.sha256()
    for entry in sorted(path.iterdir(), key=lambda item: item.name):
        if entry.is_symlink() or not entry.is_file():
            return None
        data = read_bytes(entry, f"file {entry.name}")
        name = entry.name.encode("utf-8")
        digest.update(len(name).to_bytes(8, "big"))
        digest.update(name)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def validate_patch_directory_for_save(path: Path) -> None:
    if path.is_symlink() or not path.is_dir():
        fail("patch directory is missing or is a symlink")
    for entry in path.iterdir():
        if entry.is_symlink() or not entry.is_file():
            fail(f"patch directory contains a non-file entry: {entry.name}")
        if entry.name != ".gitkeep" and not PATCH_NAME_RE.fullmatch(entry.name):
            fail(f"patch directory contains an unexpected file: {entry.name}")


def export_path(path: str) -> bool:
    return path == ".mine/sources.lock.json" or path.startswith(".mine/patches/")


def index_snapshot(repo: Path) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "-s", "-z"],
        check=False,
        env=git_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        fail(f"cannot snapshot the recipe Git index: {result.stderr.decode(errors='replace').strip()}")
    records = []
    for record in result.stdout.split(b"\0"):
        if not record:
            continue
        try:
            path = record.split(b"\t", 1)[1].decode("utf-8")
        except (IndexError, UnicodeDecodeError):
            fail("recipe Git index contains a malformed record")
        if not export_path(path):
            records.append(record)
    return b"\0".join(records)


def staged_export_paths(repo: Path) -> list[str]:
    names = run_git(repo, ["diff", "--cached", "--name-only", "--", ".mine/patches", ".mine/sources.lock.json"])
    return [name for name in names.splitlines() if name]


def write_save_journal(journal: dict[str, Any]) -> None:
    atomic_write(SAVE_JOURNAL, (json.dumps(journal, indent=2, sort_keys=True) + "\n").encode("utf-8"))


def save_journal_paths(transaction: Path) -> dict[str, str]:
    return {
        "transaction": str(transaction),
        "patch_dir": str(PATCH_DIR),
        "lock": str(LOCK_PATH),
        "receipt": str(source_receipt_path(SOURCE)),
    }


def validate_save_journal(journal: Any) -> dict[str, Any]:
    value = require_keys(
        journal,
        {
            "schema",
            "state",
            "source_head",
            "paths",
            "old",
            "new",
        },
        "source save journal",
    )
    if value["schema"] != SAVE_JOURNAL_SCHEMA:
        fail("unsupported source save journal")
    if value["state"] not in SAVE_JOURNAL_STATES:
        fail("malformed source save journal: unsupported state")
    for key in ("source_head",):
        require_sha(value[key], f"source save journal.{key}")
    paths = require_keys(value["paths"], {"transaction", "patch_dir", "lock", "receipt"}, "source save journal.paths")
    for key in ("transaction", "patch_dir", "lock", "receipt"):
        if not isinstance(paths[key], str) or not Path(paths[key]).is_absolute():
            fail(f"malformed source save journal.paths.{key}: expected an absolute path")
    transaction = Path(paths["transaction"])
    if transaction.parent.resolve() != BUILD.resolve() or not transaction.name.startswith(SAVE_PREFIX):
        fail("source save journal transaction is outside .build")
    if Path(paths["patch_dir"]).resolve() != PATCH_DIR.resolve() or Path(paths["lock"]).resolve() != LOCK_PATH.resolve():
        fail("source save journal paths do not match this recipe")
    if Path(paths["receipt"]).resolve() != source_receipt_path(SOURCE).resolve():
        fail("source save journal receipt path does not match this source")
    for label in ("old", "new"):
        record = require_keys(
            value[label],
            {"patch_tree", "lock", "receipt"},
            f"source save journal.{label}",
        )
        for key in record:
            if not isinstance(record[key], str) or not re.fullmatch(r"[0-9a-f]{64}", record[key]):
                fail(f"malformed source save journal.{label}.{key}")
    return value


def source_save_artifacts() -> list[Path]:
    return [
        path
        for path in BUILD.glob(SAVE_PREFIX + "*")
        if path.name != SAVE_JOURNAL.name and path.is_dir()
    ]


def read_verified_snapshot(path: Path, label: str, expected: str) -> bytes:
    if not path.is_file():
        fail(f"interrupted source save is missing its {label}")
    descriptor = open_owned_regular(path, label, os.O_RDONLY)
    with os.fdopen(descriptor, "rb") as handle:
        data = handle.read()
    if sha256_bytes(data) != expected:
        fail(f"interrupted source save has a corrupt {label}; previous files were retained")
    return data


def stage_verified_patch_snapshot(source: Path, expected: str, transaction: Path) -> Path:
    if source.is_symlink() or not source.is_dir():
        fail("interrupted source save is missing its rollback patch snapshot")
    staging = Path(tempfile.mkdtemp(prefix="verified-patches-", dir=transaction))
    try:
        staging.chmod(stat.S_IMODE(source.stat().st_mode))
        digest = hashlib.sha256()
        for entry in sorted(source.iterdir(), key=lambda item: item.name):
            if entry.is_symlink() or not entry.is_file():
                fail(f"interrupted source save rollback patch snapshot has an unsafe entry: {entry.name}")
            if entry.name != ".gitkeep" and not PATCH_NAME_RE.fullmatch(entry.name):
                fail(f"interrupted source save rollback patch snapshot has an unexpected file: {entry.name}")
            descriptor = open_owned_regular(entry, f"rollback patch {entry.name}", os.O_RDONLY)
            with os.fdopen(descriptor, "rb") as handle:
                data = handle.read()
            target = staging / entry.name
            target.write_bytes(data)
            target.chmod(stat.S_IMODE(entry.stat().st_mode))
            name = entry.name.encode("utf-8")
            digest.update(len(name).to_bytes(8, "big"))
            digest.update(name)
            digest.update(len(data).to_bytes(8, "big"))
            digest.update(data)
        if digest.hexdigest() != expected:
            fail("interrupted source save has a corrupt rollback patch snapshot; previous files were retained")
        return staging
    except BaseException:
        remove_owned(staging)
        raise


def recover_save_transaction() -> None:
    if SAVE_JOURNAL.is_symlink():
        fail("source save journal is a symlink")
    if not SAVE_JOURNAL.exists():
        for transaction in source_save_artifacts():
            marker = transaction / ".recipe-save-owner"
            if not marker.is_file() or marker.read_text(encoding="utf-8") != "tinycast-recipe-save\n":
                fail(f"unowned source save staging requires recovery: {transaction}")
            remove_owned(transaction)
        return
    journal = validate_save_journal(parse_json(read_bytes(SAVE_JOURNAL, "source save journal"), "source save journal"))
    transaction = Path(journal["paths"]["transaction"])
    if transaction.is_symlink() or not transaction.is_dir() or (transaction / ".recipe-save-owner").read_text(encoding="utf-8") != "tinycast-recipe-save\n":
        fail("source save journal staging directory is missing or unowned")
    extra = [path for path in source_save_artifacts() if path.resolve() != transaction.resolve()]
    if extra:
        fail(f"multiple source save transactions require recovery: {extra[0]}")
    if revision_commit(SOURCE, "HEAD") != journal["source_head"]:
        fail("source changed during interrupted save; recover manually before retrying")
    if run_git(SOURCE, ["status", "--porcelain=v1", "--untracked-files=all"]).strip():
        fail("source has newer working-tree data during interrupted save; recover manually before retrying")
    if PATCH_DIR.is_symlink() or (PATCH_DIR.exists() and not PATCH_DIR.is_dir()):
        fail("source patch directory is unsafe during interrupted save")
    patch_missing = not PATCH_DIR.exists() and not PATCH_DIR.is_symlink()
    current_patch_tree = None if patch_missing else directory_digest(PATCH_DIR)
    if not patch_missing and current_patch_tree is None:
        fail("source patch directory is unsafe during interrupted save")
    receipt_path = source_receipt_path(SOURCE)
    current = {
        "patch_tree": current_patch_tree,
        "lock": sha256_bytes(read_bytes(LOCK_PATH, "sources.lock.json")) if LOCK_PATH.is_file() else None,
        "receipt": sha256_bytes(read_bytes(receipt_path, "recipe receipt")) if receipt_path.is_file() else None,
    }
    old = journal["old"]
    new = journal["new"]
    old_match = all(current[key] == old[key] for key in current)
    new_match = all(current[key] == new[key] for key in current)
    missing_patch_window = (
        current["patch_tree"] is None
        and current["lock"] == old["lock"]
        and current["receipt"] == old["receipt"]
    )
    if not old_match and not new_match and not missing_patch_window and not all(
        current[key] in (old[key], new[key]) for key in current
    ):
        fail("interrupted source save has newer edits; refusing to overwrite them")
    if old_match or new_match:
        SAVE_JOURNAL.unlink()
        remove_owned(transaction)
        return
    if staged_export_paths(ROOT):
        fail("interrupted source save has staged export-owned files; resolve them before recovery")
    previous_patches = transaction / "previous-patches"
    old_lock = transaction / "old-lock"
    old_receipt = transaction / "old-receipt"
    old_lock_bytes = read_verified_snapshot(old_lock, "rollback lock snapshot", old["lock"])
    old_receipt_bytes = read_verified_snapshot(old_receipt, "rollback receipt snapshot", old["receipt"])
    staged_patches = stage_verified_patch_snapshot(previous_patches, old["patch_tree"], transaction)
    try:
        if PATCH_DIR.exists() or PATCH_DIR.is_symlink():
            if directory_digest(PATCH_DIR) != current["patch_tree"]:
                fail("source patch directory changed during recovery; previous files were retained")
            remove_owned(PATCH_DIR)
        os.replace(staged_patches, PATCH_DIR)
        staged_patches = None
        atomic_write(LOCK_PATH, old_lock_bytes)
        atomic_write(receipt_path, old_receipt_bytes)
        SAVE_JOURNAL.unlink()
        remove_owned(transaction)
    finally:
        if staged_patches is not None:
            remove_owned(staged_patches)


def export_candidate(source: Path, base: str, head: str, destination: Path) -> list[Path]:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(source),
            "format-patch",
            "--quiet",
            "--zero-commit",
            "-N",
            "-o",
            str(destination),
            f"{base}..{head}",
            "--",
            ".",
            ":!.mine",
            ":!Makefile",
        ],
        check=False,
        env=git_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        fail(f"source patch export failed: {result.stderr.strip()}")
    patches = sorted(destination.glob("*.patch"), key=lambda path: path.name)
    commit_count = len(run_git(source, ["rev-list", f"{base}..{head}"]).splitlines())
    if len(patches) != commit_count:
        fail("source patch export omitted a commit outside the recipe export contract")
    for patch in patches:
        if patch.is_symlink() or not patch.is_file() or not PATCH_NAME_RE.fullmatch(patch.name):
            fail(f"source patch export produced an unsafe patch: {patch.name}")
    if (PATCH_DIR / ".gitkeep").is_file():
        shutil.copy2(PATCH_DIR / ".gitkeep", destination / ".gitkeep")
    return patches


def validate_export_candidate(
    source: Path, base: str, authored_fingerprint: str, candidate: Path, patches: list[Path]
) -> None:
    validation = candidate.parent / "validation"
    result = subprocess.run(
        ["git", "clone", "--quiet", "--no-local", str(source), str(validation)],
        check=False,
        env=git_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        fail(f"source export validation clone failed: {result.stderr.strip()}")
    try:
        configure_repository(validation)
        run_git(validation, ["checkout", "--quiet", "--detach", base])
        run_git(validation, ["remote", "remove", "origin"])
        if run_git(validation, ["rev-parse", "HEAD"]).strip() != base:
            fail("source export validation did not start at the source-only checkpoint")
        if patches:
            replay = subprocess.run(
                [
                    "git",
                    "-C",
                    str(validation),
                    "am",
                    "--3way",
                    "--no-verify",
                    "--whitespace=nowarn",
                    *(str(path) for path in patches),
                ],
                check=False,
                env=git_env(commit_identity=True),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            if replay.returncode:
                subprocess.run(
                    ["git", "-C", str(validation), "am", "--abort"],
                    check=False,
                    env=git_env(commit_identity=True),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                fail(f"source export validation patch replay conflicted: {replay.stderr.strip()}")
        if run_git(validation, ["status", "--porcelain=v1", "--untracked-files=all"]).strip():
            fail("source export validation clone is dirty after replay")
        actual = source_fingerprint(validation)
        if actual != authored_fingerprint:
            fail(f"source export fingerprint mismatch: replayed {actual}, authored {authored_fingerprint}")
    finally:
        if validation.exists():
            remove_owned(validation)


def new_lock_bytes(lock_bytes: bytes, old_fingerprint: str, fingerprint: str) -> bytes:
    if old_fingerprint == fingerprint:
        return lock_bytes
    old = old_fingerprint.encode("ascii")
    if lock_bytes.count(old) != 1:
        fail("sources.lock.json expected fingerprint is not uniquely identifiable")
    return lock_bytes.replace(old, fingerprint.encode("ascii"), 1)


def receipt_bytes(
    inputs: dict[str, Any],
    lock_bytes: bytes,
    patch_sha: str,
    patch_records: list[dict[str, Any]],
    base: str,
    managed_tip: str,
    fingerprint: str,
) -> bytes:
    lock_sha = sha256_bytes(lock_bytes)
    receipt = {
        "schema": RECEIPT_SCHEMA,
        "input": {
            "lock_sha256": lock_sha,
            "patch_digest": patch_sha,
            "recipe_sha256": inputs["recipe_sha256"],
            "input_digest": input_digest(lock_bytes, patch_sha, inputs["recipe_sha256"]),
        },
        "locked": {
            "upstream": inputs["lock"]["upstream"]["commit"],
            "release_version": inputs["lock"]["upstream"]["release_version"],
        },
        "patches": patch_records,
        "source_only_base_checkpoint": base,
        "managed_tip": managed_tip,
        "source_fingerprint": fingerprint,
    }
    return (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode("utf-8")


def validate_source_for_save(
    source: Path, inputs: dict[str, Any], *, allow_rewrite: bool = False
) -> tuple[dict[str, Any], dict[str, Any], str, str]:
    if not source.exists() or source.is_symlink():
        fail("generated source is missing; run make prepare before make save")
    receipt, _inputs_current, state = inspect_existing(source, inputs, allow_rewrite=allow_rewrite)
    if state["worktree_dirty"]:
        fail("generated source has uncommitted, untracked changes; commit product edits first")
    if state["unrepresented_refs"]:
        fail(
            "generated source has unique branches or stashes; preserve them and export only the current committed source: "
            + ", ".join(state["unrepresented_refs"])
        )
    if receipt["input"]["lock_sha256"] != inputs["lock_sha256"] or receipt["input"]["patch_digest"] != inputs["patch_digest"]:
        fail("authoritative lock or patch inputs changed since the generated source was prepared")
    expected_locked = {
        "upstream": inputs["lock"]["upstream"]["commit"],
        "release_version": inputs["lock"]["upstream"]["release_version"],
    }
    if receipt["locked"] != expected_locked:
        fail("generated source receipt identities disagree with authoritative lock inputs")
    base = receipt["source_only_base_checkpoint"]
    managed_tip = receipt["managed_tip"]
    if not is_ancestor(source, base, managed_tip):
        fail("generated source receipt checkpoint is not an ancestor of its managed tip")
    if any(path == "Makefile" or path.startswith(".mine/") for _, _, _, path in safe_git_tree(source, base)):
        fail("generated source receipt checkpoint contains recipe tooling")
    if source_fingerprint(source, managed_tip) != inputs["lock"]["expected_source"]["fingerprint"]:
        fail("generated source managed tip disagrees with the authoritative fingerprint")
    head = state["head"]
    if run_git(source, ["rev-list", "--merges", f"{base}..{head}"]).strip():
        fail("source export does not support merge commits; preserve the source and resolve manually")
    return receipt, state, base, head


def publish_save(
    transaction: Path,
    source_head: str,
    old_patch_tree: str,
    old_lock_sha: str,
    old_receipt_sha: str,
    new_patch_tree: str,
    new_lock_sha: str,
    new_receipt_sha: str,
    new_lock: bytes,
    new_receipt: bytes,
) -> None:
    old_lock = read_bytes(LOCK_PATH, "sources.lock.json")
    old_receipt = read_bytes(source_receipt_path(SOURCE), "recipe receipt")
    if (
        directory_digest(PATCH_DIR) != old_patch_tree
        or sha256_bytes(old_lock) != old_lock_sha
        or sha256_bytes(old_receipt) != old_receipt_sha
    ):
        fail("source save inputs changed before publication; previous files were retained")
    previous_patches = transaction / "previous-patches"
    new_patches = transaction / "new-patches"
    old_lock_path = transaction / "old-lock"
    new_lock_path = transaction / "new-lock"
    old_receipt_path = transaction / "old-receipt"
    new_receipt_path = transaction / "new-receipt"
    shutil.copytree(transaction / "candidate", new_patches)
    old_lock_path.write_bytes(old_lock)
    new_lock_path.write_bytes(new_lock)
    old_receipt_path.write_bytes(old_receipt)
    new_receipt_path.write_bytes(new_receipt)
    journal = {
        "schema": SAVE_JOURNAL_SCHEMA,
        "state": "prepared",
        "source_head": source_head,
        "paths": save_journal_paths(transaction),
        "old": {"patch_tree": old_patch_tree, "lock": old_lock_sha, "receipt": old_receipt_sha},
        "new": {"patch_tree": new_patch_tree, "lock": new_lock_sha, "receipt": new_receipt_sha},
    }
    write_save_journal(journal)
    try:
        os.replace(PATCH_DIR, transaction / "previous-patches")
        journal["state"] = "old-patches-moved"
        write_save_journal(journal)
        os.replace(new_patches, PATCH_DIR)
        journal["state"] = "patches-published"
        write_save_journal(journal)
        os.replace(new_lock_path, LOCK_PATH)
        journal["state"] = "lock-published"
        write_save_journal(journal)
        os.replace(new_receipt_path, source_receipt_path(SOURCE))
        journal["state"] = "receipt-published"
        write_save_journal(journal)
    except BaseException as error:
        try:
            recover_save_transaction()
        except RecipeError as recovery_error:
            fail(f"source save publication failed: {error}; recovery stopped: {recovery_error}")
        fail(f"source save publication failed; previous state was restored: {error}")


def commit_saved_paths() -> bool:
    before = index_snapshot(ROOT)
    if staged_export_paths(ROOT):
        fail("export-owned files are already staged; preserve them and retry make save")
    run_git(ROOT, ["add", "-A", "--", ".mine/patches", ".mine/sources.lock.json"])
    if subprocess.run(
        ["git", "-C", str(ROOT), "diff", "--cached", "--quiet", "--", ".mine/patches", ".mine/sources.lock.json"],
        check=False,
        env=git_env(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0:
        return False
    result = subprocess.run(
        [
            "git",
            "-C",
            str(ROOT),
            "commit",
            "--only",
            "--quiet",
            "-m",
            "mine: save patches",
            "--",
            ".mine/patches",
            ".mine/sources.lock.json",
        ],
        check=False,
        env=git_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        fail(f"source export published but commit failed; files remain recoverable: {result.stderr.strip()}")
    if index_snapshot(ROOT) != before:
        fail("source export commit changed unrelated staged index entries")
    return True


def save(*, rewrite: bool = False) -> dict[str, Any]:
    ensure_build_root()
    with RecipeLock(BUILD / ".recipe.lock", "save"):
        recover_save_transaction()
        inputs = load_inputs()
        if staged_export_paths(ROOT):
            fail("export-owned files are already staged; preserve them and retry make save")
        if any(path for prefix in (STAGE_PREFIX, OLD_PREFIX) for path in BUILD.glob(prefix + "*")):
            fail("source preparation has pending recovery; resolve it before make save")
        validate_patch_directory_for_save(PATCH_DIR)
        receipt, state, base, head = validate_source_for_save(SOURCE, inputs, allow_rewrite=rewrite)
        if head == receipt["managed_tip"]:
            return {"exported": False, "committed": False, "source_head": head}
        initial_patch_tree = directory_digest(PATCH_DIR)
        initial_receipt_sha = sha256_bytes(read_bytes(source_receipt_path(SOURCE), "recipe receipt"))
        if initial_patch_tree is None:
            fail("source patch publication has an unsafe directory")

        transaction = Path(tempfile.mkdtemp(prefix=SAVE_PREFIX, dir=BUILD))
        (transaction / ".recipe-save-owner").write_text("tinycast-recipe-save\n", encoding="utf-8")
        try:
            candidate = transaction / "candidate"
            candidate.mkdir()
            patches = export_candidate(SOURCE, base, head, candidate)
            patch_sha, patch_records = patch_digest(sorted(candidate.glob("*.patch"), key=lambda path: path.name))
            authored_fingerprint = source_fingerprint(SOURCE, head)
            validate_export_candidate(SOURCE, base, authored_fingerprint, candidate, patches)
            current_inputs = load_inputs()
            if (
                current_inputs["lock_sha256"] != inputs["lock_sha256"]
                or current_inputs["patch_digest"] != inputs["patch_digest"]
            ):
                fail("authoritative recipe inputs changed during save; previous files were retained")
            current_receipt, current_state, current_base, current_head = validate_source_for_save(
                SOURCE, current_inputs, allow_rewrite=rewrite
            )
            if current_head != head or current_base != base or current_receipt["managed_tip"] != receipt["managed_tip"]:
                fail("source or recipe inputs changed during save; previous files were retained")
            if current_state["source_fingerprint"] != authored_fingerprint:
                fail("source changed during save; previous files were retained")
            new_lock = new_lock_bytes(
                read_bytes(LOCK_PATH, "sources.lock.json"),
                current_inputs["lock"]["expected_source"]["fingerprint"],
                authored_fingerprint,
            )
            new_receipt = receipt_bytes(
                current_inputs,
                new_lock,
                patch_sha,
                patch_records,
                base,
                head,
                authored_fingerprint,
            )
            old_lock = read_bytes(LOCK_PATH, "sources.lock.json")
            old_receipt = read_bytes(source_receipt_path(SOURCE), "recipe receipt")
            old_patch_tree = directory_digest(PATCH_DIR)
            new_patch_tree = directory_digest(candidate)
            if old_patch_tree is None or new_patch_tree is None:
                fail("source patch publication has an unsafe directory")
            if (
                old_patch_tree != initial_patch_tree
                or sha256_bytes(old_lock) != current_inputs["lock_sha256"]
                or sha256_bytes(old_receipt) != initial_receipt_sha
            ):
                fail("patch inputs changed during save; previous files were retained")
            publish_save(
                transaction,
                head,
                old_patch_tree,
                sha256_bytes(old_lock),
                sha256_bytes(old_receipt),
                new_patch_tree,
                sha256_bytes(new_lock),
                sha256_bytes(new_receipt),
                new_lock,
                new_receipt,
            )
            committed = commit_saved_paths()
            recover_save_transaction()
            return {
                "exported": True,
                "committed": committed,
                "source_head": head,
                "source_fingerprint": authored_fingerprint,
                "patch_count": len(patches),
            }
        finally:
            if transaction.exists() and not SAVE_JOURNAL.exists():
                remove_owned(transaction)


def finish_guard() -> None:
    if SAVE_JOURNAL.exists() or source_save_artifacts():
        fail("source export recovery is pending")
    for prefix in (STAGE_PREFIX, OLD_PREFIX, BACKUP_PREFIX):
        if any(BUILD.glob(prefix + "*")):
            fail("generated source has retained or incomplete predecessor data")
    if not SOURCE.exists():
        print("finish guard: no prepared source")
        return
    inputs = load_inputs()
    receipt, _inputs_current, state = inspect_existing(SOURCE, inputs)
    if state["ignored_paths"]:
        fail("generated source has ignored files that cleanup would lose: " + ", ".join(state["ignored_paths"]))
    if state["unexported_changes"]:
        fail("generated source has unexported source changes")
    if receipt["input"]["lock_sha256"] != inputs["lock_sha256"] or receipt["input"]["patch_digest"] != inputs["patch_digest"]:
        fail("generated source receipt is not aligned with authoritative lock and patch inputs")
    if receipt["source_fingerprint"] != inputs["lock"]["expected_source"]["fingerprint"]:
        fail("generated source fingerprint is not saved")
    print("finish guard: source saved")


def ensure_build_root() -> None:
    if BUILD.is_symlink():
        fail(".build is a symlink")
    BUILD.mkdir(exist_ok=True)


def prepare_locked() -> dict[str, Any]:
    for stale in sorted(BUILD.glob(STAGE_PREFIX + "*")):
        if not stale.is_dir() or (stale / ".recipe-stage-owner").read_text(encoding="utf-8") != "tinycast-recipe\n":
            fail(f"unowned or malformed staging directory requires recovery: {stale}")
        shutil.rmtree(stale)
    inputs = load_inputs()
    old_backups = sorted(BUILD.glob(OLD_PREFIX + "*"))
    if old_backups:
        if len(old_backups) != 1:
            fail(f"incomplete publication requires recovery before prepare: {old_backups[0]}")
        if SOURCE.exists() or SOURCE.is_symlink():
            inspect_existing(SOURCE, inputs)
            inspect_existing(old_backups[0], inputs)
            retained = BUILD / (BACKUP_PREFIX + next(tempfile._get_candidate_names()))
            os.replace(old_backups[0], retained)
        else:
            inspect_existing(old_backups[0], inputs)
            os.replace(old_backups[0], SOURCE)
    had_source = SOURCE.exists() or SOURCE.is_symlink()
    existing_receipt: dict[str, Any] | None = None
    if had_source:
        receipt, inputs_current, local_state = inspect_existing(SOURCE, inputs)
        existing_receipt = receipt
        fresh = inputs_current and not local_state["unexported_changes"] and receipt["source_fingerprint"] == inputs["lock"]["expected_source"]["fingerprint"]
        if inputs_current:
            return {
                "source_path": str(SOURCE),
                "release_version": inputs["lock"]["upstream"]["release_version"],
                "fresh": fresh,
                "reused": True,
                "source_only_base_checkpoint": receipt["source_only_base_checkpoint"],
                "managed_tip": receipt["managed_tip"],
                "source_state": local_state,
            }
        if local_state["unexported_changes"]:
            fail("locked recipe inputs changed while generated source has unexported local changes")
    stage = Path(tempfile.mkdtemp(prefix=STAGE_PREFIX, dir=BUILD))
    published = False
    try:
        base, managed_tip, fingerprint = build_stage(
            inputs,
            stage,
            expected_fingerprint=inputs["lock"]["expected_source"]["fingerprint"],
        )
        current_inputs = load_inputs()
        if current_inputs["input_digest"] != inputs["input_digest"]:
            fail("locked recipe inputs changed during prepare; previous source was retained")
        if had_source:
            current_receipt, _, current_state = inspect_existing(SOURCE, current_inputs)
            if current_state["unexported_changes"] or any(
                current_receipt[key] != existing_receipt[key]
                for key in ("source_only_base_checkpoint", "managed_tip")
            ):
                fail("generated source changed during prepare; previous source was retained")
        elif SOURCE.exists() or SOURCE.is_symlink():
            fail("generated source appeared during prepare; refusing to replace it")
        backup: Path | None = None
        retained_backup: Path | None = None
        if SOURCE.exists() or SOURCE.is_symlink():
            backup = BUILD / (OLD_PREFIX + next(tempfile._get_candidate_names()))
            os.replace(SOURCE, backup)
        try:
            os.replace(stage, SOURCE)
            published = True
        except OSError:
            if backup is not None and not SOURCE.exists():
                os.replace(backup, SOURCE)
            raise
        if backup is not None:
            retained_backup = BUILD / (BACKUP_PREFIX + next(tempfile._get_candidate_names()))
            try:
                os.replace(backup, retained_backup)
            except OSError as error:
                fail(f"source published but predecessor backup requires recovery: {error}")
        return {
            "source_path": str(SOURCE),
            "release_version": inputs["lock"]["upstream"]["release_version"],
            "fresh": True,
            "reused": False,
            "source_only_base_checkpoint": base,
            "managed_tip": managed_tip,
            "source_fingerprint": fingerprint,
            "source_state": {
                "head": managed_tip,
                "head_is_managed": True,
                "head_is_descendant": True,
                "worktree_dirty": False,
                "refs": [],
                "unexported_changes": False,
                "source_fingerprint": fingerprint,
            },
            "predecessor_backup": str(retained_backup) if retained_backup is not None else None,
        }
    finally:
        if not published and stage.exists():
            shutil.rmtree(stage)


def prepare() -> dict[str, Any]:
    ensure_build_root()
    with RecipeLock(BUILD / ".recipe.lock", "prepare"):
        return prepare_locked()


def source_file(relative: str, label: str) -> Path:
    path = SOURCE.joinpath(*PurePosixPath(relative).parts)
    if path.is_symlink() or not path.is_file():
        fail(f"generated source is missing {label}: {relative}")
    return path


def run_logged(command: list[str], log_name: str) -> int:
    if LOG_DIR.is_symlink():
        fail(".build/logs is a symlink")
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / log_name
    descriptor = open_owned_regular(log_path, f"log {log_name}", os.O_WRONLY | os.O_CREAT)
    with os.fdopen(descriptor, "w", encoding="utf-8") as log:
        log.truncate(0)
        log.write(f"$ {' '.join(command)}\n")
        log.flush()
        try:
            process = subprocess.Popen(
                command,
                cwd=str(SOURCE),
                env=command_env(),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                errors="replace",
                bufsize=1,
            )
        except OSError as error:
            fail(f"cannot run {command[0]}: {error}")
        assert process.stdout is not None
        try:
            for line in process.stdout:
                log.write(line)
                sys.stderr.write(line)
        except BaseException:
            process.terminate()
            process.wait()
            raise
        finally:
            process.stdout.close()
        return process.wait()


def resolve_sign_identity() -> str:
    requested = os.environ.get("TINYCAST_SIGN_IDENTITY") or DEFAULT_SIGN_IDENTITY
    try:
        result = subprocess.run(
            ["security", "find-identity", "-v", "-p", "codesigning"],
            check=False,
            env=command_env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as error:
        fail(f"cannot inspect code-signing identities: {error}")
    if result.returncode:
        fail(f"cannot inspect code-signing identities: {result.stderr.strip()}")
    for line in result.stdout.splitlines():
        match = re.fullmatch(r'\s*\d+\)\s+([0-9A-Fa-f]+)\s+"(.*)"\s*', line)
        if match is None:
            continue
        identity, name = match.groups()
        if identity == requested or name == requested or name.startswith(requested + ":"):
            print(f"signing with {identity}", file=sys.stderr)
            return identity
    fail(f"no codesigning identity matches {requested!r}")


def verify_signature(product: Path) -> int:
    try:
        result = subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", str(product)],
            check=False,
            cwd=str(SOURCE),
            env=command_env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as error:
        fail(f"cannot verify the built signature: {error}")
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        print(f"recipe: signature verification failed ({result.returncode}): {detail}", file=sys.stderr)
    return result.returncode


def product_path(debug: bool) -> Path:
    configuration = "Debug" if debug else "Release"
    product = DEBUG_PRODUCT if debug else RELEASE_PRODUCT
    return DERIVED_DATA / "Build" / "Products" / configuration / product


def build_source(debug: bool, prepared: dict[str, Any]) -> tuple[int, Path | None]:
    configuration = "Debug" if debug else "Release"
    if not (SOURCE / "Tinycast.xcodeproj" / "project.pbxproj").is_file():
        fail("generated source has no Tinycast.xcodeproj")
    if DERIVED_DATA.is_symlink():
        fail(".build/DerivedData is a symlink")
    command = [
        "xcodebuild",
        "-project",
        str(SOURCE / "Tinycast.xcodeproj"),
        "-scheme",
        "Tinycast",
        "-configuration",
        configuration,
        "-derivedDataPath",
        str(DERIVED_DATA),
        f"MARKETING_VERSION={prepared['release_version']}",
    ]
    if debug:
        command.append("CODE_SIGNING_ALLOWED=NO")
    else:
        identity = resolve_sign_identity()
        command.extend(
            [
                "ARCHS=arm64",
                "ONLY_ACTIVE_ARCH=NO",
                "CODE_SIGN_STYLE=Manual",
                f"CODE_SIGN_IDENTITY={identity}",
                "OTHER_CODE_SIGN_FLAGS=--timestamp=none",
            ]
        )
    command.append("build")
    log_name = "debug-build.log" if debug else "release-build.log"
    status = run_logged(command, log_name)
    if status:
        print(f"recipe: {configuration} build failed ({status}); log: {LOG_DIR / log_name}", file=sys.stderr)
        return status, None
    product = product_path(debug)
    if product.is_symlink() or not product.is_dir():
        fail(f"{configuration} build did not produce {product}")
    if not debug:
        status = verify_signature(product)
        if status:
            return status, None
    print(product)
    return 0, product


def run_install(product: Path) -> int:
    script = MINE / "install.sh"
    if script.is_symlink() or not script.is_file():
        fail("install script is missing or is a symlink")
    status = subprocess.run(
        ["/bin/bash", str(script), str(product)],
        cwd=str(ROOT),
        env=command_env(),
        check=False,
    ).returncode
    if status:
        print(f"recipe: install failed ({status})", file=sys.stderr)
    return status


def run_project_tool(name: str, arguments: list[str]) -> int:
    relative = "Scripts/run-tests.sh" if name == "test" else "Scripts/lint.sh"
    script = source_file(relative, f"{name} script")
    log_name = f"{name}.log"
    status = run_logged(["/bin/bash", str(script), *arguments], log_name)
    if status:
        print(f"recipe: {name} failed ({status}); log: {LOG_DIR / log_name}", file=sys.stderr)
    return status


def report_source(prepared: dict[str, Any]) -> None:
    state = prepared.get("source_state") or {}
    phase = "reused" if prepared.get("reused") else "published"
    changes = "local changes" if state.get("unexported_changes") else "clean"
    print(
        f"source: {prepared['source_path']} ({phase}, {changes}, locked {prepared['release_version']})",
        file=sys.stderr,
    )


def run_command(name: str, arguments: list[str]) -> int:
    ensure_build_root()
    with RecipeLock(BUILD / ".recipe.lock", f"command:{name}"):
        prepared = prepare_locked()
        report_source(prepared)
        if name in ("build", "build-debug"):
            return build_source(name == "build-debug", prepared)[0]
        if name == "install":
            status, product = build_source(False, prepared)
            if status:
                return status
            if product is None:
                fail("Release build did not produce an installable product")
            return run_install(product)
        return run_project_tool(name, arguments)


def status() -> dict[str, Any]:
    if BUILD.is_symlink():
        fail(".build is a symlink")
    inputs = load_inputs()
    result: dict[str, Any] = {
        "source_path": str(SOURCE),
        "release_version": inputs["lock"]["upstream"]["release_version"],
        "fresh": False,
        "operation_owner": "tinycast-recipe",
        "operation_lock": str(BUILD / ".recipe.lock"),
        "operation_busy": False,
    }
    if not BUILD.exists():
        return result
    try:
        with RecipeLock(BUILD / ".recipe.lock", "status", blocking=False):
            if not (SOURCE.exists() or SOURCE.is_symlink()):
                return result
            receipt, inputs_current, local_state = inspect_existing(SOURCE, inputs)
            fresh = inputs_current and not local_state["unexported_changes"] and receipt["source_fingerprint"] == inputs["lock"]["expected_source"]["fingerprint"]
            result.update(
                {
                    "fresh": fresh,
                    "inputs_current": inputs_current,
                    "source_only_base_checkpoint": receipt["source_only_base_checkpoint"],
                    "managed_tip": receipt["managed_tip"],
                    "source_fingerprint": receipt["source_fingerprint"],
                    "source_state": local_state,
                }
            )
    except BlockingIOError:
        result["operation_busy"] = True
    return result


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    rewrite = False
    normalized_argv = []
    for argument in argv:
        if argument == "--rewrite":
            rewrite = True
        else:
            normalized_argv.append(argument)
    parser.add_argument(
        "command",
        choices=("prepare", "status", "save", "finish-guard", "check-space", "update", "command"),
    )
    parser.add_argument("name", nargs="?")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args(normalized_argv)
    try:
        if rewrite and args.command != "save":
            parser.error("--rewrite is only valid with save")
        if args.command == "command":
            if args.name not in TOOL_COMMANDS:
                parser.error("command must be one of: " + ", ".join(TOOL_COMMANDS))
            return run_command(args.name, args.arguments)
        if args.name is not None:
            parser.error(f"{args.command} takes no arguments")
        if args.command == "save":
            result = save(rewrite=rewrite)
        elif args.command == "finish-guard":
            finish_guard()
            return 0
        elif args.command == "check-space":
            result = check_space()
        elif args.command == "update":
            result = update()
        else:
            result = prepare() if args.command == "prepare" else status()
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except RecipeError as error:
        print(f"recipe: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print(f"recipe: command failed: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"recipe: filesystem operation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
