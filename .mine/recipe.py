#!/usr/bin/env python3
"""Materialize Tinycast from the locked upstream, Space, and fork inputs."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
MINE = ROOT / ".mine"
BUILD = ROOT / ".build"
SOURCE = BUILD / "source"
LOCK_PATH = MINE / "sources.lock.json"
PATCH_DIR = MINE / "patches"
RECIPE_PATH = Path(__file__).resolve()
RECEIPT_NAME = "tinycast-recipe-receipt.json"
RECEIPT_SCHEMA = 1
SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
PATCH_NAME_RE = re.compile(r"^[0-9]{4}-[A-Za-z0-9][A-Za-z0-9._-]*\.patch$")
STAGE_PREFIX = ".source-stage-"
OLD_PREFIX = ".source-old-"


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


def git_env(*, commit_identity: bool = False) -> dict[str, str]:
    env = os.environ.copy()
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
    result = subprocess.run(command, cwd=cwd, env=env, check=False)
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


def safe_git_tree(repo: Path) -> list[tuple[str, str, str, str]]:
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
            "HEAD",
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


def source_fingerprint(repo: Path) -> str:
    records = []
    for mode, kind, object_id, path in safe_git_tree(repo):
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


def inspect_existing(source: Path, inputs: dict[str, Any]) -> tuple[dict[str, Any], bool]:
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
    if status:
        fail("generated source has local changes; commit or discard them before prepare")
    refs = run_git(source, ["for-each-ref", "--format=%(refname)"]).strip()
    if refs:
        fail("generated source has local branches, tags, or stashes; prepare will not replace them")
    unreachable = run_git(source, ["fsck", "--no-reflogs", "--unreachable"], check=False).strip()
    if any(line.startswith(("unreachable commit ", "unreachable tree ", "unreachable tag ")) for line in unreachable.splitlines()):
        fail("generated source has unreachable Git objects that may contain unexported work")
    head = run_git(source, ["rev-parse", "--verify", "HEAD^{commit}"]).strip()
    if head != receipt["managed_tip"]:
        fail(f"generated source HEAD moved from managed tip {receipt['managed_tip']} to {head}")
    for commit_key in ("source_only_base_checkpoint", "managed_tip"):
        verify_commit(source, receipt[commit_key], f"receipt.{commit_key}")
    actual_fingerprint = source_fingerprint(source)
    if actual_fingerprint != receipt["source_fingerprint"]:
        fail("generated source fingerprint disagrees with its receipt")
    current = inputs["input_digest"] == receipt["input"]["input_digest"]
    current = current and inputs["lock_sha256"] == receipt["input"]["lock_sha256"]
    current = current and inputs["patch_digest"] == receipt["input"]["patch_digest"]
    current = current and inputs["recipe_sha256"] == receipt["input"]["recipe_sha256"]
    current = current and actual_fingerprint == inputs["lock"]["expected_source"]["fingerprint"]
    return receipt, current


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
        self.handle = self.path.open("a+")
        flags = fcntl.LOCK_EX
        if not self.blocking:
            flags |= fcntl.LOCK_NB
        try:
            fcntl.flock(self.handle.fileno(), flags)
        except BlockingIOError:
            self.handle.close()
            self.handle = None
            raise
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


def prepare() -> dict[str, Any]:
    if BUILD.is_symlink():
        fail(".build is a symlink")
    BUILD.mkdir(exist_ok=True)
    with RecipeLock(BUILD / ".recipe.lock", "prepare"):
        for stale in sorted(BUILD.glob(STAGE_PREFIX + "*")):
            if not stale.is_dir() or (stale / ".recipe-stage-owner").read_text(encoding="utf-8") != "tinycast-recipe\n":
                fail(f"unowned or malformed staging directory requires recovery: {stale}")
            shutil.rmtree(stale)
        inputs = load_inputs()
        old_backups = sorted(BUILD.glob(OLD_PREFIX + "*"))
        if old_backups:
            if SOURCE.exists() or SOURCE.is_symlink() or len(old_backups) != 1:
                fail(f"incomplete publication requires recovery before prepare: {old_backups[0]}")
            inspect_existing(old_backups[0], inputs)
            os.replace(old_backups[0], SOURCE)
        had_source = SOURCE.exists() or SOURCE.is_symlink()
        if had_source:
            receipt, fresh = inspect_existing(SOURCE, inputs)
            if fresh:
                return {
                    "source_path": str(SOURCE),
                    "release_version": inputs["lock"]["upstream"]["release_version"],
                    "fresh": True,
                    "reused": True,
                    "source_only_base_checkpoint": receipt["source_only_base_checkpoint"],
                    "managed_tip": receipt["managed_tip"],
                }
        stage = Path(tempfile.mkdtemp(prefix=STAGE_PREFIX, dir=BUILD))
        published = False
        try:
            base, managed_tip, fingerprint = build_stage(inputs, stage)
            current_inputs = load_inputs()
            if current_inputs["input_digest"] != inputs["input_digest"]:
                fail("locked recipe inputs changed during prepare; previous source was retained")
            if had_source:
                inspect_existing(SOURCE, current_inputs)
            elif SOURCE.exists() or SOURCE.is_symlink():
                fail("generated source appeared during prepare; refusing to replace it")
            backup: Path | None = None
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
                shutil.rmtree(backup)
            return {
                "source_path": str(SOURCE),
                "release_version": inputs["lock"]["upstream"]["release_version"],
                "fresh": True,
                "reused": False,
                "source_only_base_checkpoint": base,
                "managed_tip": managed_tip,
                "source_fingerprint": fingerprint,
            }
        finally:
            if not published and stage.exists():
                shutil.rmtree(stage)


def status() -> dict[str, Any]:
    inputs = load_inputs()
    busy = False
    if BUILD.exists() and not BUILD.is_symlink():
        try:
            with RecipeLock(BUILD / ".recipe.lock", "status", blocking=False):
                pass
        except BlockingIOError:
            busy = True
    result: dict[str, Any] = {
        "source_path": str(SOURCE),
        "release_version": inputs["lock"]["upstream"]["release_version"],
        "fresh": False,
        "operation_owner": "tinycast-recipe",
        "operation_lock": str(BUILD / ".recipe.lock"),
        "operation_busy": busy,
    }
    if SOURCE.exists() or SOURCE.is_symlink():
        receipt, fresh = inspect_existing(SOURCE, inputs)
        result.update(
            {
                "fresh": fresh,
                "source_only_base_checkpoint": receipt["source_only_base_checkpoint"],
                "managed_tip": receipt["managed_tip"],
                "source_fingerprint": receipt["source_fingerprint"],
            }
        )
    return result


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "status"))
    args = parser.parse_args(argv)
    try:
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
