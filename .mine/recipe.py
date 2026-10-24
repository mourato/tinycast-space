#!/usr/bin/env python3
"""Materialize and drive Tinycast from the locked upstream, Space, and fork inputs."""

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
DEFAULT_SIGN_IDENTITY = "Apple Development"
RELEASE_PRODUCT = "Tinycast.app"
DEBUG_PRODUCT = "Tinycast Dev.app"
TOOL_COMMANDS = ("build", "build-debug", "test", "lint")
RECEIPT_SCHEMA = 1
SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
PATCH_NAME_RE = re.compile(r"^[0-9]{4}-[A-Za-z0-9][A-Za-z0-9._-]*\.patch$")
STAGE_PREFIX = ".source-stage-"
OLD_PREFIX = ".source-old-"
BACKUP_PREFIX = ".source-backup-"
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


def require_relative_path(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or "\\" in value:
        fail(f"malformed {label}: expected a relative POSIX path")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        fail(f"malformed {label}: path escapes its declared root")
    return value.rstrip("/")


def load_lock() -> tuple[dict[str, Any], bytes, str]:
    data = read_bytes(LOCK_PATH, "sources.lock.json")
    lock = require_keys(
        parse_json(data, "sources.lock.json"),
        {"schema", "original_reference_revision", "upstream", "space", "expected_source"},
        "sources.lock.json",
    )
    if lock["schema"] != 1:
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

    space = require_keys(
        lock["space"], {"url", "commit", "source_paths"}, "space"
    )
    require_url(space["url"], "space.url")
    require_sha(space["commit"], "space.commit")
    if not isinstance(space["source_paths"], list) or not space["source_paths"]:
        fail("malformed space.source_paths: expected a non-empty list")
    source_paths = [require_relative_path(path, "space.source_paths") for path in space["source_paths"]]
    if len(source_paths) != len(set(source_paths)):
        fail("malformed space.source_paths: duplicate path")
    if source_paths != [".space", ".github/workflows"]:
        fail("malformed space.source_paths: expected .space and .github/workflows")

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


def load_inputs() -> dict[str, Any]:
    lock, lock_bytes, lock_sha = load_lock()
    patches = patch_files()
    patch_sha, patch_records = patch_digest(patches)
    recipe_sha = sha256_bytes(read_bytes(RECIPE_PATH, "recipe.py"))
    input_digest = sha256_bytes(
        b"tinycast-recipe-inputs-v1\0"
        + lock_bytes
        + b"\0"
        + patch_sha.encode("ascii")
        + b"\0"
        + recipe_sha.encode("ascii")
    )
    return {
        "lock": lock,
        "lock_sha256": lock_sha,
        "patches": patches,
        "patch_records": patch_records,
        "patch_digest": patch_sha,
        "recipe_sha256": recipe_sha,
        "input_digest": input_digest,
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


def run_process(command: list[str], cwd: Path, env: dict[str, str]) -> None:
    result = subprocess.run(command, cwd=cwd, env=env, check=False, stdout=sys.stderr)
    if result.returncode:
        fail(f"pipeline command failed ({result.returncode}): {' '.join(command)}")


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
    require_keys(receipt["locked"], {"upstream", "space", "release_version"}, "receipt.locked")
    require_sha(receipt["locked"]["upstream"], "receipt.locked.upstream")
    require_sha(receipt["locked"]["space"], "receipt.locked.space")
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
            "space": inputs["lock"]["space"]["commit"],
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


def inspect_existing(source: Path, inputs: dict[str, Any]) -> tuple[dict[str, Any], bool, dict[str, Any]]:
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
    refs = [line for line in run_git(source, ["for-each-ref", "--format=%(refname)"]).splitlines() if line]
    unreachable = run_git(source, ["fsck", "--no-reflogs", "--unreachable"], check=False).strip()
    if any(line.startswith(("unreachable commit ", "unreachable tree ", "unreachable tag ")) for line in unreachable.splitlines()):
        fail("generated source has unreachable Git objects that may contain unexported work")
    head = run_git(source, ["rev-parse", "--verify", "HEAD^{commit}"]).strip()
    for commit_key in ("source_only_base_checkpoint", "managed_tip"):
        verify_commit(source, receipt[commit_key], f"receipt.{commit_key}")
    if not is_ancestor(source, receipt["managed_tip"], head):
        fail(f"generated source HEAD is outside managed lineage: {head}")
    managed_fingerprint = source_fingerprint(source, receipt["managed_tip"])
    if managed_fingerprint != receipt["source_fingerprint"]:
        fail("generated source fingerprint disagrees with its receipt")
    actual_fingerprint = source_fingerprint(source)
    current = inputs["input_digest"] == receipt["input"]["input_digest"]
    current = current and inputs["lock_sha256"] == receipt["input"]["lock_sha256"]
    current = current and inputs["patch_digest"] == receipt["input"]["patch_digest"]
    current = current and inputs["recipe_sha256"] == receipt["input"]["recipe_sha256"]
    local_state = {
        "head": head,
        "head_is_managed": head == receipt["managed_tip"],
        "head_is_descendant": True,
        "worktree_dirty": bool(status),
        "refs": refs,
        "unexported_changes": bool(status or refs or head != receipt["managed_tip"]),
        "source_fingerprint": actual_fingerprint,
    }
    return receipt, current, local_state


def extraction_records(space_repo: Path, commit: str, roots: list[str]) -> list[tuple[int, str, str]]:
    result = subprocess.run(
        ["git", "-C", str(space_repo), "ls-tree", "-r", "-z", "--full-tree", commit, "--", *roots],
        check=False,
        env=git_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        fail(f"cannot inspect locked Space tree: {result.stderr.decode(errors='replace').strip()}")
    records: list[tuple[int, str, str]] = []
    for raw in result.stdout.split(b"\0"):
        if not raw:
            continue
        try:
            metadata, path_bytes = raw.split(b"\t", 1)
            mode_text, kind, object_id = metadata.decode("ascii").split(" ")
            path = path_bytes.decode("utf-8")
            mode = int(mode_text, 8)
        except (UnicodeDecodeError, ValueError):
            fail("locked Space tree contains a malformed Git record")
        if kind != "blob" or mode not in (0o100644, 0o100755):
            fail(f"locked Space tree contains a symlink or non-file at {path}")
        pure = PurePosixPath(path)
        if pure.is_absolute() or ".." in pure.parts or not any(
            path == root or path.startswith(root + "/") for root in roots
        ):
            fail(f"locked Space path escapes its declared roots: {path}")
        records.append((mode, path, object_id))
    return records


def safe_extract_space(space_repo: Path, commit: str, destination: Path, roots: list[str]) -> None:
    records = extraction_records(space_repo, commit, roots)
    if not any(path == ".space/apply.sh" for _, path, _ in records):
        fail("locked Space snapshot has no .space/apply.sh")
    for root in roots:
        target_root = destination.joinpath(*PurePosixPath(root).parts)
        parent = destination
        for component in PurePosixPath(root).parts[:-1]:
            parent /= component
            if parent.is_symlink():
                fail(f"Space extraction would follow a symlink at {parent}")
            if parent.exists() and not parent.is_dir():
                fail(f"Space extraction path is not a directory: {parent}")
        if target_root.is_symlink():
            fail(f"Space extraction would replace a symlink: {target_root}")
        if target_root.exists() and not target_root.is_dir():
            fail(f"Space extraction root is not a directory: {target_root}")
        if target_root.is_dir():
            shutil.rmtree(target_root)
    for mode, path, object_id in records:
        relative = PurePosixPath(path)
        target = destination.joinpath(*relative.parts)
        current = destination
        for component in relative.parent.parts:
            current /= component
            if current.is_symlink():
                fail(f"Space extraction would follow a symlink at {current}")
            if current.exists() and not current.is_dir():
                fail(f"Space extraction path is not a directory: {current}")
        if target.is_symlink():
            fail(f"Space extraction would overwrite a symlink: {target}")
        if target.exists() and target.is_dir():
            fail(f"Space extraction target is a directory: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        data = subprocess.run(
            ["git", "-C", str(space_repo), "show", f"{commit}:{path}"],
            check=False,
            env=git_env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if data.returncode:
            fail(f"cannot extract locked Space path {path}: {data.stderr.decode(errors='replace').strip()}")
        target.write_bytes(data.stdout)
        target.chmod(mode & 0o777)


def repository_commit(repo: Path, message: str) -> str:
    run_git(repo, ["add", "-A", "--", "."], check=True)
    result = subprocess.run(
        ["git", "-C", str(repo), "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "commit", "-q", "--no-verify", "-m", message],
        check=False,
        env=git_env(commit_identity=True),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        fail(f"generated Git commit failed: {result.stderr.strip()}")
    return run_git(repo, ["rev-parse", "HEAD"]).strip()


def run_space_pipeline(stage: Path) -> None:
    script = stage / ".space" / "apply.sh"
    if script.is_symlink() or not script.is_file():
        fail("locked Space apply.sh is missing or is a symlink")
    script_text = script.read_text(encoding="utf-8")
    for command in ("npx", "node"):
        if command in script_text and shutil.which(command) is None:
            fail(f"required pipeline command is unavailable: {command}")
    if "xcodegen" in script_text and shutil.which("xcodegen") is None:
        fail("required pipeline command is unavailable: xcodegen")
    private_root = stage.parent / (stage.name + "-runtime")
    private_root.mkdir()
    env = git_env()
    env["TMPDIR"] = str(private_root / "tmp")
    env["HOME"] = str(private_root / "home")
    env["XDG_CACHE_HOME"] = str(private_root / "cache")
    env["NPM_CONFIG_CACHE"] = str(private_root / "npm-cache")
    env["npm_config_cache"] = env["NPM_CONFIG_CACHE"]
    env["PNPM_HOME"] = str(private_root / "pnpm")
    for name in ("TMPDIR", "HOME", "XDG_CACHE_HOME", "NPM_CONFIG_CACHE", "PNPM_HOME"):
        Path(env[name]).mkdir(parents=True, exist_ok=True)
    try:
        run_process(["bash", str(script)], stage, env)
    finally:
        shutil.rmtree(private_root, ignore_errors=True)
    node_modules = stage / "Scripts" / "raycast-runtime" / "node_modules"
    if node_modules.is_symlink() or node_modules.is_file():
        node_modules.unlink()
    elif node_modules.is_dir():
        shutil.rmtree(node_modules)


def ensure_independent_source(repo: Path) -> None:
    if (repo / ".git" / "objects" / "info" / "alternates").exists():
        fail("generated source has a Git alternates dependency")
    refs = run_git(repo, ["for-each-ref", "--format=%(refname)"]).strip()
    if refs:
        fail("generated source unexpectedly contains refs")
    remotes = run_git(repo, ["remote"]).strip()
    if remotes:
        fail("generated source retains a source remote")


def build_stage(inputs: dict[str, Any], stage: Path) -> tuple[str, str, str]:
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

    space_fetch = Path(tempfile.mkdtemp(prefix=".space-fetch-", dir=stage.parent))
    try:
        run_git(space_fetch, ["init", "--bare", "--quiet"])
        space = inputs["lock"]["space"]
        run_git(space_fetch, ["fetch", "--no-tags", "--no-prune", space["url"], space["commit"]])
        verify_commit(space_fetch, space["commit"], "Space")
        safe_extract_space(space_fetch, space["commit"], stage, space["source_paths"])
    finally:
        shutil.rmtree(space_fetch, ignore_errors=True)

    if (stage / ".mine").exists() or (stage / "Makefile").exists():
        fail("generated source contains recipe tooling")
    run_space_pipeline(stage)
    marker.unlink()
    base = repository_commit(stage, "tinycast-space: materialize source-only base")

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
    expected = inputs["lock"]["expected_source"]["fingerprint"]
    if fingerprint != expected:
        fail(f"generated source fingerprint {fingerprint} does not match locked {expected}")
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
            "space": inputs["lock"]["space"]["commit"],
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


class RecipeLock:
    def __init__(self, path: Path, operation: str, *, blocking: bool = True) -> None:
        self.path = path
        self.operation = operation
        self.blocking = blocking
        self.handle: Any = None

    def __enter__(self) -> "RecipeLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        no_follow = getattr(os, "O_NOFOLLOW", 0)
        if not no_follow:
            fail("recipe lock cannot be opened without following symlinks")
        fd: int | None = None
        try:
            fd = os.open(
                self.path,
                os.O_RDWR | os.O_CREAT | no_follow | getattr(os, "O_CLOEXEC", 0) | os.O_NONBLOCK,
                0o600,
            )
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                fail(f"recipe lock is not a private regular file: {self.path}")
            self.handle = os.fdopen(fd, "r+", encoding="utf-8")
            fd = None
        except RecipeError:
            if fd is not None:
                os.close(fd)
            raise
        except OSError as error:
            if fd is not None:
                os.close(fd)
            fail(f"cannot open recipe lock safely: {error}")
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
        base, managed_tip, fingerprint = build_stage(inputs, stage)
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
    if log_path.is_symlink():
        fail(f"log path is a symlink: {log_name}")
    with log_path.open("w", encoding="utf-8") as log:
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


def build_source(debug: bool, prepared: dict[str, Any]) -> int:
    configuration = "Debug" if debug else "Release"
    product_name = DEBUG_PRODUCT if debug else RELEASE_PRODUCT
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
        return status
    product = DERIVED_DATA / "Build" / "Products" / configuration / product_name
    if product.is_symlink() or not product.is_dir():
        fail(f"{configuration} build did not produce {product}")
    if not debug:
        status = verify_signature(product)
        if status:
            return status
    print(product)
    return 0


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
            return build_source(name == "build-debug", prepared)
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
    parser.add_argument("command", choices=("prepare", "status", "command"))
    parser.add_argument("name", nargs="?")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        if args.command == "command":
            if args.name not in TOOL_COMMANDS:
                parser.error("command must be one of: " + ", ".join(TOOL_COMMANDS))
            return run_command(args.name, args.arguments)
        if args.name is not None:
            parser.error(f"{args.command} takes no arguments")
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
