#!/usr/bin/env python3
"""Real-CLI tests for the pinned Tinycast source recipe."""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent.parent
RECIPE = HERE / ".mine" / "recipe.py"
SOURCE_TREE = HERE / ".mine" / "source-tree.sh"
IDENTITY_HASH = "0123456789abcdef0123456789abcdef01234567"
SECOND_IDENTITY_HASH = "89abcdef0123456789abcdef0123456789abcdef"
SAVE_FAULT_DRIVER = '''\
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("recipe_under_test", sys.argv[1])
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)
real_replace = os.replace
mode = sys.argv[2]


def replace(source, destination):
    if os.path.basename(os.fspath(source)) == "new-patches" and os.fspath(destination) == os.fspath(recipe.PATCH_DIR):
        if mode == "exit":
            os._exit(23)
        raise OSError("injected source save publication fault")
    return real_replace(source, destination)


os.replace = replace
raise SystemExit(recipe.main(["save"]))
'''


def git(cwd: Path, *args: str, check: bool = True) -> str:
    env = os.environ.copy()
    env.update(
        {
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Recipe Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@localhost",
            "GIT_COMMITTER_NAME": "Recipe Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@localhost",
        }
    )
    result = subprocess.run(
        ["git", "-C", str(cwd), *args],
        env=env,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check and result.returncode:
        raise AssertionError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def write(path: Path, content: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    if mode is not None:
        path.chmod(mode)


class Fixture:
    def __init__(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tinycast-recipe-test-")
        self.root = Path(self.temp.name) / "recipe-root"
        self.root.mkdir()
        mine = self.root / ".mine"
        (mine / "patches").mkdir(parents=True)
        shutil.copy2(RECIPE, mine / "recipe.py")
        shutil.copy2(SOURCE_TREE, mine / "source-tree.sh")
        shutil.copy2(HERE / ".mine" / "install.sh", mine / "install.sh")
        self.processes: list[subprocess.Popen[str]] = []
        self.tools = self.root / "test-tools"
        self.logs = self.root / "tool-logs"
        self.logs.mkdir()
        self._make_shims()
        self.upstream = self.root / "upstream.git"
        self.space = self.root / "space.git"
        self._make_upstream()
        self._make_space()
        self._make_patch()
        self._write_lock()
        self._write_space_radar()
        self._tag_recipe_root()

    def close(self) -> None:
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
        self.temp.cleanup()

    def _init(self, path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True)
        git(path, "init", "--quiet")
        git(path, "config", "user.name", "Recipe Fixture")
        git(path, "config", "user.email", "fixture@localhost")

    def _make_upstream(self) -> None:
        self._init(self.upstream)
        git(self.upstream, "branch", "-M", "main")
        write(self.upstream / "README.md", "upstream\n")
        write(self.upstream / "project.yml", "name: Fixture\n")
        write(self.upstream / ".github/workflows/upstream.yml", "name: upstream\n")
        write(self.upstream / "Tinycast.xcodeproj/project.pbxproj", "// fixture project\n")
        write(
            self.upstream / "Scripts/run-tests.sh",
            "#!/bin/sh\n"
            "set -eu\n"
            "{\n"
            "  printf 'script=%s\\n' run-tests\n"
            "  printf 'cwd=%s\\n' \"$PWD\"\n"
            "  printf 'args=%s\\n' \"$*\"\n"
            "  if [ -f local-authoring.txt ]; then printf 'local=yes\\n'; fi\n"
            "} > \"${RECIPE_TEST_SCRIPT_LOG:?}\"\n"
            "if [ \"${RECIPE_TEST_HANDSHAKE:-0}\" = 1 ]; then\n"
            "  \"${RECIPE_TEST_HELPER:?}\" -c 'import os, socket; s=socket.socket(socket.AF_UNIX); s.connect(os.environ[\"RECIPE_TEST_SOCKET\"]); s.sendall(b\"ready\\n\"); s.recv(1); s.close()'\n"
            "fi\n"
            "exit \"${RECIPE_TEST_TEST_STATUS:-0}\"\n",
            0o755,
        )
        write(
            self.upstream / "Scripts/lint.sh",
            "#!/bin/sh\n"
            "set -eu\n"
            "{\n"
            "  printf 'script=%s\\n' lint\n"
            "  printf 'cwd=%s\\n' \"$PWD\"\n"
            "  printf 'args=%s\\n' \"$*\"\n"
            "} > \"${RECIPE_TEST_SCRIPT_LOG:?}\"\n"
            "exit \"${RECIPE_TEST_LINT_STATUS:-0}\"\n",
            0o755,
        )
        git(self.upstream, "add", "-A")
        git(self.upstream, "commit", "--quiet", "-m", "upstream base")
        self.upstream_commit = git(self.upstream, "rev-parse", "HEAD")
        git(self.upstream, "tag", "v1.2.3", self.upstream_commit)
        write(self.upstream / "upstream-latest.txt", "latest upstream\n")
        git(self.upstream, "add", "upstream-latest.txt")
        git(self.upstream, "commit", "--quiet", "-m", "upstream latest")
        self.upstream_latest = git(self.upstream, "rev-parse", "HEAD")
        git(self.upstream, "tag", "v1.3.0", self.upstream_latest)

    def _make_shims(self) -> None:
        self.tools.mkdir()
        write(
            self.tools / "git",
            "#!/bin/sh\n"
            "set -euo pipefail\n"
            "for arg in \"$@\"; do\n"
            "  if [ \"${RECIPE_TEST_HANDSHAKE:-0}\" = 1 ] && [ \"$arg\" = fetch ]; then\n"
            "    \"${RECIPE_TEST_HELPER:?}\" -c 'import os, socket; s=socket.socket(socket.AF_UNIX); s.connect(os.environ[\"RECIPE_TEST_SOCKET\"]); s.sendall(b\"ready\\n\"); s.recv(1); s.close()'\n"
            "    break\n"
            "  fi\n"
            "done\n"
            "exec \"${RECIPE_TEST_REAL_GIT:?}\" \"$@\"\n",
            0o755,
        )
        write(
            self.tools / "xcodebuild",
            "#!/bin/bash\n"
            "set -eu\n"
            "{\n"
            "  printf 'tool=xcodebuild\\n'\n"
            "  printf 'cwd=%s\\n' \"$PWD\"\n"
            "  for arg in \"$@\"; do printf 'arg=%s\\n' \"$arg\"; done\n"
            "} > \"${RECIPE_TEST_TOOL_LOG:?}\"\n"
            "dd=''\n"
            "configuration=Release\n"
            "previous=''\n"
            "for arg in \"$@\"; do\n"
            "  case \"$previous\" in\n"
            "    -configuration) configuration=\"$arg\" ;;\n"
            "    -derivedDataPath) dd=\"$arg\" ;;\n"
            "  esac\n"
            "  previous=\"$arg\"\n"
            "done\n"
            "[ -n \"$dd\" ] || { echo 'xcodebuild shim: no derived data' >&2; exit 64; }\n"
            "product=Tinycast.app\n"
            "[ \"$configuration\" = Debug ] && product='Tinycast Dev.app'\n"
            "mkdir -p \"$dd/Build/Products/$configuration/$product\"\n"
            "if [ -n \"${RECIPE_TEST_INSTALL_ORDER:-}\" ]; then printf 'xcodebuild\\n' >> \"$RECIPE_TEST_INSTALL_ORDER\"; fi\n"
            "exit \"${RECIPE_TEST_XCODEBUILD_STATUS:-0}\"\n",
            0o755,
        )
        write(
            self.tools / "security",
            "#!/bin/bash\n"
            "set -eu\n"
            "printf 'arg=%s\\n' \"$@\" > \"${RECIPE_TEST_SECURITY_LOG:?}\"\n"
            "printf '  1) %s \"Apple Development: Fixture (TEAM123456)\"\\n' \"${RECIPE_TEST_IDENTITY_HASH:?}\"\n"
            "printf '  2) %s \"Tinycast Self-Signed\"\\n' \"${RECIPE_TEST_SECOND_IDENTITY:?}\"\n",
            0o755,
        )
        write(
            self.tools / "codesign",
            "#!/bin/bash\n"
            "set -eu\n"
            "printf 'arg=%s\\n' \"$@\" > \"${RECIPE_TEST_CODESIGN_LOG:?}\"\n"
            "exit \"${RECIPE_TEST_CODESIGN_STATUS:-0}\"\n",
            0o755,
        )
        for tool, status, default in (
            ("osascript", "RECIPE_TEST_OSASCRIPT_STATUS", "0"),
            ("pgrep", "RECIPE_TEST_PGREP_STATUS", "1"),
            ("rm", "RECIPE_TEST_RM_STATUS", "0"),
            ("ditto", "RECIPE_TEST_DITTO_STATUS", "0"),
            ("open", "RECIPE_TEST_OPEN_STATUS", "0"),
        ):
            handshake = ""
            if tool == "osascript":
                handshake = (
                    "if [ \"${RECIPE_TEST_INSTALL_HANDSHAKE:-0}\" = 1 ]; then\n"
                    "  \"${RECIPE_TEST_HELPER:?}\" -c 'import os, socket; s=socket.socket(socket.AF_UNIX); s.connect(os.environ[\"RECIPE_TEST_SOCKET\"]); s.sendall(b\"ready\\n\"); s.recv(1); s.close()'\n"
                    "fi\n"
                )
            write(
                self.tools / tool,
                "#!/bin/bash\n"
                "set -eu\n"
                "{\n"
                f"  printf 'tool={tool}\\n'\n"
                "  for arg in \"$@\"; do printf 'arg=%s\\n' \"$arg\"; done\n"
                "} >> \"${RECIPE_TEST_INSTALL_LOG:?}\"\n"
                f"if [ -n \"${{RECIPE_TEST_INSTALL_ORDER:-}}\" ]; then printf '{tool}\\n' >> \"$RECIPE_TEST_INSTALL_ORDER\"; fi\n"
                f"{handshake}exit \"${{{status}:-{default}}}\"\n",
                0o755,
            )

    def _tag_recipe_root(self) -> None:
        self._init(self.root)
        git(self.root, "branch", "-M", "main")
        write(self.root / "recipe-root.txt", "unrelated recipe tag\n")
        git(self.root, "add", "--", ".mine/sources.lock.json", ".mine/patches", "recipe-root.txt")
        git(self.root, "commit", "--quiet", "-m", "recipe root")
        git(self.root, "tag", "v9.9.9")

    def _make_space(self) -> None:
        self._init(self.space)
        git(self.space, "branch", "-M", "main")
        write(self.space / ".space/UPSTREAM", f"{self.upstream_commit}\n")
        write(self.space / ".space/patches/0001-fixture.patch", "fixture patch\n")
        write(self.space / ".space/patches/0002-removed.patch", "removed patch\n")
        write(self.space / ".space/patches/0003-modified.patch", "old patch\n")
        git(self.space, "add", "-A")
        git(self.space, "commit", "--quiet", "-m", "Space adopted snapshot")
        self.space_commit = git(self.space, "rev-parse", "HEAD")
        write(self.space / ".space/UPSTREAM", f"{self.upstream_latest}\n")
        write(self.space / ".space/patches/0003-modified.patch", "new patch\n")
        (self.space / ".space/patches/0002-removed.patch").unlink()
        write(self.space / ".space/patches/0004-added.patch", "added patch\n")
        git(self.space, "add", "-A")
        git(self.space, "commit", "--quiet", "-m", "Space radar head")
        self.space_head = git(self.space, "rev-parse", "HEAD")

    def _make_patch(self) -> None:
        patch_work = self.root / "patch-work"
        git(self.root, "clone", "--quiet", str(self.upstream), str(patch_work))
        git(patch_work, "config", "user.name", "Recipe Fixture")
        git(patch_work, "config", "user.email", "fixture@localhost")
        git(patch_work, "checkout", "--quiet", "--detach", self.upstream_commit)
        write(patch_work / "fork.txt", "fork patch\n")
        git(patch_work, "add", "fork.txt")
        git(patch_work, "commit", "--quiet", "-m", "fork patch")
        patch = subprocess.run(
            ["git", "-C", str(patch_work), "format-patch", "--stdout", "--zero-commit", f"{self.upstream_commit}..HEAD"],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout
        self.patch = self.root / ".mine/patches/0001-fork-patch.patch"
        self.patch.write_bytes(patch)

    def _expected_fingerprint(self) -> str:
        expected = self.root / "expected"
        git(self.root, "clone", "--quiet", str(self.upstream), str(expected))
        git(expected, "checkout", "--quiet", "--detach", self.upstream_commit)
        git(expected, "am", "--3way", "--no-verify", str(self.patch))
        fingerprint = subprocess.run(
            ["bash", str(SOURCE_TREE), str(expected), "HEAD"],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout.strip()
        return f"sha256:{fingerprint}"

    def _write_lock(self) -> None:
        lock = {
            "schema": 2,
            "original_reference_revision": self.upstream_commit,
            "upstream": {
                "url": self.upstream.resolve().as_uri(),
                "commit": self.upstream_commit,
                "release_tag": "v1.2.3",
                "release_version": "1.2.3",
            },
            "expected_source": {
                "fingerprint": self._expected_fingerprint(),
                "record_format": "git-ls-tree-z-v1",
                "excluded_paths": [".mine/", "Makefile"],
            },
        }
        write(self.root / ".mine/sources.lock.json", json.dumps(lock, indent=2) + "\n")

    def _write_space_radar(self) -> None:
        write(
            self.root / ".mine/space-radar.json",
            json.dumps(
                {"url": self.space.resolve().as_uri(), "adopted_commit": self.space_commit},
                indent=2,
            )
            + "\n",
        )

    @property
    def source(self) -> Path:
        return self.root / ".build/source"

    def run(
        self,
        command: str = "prepare",
        arguments: list[str] | None = None,
        extra_env: dict[str, str] | None = None,
        timeout: float = 120,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [sys.executable, str(self.root / ".mine/recipe.py"), command, *(arguments or [])],
            cwd=self.root,
            env=env,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )

    def start(self, command: str = "prepare", extra_env: dict[str, str] | None = None) -> subprocess.Popen[str]:
        env = os.environ.copy()
        if extra_env:
            env.update(extra_env)
        process = subprocess.Popen(
            [sys.executable, str(self.root / ".mine/recipe.py"), command],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.processes.append(process)
        return process

    def tool_env(self, **extra: str) -> dict[str, str]:
        env = {
            "PATH": f"{self.tools}:{os.environ.get('PATH', '')}",
            "RECIPE_TEST_REAL_GIT": shutil.which("git") or "/usr/bin/git",
            "RECIPE_TEST_TOOL_LOG": str(self.logs / "xcodebuild.log"),
            "RECIPE_TEST_SECURITY_LOG": str(self.logs / "security.log"),
            "RECIPE_TEST_CODESIGN_LOG": str(self.logs / "codesign.log"),
            "RECIPE_TEST_SCRIPT_LOG": str(self.logs / "project-script.log"),
            "RECIPE_TEST_INSTALL_LOG": str(self.logs / "install.log"),
            "RECIPE_TEST_IDENTITY_HASH": IDENTITY_HASH,
            "RECIPE_TEST_SECOND_IDENTITY": SECOND_IDENTITY_HASH,
        }
        env.update(extra)
        return env

    def command(
        self,
        name: str,
        arguments: list[str] | None = None,
        extra_env: dict[str, str] | None = None,
        cwd: Path | None = None,
        timeout: float = 120,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(self.tool_env())
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [sys.executable, str(self.root / ".mine/recipe.py"), "command", name, *(arguments or [])],
            cwd=cwd or self.root,
            env=env,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )

    def start_command(
        self,
        name: str,
        arguments: list[str] | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.Popen[str]:
        env = os.environ.copy()
        env.update(self.tool_env())
        if extra_env:
            env.update(extra_env)
        process = subprocess.Popen(
            [sys.executable, str(self.root / ".mine/recipe.py"), "command", name, *(arguments or [])],
            cwd=self.root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.processes.append(process)
        return process

    def receipt(self) -> dict[str, object]:
        return json.loads((self.source / ".git/tinycast-recipe-receipt.json").read_text())

    def source_fingerprint(self, revision: str = "HEAD") -> str:
        result = subprocess.run(
            ["bash", str(SOURCE_TREE), str(self.source), revision],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        )
        return f"sha256:{result.stdout.strip()}"

    def commit_source(self, relative: str, content: str, message: str) -> str:
        write(self.source / relative, content)
        git(self.source, "add", "--", relative)
        git(self.source, "commit", "--quiet", "-m", message)
        return git(self.source, "rev-parse", "HEAD")


class RecipeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = Fixture()

    def tearDown(self) -> None:
        self.fixture.close()

    def assertFailsWith(self, result: subprocess.CompletedProcess[str], text: str) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(text, result.stderr)

    def run_save_with_publication_fault(self, mode: str) -> subprocess.CompletedProcess[str]:
        driver = Path(self.fixture.temp.name) / "save-fault.py"
        driver.write_text(SAVE_FAULT_DRIVER, encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(driver), str(self.fixture.root / ".mine/recipe.py"), mode],
            cwd=self.fixture.root,
            env=os.environ.copy(),
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=120,
        )

    def save_transaction(self) -> Path:
        transactions = [
            path for path in (self.fixture.root / ".build").glob(".source-save-*") if path.is_dir()
        ]
        self.assertEqual(len(transactions), 1)
        return transactions[0]

    def test_pristine_repeat_independent_source_and_status(self) -> None:
        first = self.fixture.run()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        first_json = json.loads(first.stdout)
        self.assertTrue(first_json["fresh"])
        self.assertFalse(first_json["reused"])
        first_head = git(self.fixture.source, "rev-parse", "HEAD")
        self.assertTrue((self.fixture.source / ".git").is_dir())
        self.assertFalse((self.fixture.source / ".space").exists())
        self.assertFalse((self.fixture.source / "generated.txt").exists())
        self.assertEqual(git(self.fixture.source, "remote"), "")
        self.assertEqual(git(self.fixture.source, "for-each-ref", "--format=%(refname)"), "")
        self.assertFalse((self.fixture.source / ".git/objects/info/alternates").exists())
        receipt = self.fixture.receipt()
        self.assertEqual(receipt["schema"], 2)
        self.assertEqual(
            receipt["locked"],
            {"upstream": self.fixture.upstream_commit, "release_version": "1.2.3"},
        )
        self.assertEqual(receipt["managed_tip"], first_head)
        self.assertNotEqual(receipt["source_only_base_checkpoint"], first_head)
        fingerprint = subprocess.run(
            ["bash", str(SOURCE_TREE), str(self.fixture.source), "HEAD"],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout.strip()
        self.assertEqual(receipt["source_fingerprint"], f"sha256:{fingerprint}")

        second = self.fixture.run()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(git(self.fixture.source, "rev-parse", "HEAD"), first_head)
        self.assertIn('"reused": true', second.stdout)
        status = self.fixture.run("status")
        self.assertEqual(status.returncode, 0, status.stdout + status.stderr)
        status_json = json.loads(status.stdout)
        self.assertTrue(status_json["fresh"])
        self.assertEqual(status_json["release_version"], "1.2.3")
        self.assertEqual(status_json["operation_owner"], "tinycast-recipe")

    def test_update_selects_official_main_and_release_tag_without_space(self) -> None:
        prepared = self.fixture.run()
        self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
        old_source_head = git(self.fixture.source, "rev-parse", "HEAD")
        old_root_head = git(self.fixture.root, "rev-parse", "HEAD")
        old_lock = (self.fixture.root / ".mine/sources.lock.json").read_bytes()
        shutil.rmtree(self.fixture.space)

        updated = self.fixture.run("update")
        self.assertEqual(updated.returncode, 0, updated.stdout + updated.stderr)
        result = json.loads(updated.stdout)
        lock = json.loads((self.fixture.root / ".mine/sources.lock.json").read_text())
        self.assertTrue(result["changed"])
        self.assertEqual(lock["upstream"]["commit"], self.fixture.upstream_latest)
        self.assertEqual(lock["upstream"]["release_tag"], "v1.3.0")
        self.assertEqual(lock["upstream"]["release_version"], "1.3.0")
        self.assertNotEqual(lock["upstream"]["release_version"], "9.9.9")
        self.assertEqual(lock["schema"], 2)
        self.assertNotIn("space", lock)
        self.assertEqual(result["operation"], "update")
        self.assertNotIn("space_commit", result)
        self.assertIn("run make prepare", result["cache"])
        self.assertEqual(git(self.fixture.source, "rev-parse", "HEAD"), old_source_head)
        self.assertFalse((self.fixture.source / "upstream-latest.txt").exists())
        self.assertEqual(git(self.fixture.root, "rev-parse", "HEAD"), old_root_head)
        self.assertNotEqual((self.fixture.root / ".mine/sources.lock.json").read_bytes(), old_lock)

    def test_check_space_reports_head_and_patch_changes_without_root_mutation(self) -> None:
        prepared = self.fixture.run()
        self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
        old_lock = (self.fixture.root / ".mine/sources.lock.json").read_bytes()
        old_recipe_lock = (self.fixture.root / ".build/.recipe.lock").read_bytes()
        old_root_head = git(self.fixture.root, "rev-parse", "HEAD")
        old_source_head = git(self.fixture.source, "rev-parse", "HEAD")
        old_source_status = git(self.fixture.source, "status", "--porcelain")
        old_source_fingerprint = self.fixture.source_fingerprint()
        result = self.fixture.run("check-space")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["url"], self.fixture.space.resolve().as_uri())
        self.assertEqual(report["adopted_commit"], self.fixture.space_commit)
        self.assertEqual(report["head"], self.fixture.space_head)
        self.assertEqual(report["upstream"], self.fixture.upstream_latest)
        self.assertEqual(
            report["patches"],
            {
                "added": [".space/patches/0004-added.patch"],
                "modified": [".space/patches/0003-modified.patch"],
                "removed": [".space/patches/0002-removed.patch"],
            },
        )
        self.assertFalse(report["patches_truncated"])
        self.assertEqual((self.fixture.root / ".mine/sources.lock.json").read_bytes(), old_lock)
        self.assertEqual((self.fixture.root / ".build/.recipe.lock").read_bytes(), old_recipe_lock)
        self.assertEqual(git(self.fixture.root, "rev-parse", "HEAD"), old_root_head)
        self.assertEqual(git(self.fixture.source, "rev-parse", "HEAD"), old_source_head)
        self.assertEqual(git(self.fixture.source, "status", "--porcelain"), old_source_status)
        self.assertEqual(self.fixture.source_fingerprint(), old_source_fingerprint)

    def test_check_space_bounds_patch_changes(self) -> None:
        for index in range(45):
            write(self.fixture.space / ".space/patches" / f"000{index + 10}-added.patch", "added\n")
        git(self.fixture.space, "add", "-A")
        git(self.fixture.space, "commit", "--quiet", "-m", "Space radar many patches")

        result = self.fixture.run("check-space")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(sum(len(paths) for paths in report["patches"].values()), 40)
        self.assertTrue(report["patches_truncated"])

    def test_update_conflict_preserves_lock_patch_source_and_root_state(self) -> None:
        prepared = self.fixture.run()
        self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
        old_lock = (self.fixture.root / ".mine/sources.lock.json").read_bytes()
        old_patch = self.fixture.patch.read_bytes()
        old_source_head = git(self.fixture.source, "rev-parse", "HEAD")
        old_root_head = git(self.fixture.root, "rev-parse", "HEAD")
        self.fixture.patch.write_text("not a mail patch\n")
        changed_patch = self.fixture.patch.read_bytes()

        result = self.fixture.run("update")
        self.assertFailsWith(result, "fork patch replay failed")
        self.assertEqual((self.fixture.root / ".mine/sources.lock.json").read_bytes(), old_lock)
        self.assertEqual(self.fixture.patch.read_bytes(), changed_patch)
        self.assertNotEqual(changed_patch, old_patch)
        self.assertEqual(git(self.fixture.source, "rev-parse", "HEAD"), old_source_head)
        self.assertEqual(git(self.fixture.root, "rev-parse", "HEAD"), old_root_head)

    def test_update_rejects_source_authoring_and_staged_lock_state(self) -> None:
        prepared = self.fixture.run()
        self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
        write(self.fixture.source / "local-authoring.txt", "preserve\n")
        old_lock = (self.fixture.root / ".mine/sources.lock.json").read_bytes()
        rejected_source = self.fixture.run("update")
        self.assertFailsWith(rejected_source, "unexported local changes")
        self.assertEqual((self.fixture.root / ".mine/sources.lock.json").read_bytes(), old_lock)
        self.assertTrue((self.fixture.source / "local-authoring.txt").exists())

        (self.fixture.source / "local-authoring.txt").unlink()
        lock = json.loads(old_lock)
        lock["original_reference_revision"] = lock["original_reference_revision"]
        (self.fixture.root / ".mine/sources.lock.json").write_text(json.dumps(lock) + "\n")
        git(self.fixture.root, "add", ".mine/sources.lock.json")
        staged_bytes = (self.fixture.root / ".mine/sources.lock.json").read_bytes()
        staged_index = git(self.fixture.root, "ls-files", "-s", "--", ".mine/sources.lock.json")
        rejected_lock = self.fixture.run("update")
        self.assertFailsWith(rejected_lock, "staged lock or patch edits")
        self.assertEqual((self.fixture.root / ".mine/sources.lock.json").read_bytes(), staged_bytes)
        self.assertEqual(
            git(self.fixture.root, "ls-files", "-s", "--", ".mine/sources.lock.json"), staged_index
        )

    def test_repeated_update_is_a_noop_and_does_not_create_predecessor(self) -> None:
        first = self.fixture.run("update")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        lock_path = self.fixture.root / ".mine/sources.lock.json"
        first_lock = lock_path.read_bytes()
        root_head = git(self.fixture.root, "rev-parse", "HEAD")
        root_index = git(self.fixture.root, "ls-files", "-s")
        self.assertEqual(git(self.fixture.root, "diff", "--name-only"), ".mine/sources.lock.json")
        second = self.fixture.run("update")
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertFalse(json.loads(second.stdout)["changed"])
        self.assertEqual(lock_path.read_bytes(), first_lock)
        self.assertEqual(git(self.fixture.root, "rev-parse", "HEAD"), root_head)
        self.assertEqual(git(self.fixture.root, "ls-files", "-s"), root_index)
        self.assertFalse(self.fixture.source.exists())

        manual = json.loads(first_lock)
        manual["upstream"]["release_tag"] = "v1.2.3"
        manual["upstream"]["release_version"] = "1.2.3"
        lock_path.write_text(json.dumps(manual, indent=2) + "\n")
        manual_bytes = lock_path.read_bytes()
        conflicting = self.fixture.run("update")
        self.assertFailsWith(conflicting, "pre-existing edits")
        self.assertEqual(lock_path.read_bytes(), manual_bytes)
        self.assertEqual(git(self.fixture.root, "ls-files", "-s"), root_index)
        self.assertEqual(list((self.fixture.root / ".build").glob(".source-backup-*")), [])

    def test_prepare_materializes_new_pin_then_save_preserves_fingerprint(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        updated = self.fixture.run("update")
        self.assertEqual(updated.returncode, 0, updated.stdout + updated.stderr)
        lock = json.loads((self.fixture.root / ".mine/sources.lock.json").read_text())
        stale_head = git(self.fixture.source, "rev-parse", "HEAD")
        self.assertFalse((self.fixture.source / "upstream-latest.txt").exists())

        prepared = self.fixture.run()
        self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
        self.assertNotEqual(git(self.fixture.source, "rev-parse", "HEAD"), stale_head)
        self.assertTrue((self.fixture.source / "upstream-latest.txt").exists())
        self.assertEqual(self.fixture.source_fingerprint(), lock["expected_source"]["fingerprint"])
        saved = self.fixture.run("save")
        self.assertEqual(saved.returncode, 0, saved.stdout + saved.stderr)
        self.assertFalse(json.loads(saved.stdout)["exported"])

    def test_git_environment_cannot_redirect_fixture_operations(self) -> None:
        victim = self.fixture.root / "victim"
        self.fixture._init(victim)
        write(victim / "sentinel.txt", "preserve me\n")
        git(victim, "add", "sentinel.txt")
        git(victim, "commit", "--quiet", "-m", "victim baseline")
        victim_head = git(victim, "rev-parse", "HEAD")
        victim_config = (victim / ".git/config").read_bytes()
        contaminated = {
            "GIT_DIR": str(victim / ".git"),
            "GIT_WORK_TREE": str(victim),
            "GIT_COMMON_DIR": str(victim / ".git"),
            "GIT_INDEX_FILE": str(victim / ".git/index"),
            "GIT_OBJECT_DIRECTORY": str(victim / ".git/objects"),
            "GIT_OBJECT_DIRECTORY_RELATIVE": "objects",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": str(victim / ".git/objects"),
            "GIT_CONFIG_GLOBAL": str(victim / ".git/config"),
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": str(victim / "hooks"),
        }
        result = self.fixture.run(extra_env=contaminated)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(git(victim, "rev-parse", "HEAD"), victim_head)
        self.assertEqual((victim / "sentinel.txt").read_text(), "preserve me\n")
        self.assertEqual((victim / ".git/config").read_bytes(), victim_config)
        self.assertTrue(self.fixture.source.exists())

    def test_patch_failure_keeps_previous_published_source(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        old_head = git(self.fixture.source, "rev-parse", "HEAD")
        old_receipt = self.fixture.receipt()
        self.fixture.patch.write_text("this is not a mail patch\n")
        result = self.fixture.run()
        self.assertFailsWith(result, "previous published source was retained")
        self.assertEqual(git(self.fixture.source, "rev-parse", "HEAD"), old_head)
        self.assertEqual(self.fixture.receipt(), old_receipt)
        self.assertEqual(list((self.fixture.root / ".build").glob(".source-stage-*")), [])

    def test_malformed_lock_and_symlink_are_rejected(self) -> None:
        lock_path = self.fixture.root / ".mine/sources.lock.json"
        lock = json.loads(lock_path.read_text())
        lock["schema"] = 99
        lock_path.write_text(json.dumps(lock))
        self.assertFailsWith(self.fixture.run(), "malformed sources.lock.json")

        lock["schema"] = 1
        lock_path.write_text(json.dumps(lock))
        self.assertFailsWith(self.fixture.run(), "schema 1 is no longer supported")
        lock["schema"] = 2
        lock_path.write_text(json.dumps(lock))
        outside = self.fixture.root / "outside"
        outside.mkdir()
        build = self.fixture.root / ".build"
        build.mkdir(exist_ok=True)
        (build / "source").symlink_to(outside, target_is_directory=True)
        self.assertFailsWith(self.fixture.run(), "generated source path is a symlink")

    def test_lock_aliases_are_rejected_without_truncation_or_blocking(self) -> None:
        build = self.fixture.root / ".build"
        build.mkdir()
        lock_path = build / ".recipe.lock"
        sentinel = self.fixture.root / "lock-target.txt"
        original = b"preserve lock target\n"
        sentinel.write_bytes(original)
        for variant in ("symlink", "hardlink", "directory", "fifo"):
            if lock_path.is_symlink() or lock_path.is_file() or lock_path.is_fifo():
                lock_path.unlink()
            elif lock_path.is_dir():
                lock_path.rmdir()
            if variant == "symlink":
                lock_path.symlink_to(sentinel)
            elif variant == "hardlink":
                os.link(sentinel, lock_path)
            elif variant == "directory":
                lock_path.mkdir()
            else:
                os.mkfifo(lock_path)
            result = self.fixture.run("status", timeout=5)
            self.assertFailsWith(result, "recipe lock")
            self.assertEqual(sentinel.read_bytes(), original)

    def test_missing_receipt_and_non_descendant_source_are_rejected(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        receipt_path = self.fixture.source / ".git/tinycast-recipe-receipt.json"
        saved_receipt = receipt_path.read_bytes()
        receipt_path.unlink()
        self.assertFailsWith(self.fixture.run(), "recipe receipt is missing")
        receipt_path.write_bytes(saved_receipt)
        receipt = json.loads(saved_receipt)
        receipt["schema"] = 1
        receipt_path.write_text(json.dumps(receipt))
        self.assertFailsWith(self.fixture.run(), "unsupported schema")
        receipt_path.write_bytes(saved_receipt)

        git(self.fixture.source, "branch", "managed-anchor")
        git(self.fixture.source, "checkout", "--quiet", "--orphan", "external")
        write(self.fixture.source / "external.txt", "external history\n")
        git(self.fixture.source, "add", "-A")
        git(self.fixture.source, "commit", "--quiet", "-m", "external replacement")
        self.assertFailsWith(self.fixture.run(), "outside managed lineage")

    def test_same_input_reuses_dirty_source_and_status_reports_local_state(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        write(self.fixture.source / "README.md", "user edit\n")
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('"reused": true', result.stdout)
        self.assertIn('"fresh": false', result.stdout)
        status = self.fixture.run("status")
        self.assertEqual(status.returncode, 0, status.stdout + status.stderr)
        status_json = json.loads(status.stdout)
        self.assertTrue(status_json["inputs_current"])
        self.assertTrue(status_json["source_state"]["worktree_dirty"])
        self.assertTrue(status_json["source_state"]["unexported_changes"])
        self.assertEqual((self.fixture.source / "README.md").read_text(), "user edit\n")

    def test_same_input_reuses_committed_descendant(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        write(self.fixture.source / "local.txt", "committed local work\n")
        git(self.fixture.source, "add", "local.txt")
        git(self.fixture.source, "commit", "--quiet", "-m", "unexported local work")
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('"reused": true', result.stdout)
        self.assertIn('"head_is_managed": false', result.stdout)

    def test_same_input_reuses_branch_and_stash(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        git(self.fixture.source, "checkout", "--quiet", "-b", "user-work")
        write(self.fixture.source / "README.md", "stashed local work\n")
        git(self.fixture.source, "stash", "push", "--quiet", "-m", "unexported stash")
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('"reused": true', result.stdout)
        state = json.loads(result.stdout)["source_state"]
        self.assertIn("refs/heads/user-work", state["refs"])
        self.assertIn("refs/stash", state["refs"])

    def test_changed_recipe_refuses_dirty_source(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        write(self.fixture.source / "README.md", "unexported edit\n")
        old_head = git(self.fixture.source, "rev-parse", "HEAD")
        patch_text = self.fixture.patch.read_text()
        self.fixture.patch.write_text(patch_text.replace("Subject: [PATCH]", "Subject: [PATCH] changed", 1))
        result = self.fixture.run()
        self.assertFailsWith(result, "unexported local changes")
        self.assertEqual(git(self.fixture.source, "rev-parse", "HEAD"), old_head)
        self.assertEqual((self.fixture.source / "README.md").read_text(), "unexported edit\n")

    def test_changed_recipe_refuses_committed_descendant(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        write(self.fixture.source / "local.txt", "unexported commit\n")
        git(self.fixture.source, "add", "local.txt")
        git(self.fixture.source, "commit", "--quiet", "-m", "unexported local work")
        old_head = git(self.fixture.source, "rev-parse", "HEAD")
        patch_text = self.fixture.patch.read_text()
        self.fixture.patch.write_text(patch_text.replace("Subject: [PATCH]", "Subject: [PATCH] changed", 1))
        result = self.fixture.run()
        self.assertFailsWith(result, "unexported local changes")
        self.assertEqual(git(self.fixture.source, "rev-parse", "HEAD"), old_head)

    def test_changed_recipe_refuses_branch_and_stash(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        git(self.fixture.source, "checkout", "--quiet", "-b", "user-work")
        write(self.fixture.source / "README.md", "stashed local work\n")
        git(self.fixture.source, "stash", "push", "--quiet", "-m", "unexported stash")
        patch_text = self.fixture.patch.read_text()
        self.fixture.patch.write_text(patch_text.replace("Subject: [PATCH]", "Subject: [PATCH] changed", 1))
        result = self.fixture.run()
        self.assertFailsWith(result, "unexported local changes")
        self.assertIn("refs/heads/user-work", git(self.fixture.source, "for-each-ref", "--format=%(refname)"))
        self.assertIn("unexported stash", git(self.fixture.source, "stash", "list"))

    def test_replacement_retains_predecessor_backup_and_ignored_data(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        exclude = self.fixture.source / ".git/info/exclude"
        exclude.write_text("private-note.txt\n")
        private_note = self.fixture.source / "private-note.txt"
        private_note.write_text("keep this user data\n")
        old_head = git(self.fixture.source, "rev-parse", "HEAD")
        patch_text = self.fixture.patch.read_text()
        self.fixture.patch.write_text(patch_text.replace("Subject: [PATCH]", "Subject: [PATCH] changed", 1))
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result_json = json.loads(result.stdout)
        backup = Path(result_json["predecessor_backup"])
        self.assertTrue(backup.name.startswith(".source-backup-"))
        self.assertTrue(backup.is_dir())
        self.assertEqual((backup / ".git/info/exclude").read_text(), "private-note.txt\n")
        self.assertEqual((backup / "private-note.txt").read_text(), "keep this user data\n")
        self.assertEqual(git(backup, "rev-parse", "HEAD"), old_head)
        self.assertFalse(private_note.exists())
        repeated = self.fixture.run()
        self.assertEqual(repeated.returncode, 0, repeated.stdout + repeated.stderr)
        self.assertIn('"reused": true', repeated.stdout)

    def test_changed_patch_digest_rebuilds_current_inputs(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        old_receipt = self.fixture.receipt()
        patch_text = self.fixture.patch.read_text()
        self.fixture.patch.write_text(patch_text.replace("Subject: [PATCH]", "Subject: [PATCH] v2", 1))
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        new_receipt = self.fixture.receipt()
        self.assertNotEqual(new_receipt["input"]["patch_digest"], old_receipt["input"]["patch_digest"])
        self.assertNotEqual(new_receipt["input"]["input_digest"], old_receipt["input"]["input_digest"])
        self.assertIn('"reused": false', result.stdout)

    def test_overlapping_prepare_does_not_publish_stale_inputs(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        old_head = git(self.fixture.source, "rev-parse", "HEAD")
        old_patch_digest = self.fixture.receipt()["input"]["patch_digest"]
        patch_text = self.fixture.patch.read_text()
        self.fixture.patch.write_text(patch_text.replace("Subject: [PATCH]", "Subject: [PATCH] baseline", 1))
        handshake_dir = Path(tempfile.mkdtemp(prefix="tc-handshake-", dir=tempfile.gettempdir()))
        handshake = handshake_dir / "s"
        server: socket.socket | None = None
        connection: socket.socket | None = None
        first: subprocess.Popen[str] | None = None
        second: subprocess.Popen[str] | None = None
        try:
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(handshake))
            server.listen(1)
            server.settimeout(20)
            env = {
                "RECIPE_TEST_HANDSHAKE": "1",
                "RECIPE_TEST_HELPER": sys.executable,
                "RECIPE_TEST_SOCKET": str(handshake),
                "RECIPE_TEST_REAL_GIT": shutil.which("git") or "/usr/bin/git",
                "PATH": f"{self.fixture.tools}:{os.environ.get('PATH', '')}",
            }
            first = self.fixture.start(extra_env=env)
            connection, _ = server.accept()
            connection.settimeout(20)
            self.assertEqual(connection.recv(6), b"ready\n")
            patch_text = self.fixture.patch.read_text()
            self.fixture.patch.write_text(patch_text.replace("Subject: [PATCH]", "Subject: [PATCH] overlap", 1))
            second = self.fixture.start(extra_env={**env, "RECIPE_TEST_HANDSHAKE": "0"})
            connection.sendall(b"release")
            first_stdout, first_stderr = first.communicate(timeout=120)
            second_stdout, second_stderr = second.communicate(timeout=120)
            self.assertNotEqual(first.returncode, 0, first_stdout + first_stderr)
            self.assertIn("inputs changed during prepare", first_stderr)
            self.assertEqual(second.returncode, 0, second_stdout + second_stderr)
            self.assertNotEqual(git(self.fixture.source, "rev-parse", "HEAD"), old_head)
            self.assertNotEqual(self.fixture.receipt()["input"]["patch_digest"], old_patch_digest)
        finally:
            for process in (first, second):
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
            if connection is not None:
                connection.close()
            if server is not None:
                server.close()
            shutil.rmtree(handshake_dir, ignore_errors=True)

    def test_build_commands_use_source_locked_version_and_owned_paths(self) -> None:
        release = self.fixture.command("build")
        self.assertEqual(release.returncode, 0, release.stdout + release.stderr)
        lines = release.stdout.strip().splitlines()
        self.assertEqual(len(lines), 1, release.stdout)
        artifact = Path(lines[0])
        self.assertEqual(
            artifact.resolve(),
            (self.fixture.root / ".build/DerivedData/Build/Products/Release/Tinycast.app").resolve(),
        )
        self.assertTrue(artifact.is_dir())
        self.assertIn("locked 1.2.3", release.stderr)

        log = (self.fixture.logs / "xcodebuild.log").read_text()
        self.assertIn(f"cwd={self.fixture.source.resolve()}", log)
        self.assertIn("arg=-configuration\narg=Release\n", log)
        self.assertIn("arg=MARKETING_VERSION=1.2.3", log)
        self.assertNotIn("9.9.9", log)
        self.assertIn("arg=CODE_SIGN_STYLE=Manual", log)
        self.assertIn("arg=OTHER_CODE_SIGN_FLAGS=--timestamp=none", log)
        self.assertIn(f"arg=CODE_SIGN_IDENTITY={IDENTITY_HASH}", log)
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", log)
        self.assertNotIn("PRODUCT_NAME=", log)
        self.assertNotIn("PRODUCT_BUNDLE_IDENTIFIER=", log)

        codesign = (self.fixture.logs / "codesign.log").read_text()
        self.assertIn("arg=--verify", codesign)
        self.assertNotIn("arg=--force", codesign)
        self.assertNotIn("arg=--sign", codesign)
        self.assertIn(f"arg={artifact}", codesign)

        selected = self.fixture.command("build", extra_env={"TINYCAST_SIGN_IDENTITY": SECOND_IDENTITY_HASH})
        self.assertEqual(selected.returncode, 0, selected.stdout + selected.stderr)
        selected_log = (self.fixture.logs / "xcodebuild.log").read_text()
        self.assertIn(f"arg=CODE_SIGN_IDENTITY={SECOND_IDENTITY_HASH}", selected_log)

        (self.fixture.logs / "security.log").unlink()
        debug = self.fixture.command("build-debug")
        self.assertEqual(debug.returncode, 0, debug.stdout + debug.stderr)
        debug_artifact = Path(debug.stdout.strip().splitlines()[-1])
        self.assertEqual(
            debug_artifact.resolve(),
            (self.fixture.root / ".build/DerivedData/Build/Products/Debug/Tinycast Dev.app").resolve(),
        )
        self.assertTrue(debug_artifact.is_dir())
        debug_log = (self.fixture.logs / "xcodebuild.log").read_text()
        self.assertIn("arg=-configuration\narg=Debug\n", debug_log)
        self.assertIn("arg=MARKETING_VERSION=1.2.3", debug_log)
        self.assertIn("arg=CODE_SIGNING_ALLOWED=NO", debug_log)
        self.assertNotIn("CODE_SIGN_IDENTITY=", debug_log)
        self.assertFalse((self.fixture.logs / "security.log").exists())

        failed = self.fixture.command("build", extra_env={"RECIPE_TEST_XCODEBUILD_STATUS": "7"})
        self.assertEqual(failed.returncode, 7, failed.stdout + failed.stderr)
        self.assertEqual(failed.stdout.strip(), "")
        self.assertIn("Release build failed (7)", failed.stderr)

    def test_build_log_alias_is_rejected_before_truncation(self) -> None:
        self.assertEqual(self.fixture.command("build-debug").returncode, 0)
        log_path = self.fixture.root / ".build/logs/debug-build.log"
        tool_log = self.fixture.logs / "xcodebuild.log"
        sentinel = self.fixture.root / "outside-log-target.txt"
        original = b"preserve unrelated user data\n"
        sentinel.write_bytes(original)
        log_path.unlink()
        for variant in ("symlink", "hardlink"):
            if variant == "symlink":
                log_path.symlink_to(sentinel)
            else:
                os.link(sentinel, log_path)
            tool_log.unlink(missing_ok=True)
            result = self.fixture.command("build-debug")
            self.assertFailsWith(result, "debug-build.log")
            self.assertEqual(sentinel.read_bytes(), original)
            self.assertFalse(tool_log.exists())
            log_path.unlink()
        rebuilt = self.fixture.command("build-debug")
        self.assertEqual(rebuilt.returncode, 0, rebuilt.stdout + rebuilt.stderr)
        self.assertTrue(log_path.is_file())
        self.assertIn("$ xcodebuild", log_path.read_text())

    def test_install_builds_and_installs_under_recipe_lock(self) -> None:
        result = self.fixture.command("install")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("locked 1.2.3", result.stderr)
        product = (
            self.fixture.root / ".build/DerivedData/Build/Products/Release/Tinycast.app"
        ).resolve()
        self.assertTrue(product.is_dir())
        log = (self.fixture.logs / "install.log").read_text()
        self.assertIn('tool=osascript\narg=-e\narg=quit app id "com.tinycast.app"\n', log)
        self.assertIn("tool=rm\narg=-rf\narg=/Applications/Tinycast.app\n", log)
        self.assertIn(f"tool=ditto\narg={product}\narg=/Applications/Tinycast.app\n", log)
        self.assertIn("tool=open\narg=/Applications/Tinycast.app\n", log)
        self.assertIn("installed /Applications/Tinycast.app", result.stdout)

    def test_install_build_failure_skips_app_tools(self) -> None:
        result = self.fixture.command("install", extra_env={"RECIPE_TEST_XCODEBUILD_STATUS": "7"})
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("Release build failed (7)", result.stderr)
        self.assertFalse((self.fixture.logs / "install.log").exists())

    def test_install_holds_lock_until_worker_finishes(self) -> None:
        handshake_dir = Path(tempfile.mkdtemp(prefix="tc-install-handshake-", dir=tempfile.gettempdir()))
        handshake = handshake_dir / "s"
        order = self.fixture.logs / "install-order.log"
        server: socket.socket | None = None
        connection: socket.socket | None = None
        install: subprocess.Popen[str] | None = None
        second: subprocess.Popen[str] | None = None
        try:
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(handshake))
            server.listen(1)
            server.settimeout(20)
            ordered = {"RECIPE_TEST_INSTALL_ORDER": str(order)}
            install = self.fixture.start_command(
                "install",
                extra_env={
                    **ordered,
                    "RECIPE_TEST_INSTALL_HANDSHAKE": "1",
                    "RECIPE_TEST_HELPER": sys.executable,
                    "RECIPE_TEST_SOCKET": str(handshake),
                },
            )
            connection, _ = server.accept()
            connection.settimeout(20)
            self.assertEqual(connection.recv(6), b"ready\n")

            product = (
                self.fixture.root / ".build/DerivedData/Build/Products/Release/Tinycast.app"
            ).resolve()
            self.assertTrue(product.is_dir())
            lock_path = self.fixture.root / ".build/.recipe.lock"
            with lock_path.open("r+") as handle:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

            status = self.fixture.run("status")
            self.assertEqual(status.returncode, 0, status.stdout + status.stderr)
            self.assertTrue(json.loads(status.stdout)["operation_busy"])
            self.assertEqual(order.read_text().splitlines(), ["xcodebuild", "osascript"])
            self.assertNotIn("tool=rm", (self.fixture.logs / "install.log").read_text())

            second = self.fixture.start_command("build-debug", extra_env=ordered)
            self.assertIsNone(second.poll())
            connection.sendall(b"release")
            install_stdout, install_stderr = install.communicate(timeout=120)
            second_stdout, second_stderr = second.communicate(timeout=120)
            self.assertEqual(install.returncode, 0, install_stdout + install_stderr)
            self.assertEqual(second.returncode, 0, second_stdout + second_stderr)

            tools = [entry for entry in order.read_text().splitlines() if entry != "pgrep"]
            self.assertEqual(
                tools,
                ["xcodebuild", "osascript", "rm", "ditto", "open", "xcodebuild"],
            )
            settled = self.fixture.run("status")
            self.assertEqual(settled.returncode, 0, settled.stdout + settled.stderr)
            self.assertFalse(json.loads(settled.stdout)["operation_busy"])
        finally:
            for process in (install, second):
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
            if connection is not None:
                connection.close()
            if server is not None:
                server.close()
            shutil.rmtree(handshake_dir, ignore_errors=True)

    def test_test_and_lint_inherit_source_scripts_and_preserve_status(self) -> None:
        test = self.fixture.command("test", ["calc-test"], cwd=Path("/"))
        self.assertEqual(test.returncode, 0, test.stdout + test.stderr)
        self.assertEqual(test.stdout, "")
        log = (self.fixture.logs / "project-script.log").read_text()
        self.assertIn("script=run-tests", log)
        self.assertIn(f"cwd={self.fixture.source.resolve()}", log)
        self.assertIn("args=calc-test", log)

        lint = self.fixture.command("lint", ["--fix"])
        self.assertEqual(lint.returncode, 0, lint.stdout + lint.stderr)
        log = (self.fixture.logs / "project-script.log").read_text()
        self.assertIn("script=lint", log)
        self.assertIn(f"cwd={self.fixture.source.resolve()}", log)
        self.assertIn("args=--fix", log)

        failing_test = self.fixture.command("test", extra_env={"RECIPE_TEST_TEST_STATUS": "7"})
        self.assertEqual(failing_test.returncode, 7, failing_test.stdout + failing_test.stderr)
        self.assertIn("test failed (7)", failing_test.stderr)
        failing_lint = self.fixture.command("lint", extra_env={"RECIPE_TEST_LINT_STATUS": "9"})
        self.assertEqual(failing_lint.returncode, 9, failing_lint.stdout + failing_lint.stderr)
        self.assertIn("lint failed (9)", failing_lint.stderr)

    def test_command_reuses_dirty_source_and_holds_lock_during_tool(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        authoring = self.fixture.source / "local-authoring.txt"
        write(authoring, "unexported authoring state\n")
        handshake_dir = Path(tempfile.mkdtemp(prefix="tc-command-handshake-", dir=tempfile.gettempdir()))
        handshake = handshake_dir / "s"
        server: socket.socket | None = None
        connection: socket.socket | None = None
        command: subprocess.Popen[str] | None = None
        try:
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(handshake))
            server.listen(1)
            server.settimeout(20)
            command = self.fixture.start_command(
                "test",
                extra_env={
                    "RECIPE_TEST_HANDSHAKE": "1",
                    "RECIPE_TEST_HELPER": sys.executable,
                    "RECIPE_TEST_SOCKET": str(handshake),
                },
            )
            connection, _ = server.accept()
            connection.settimeout(20)
            self.assertEqual(connection.recv(6), b"ready\n")

            status = self.fixture.run("status")
            self.assertEqual(status.returncode, 0, status.stdout + status.stderr)
            busy = json.loads(status.stdout)
            self.assertTrue(busy["operation_busy"])
            self.assertNotIn("source_state", busy)
            self.assertEqual(authoring.read_text(), "unexported authoring state\n")

            connection.sendall(b"release")
            stdout, stderr = command.communicate(timeout=120)
            self.assertEqual(command.returncode, 0, stdout + stderr)
            self.assertIn("local changes", stderr)
            log = (self.fixture.logs / "project-script.log").read_text()
            self.assertIn("local=yes", log)
            self.assertIn(f"cwd={self.fixture.source.resolve()}", log)

            settled = self.fixture.run("status")
            self.assertEqual(settled.returncode, 0, settled.stdout + settled.stderr)
            self.assertFalse(json.loads(settled.stdout)["operation_busy"])
            self.assertEqual(authoring.read_text(), "unexported authoring state\n")
        finally:
            if command is not None and command.poll() is None:
                command.terminate()
                try:
                    command.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    command.kill()
                    command.communicate()
            if connection is not None:
                connection.close()
            if server is not None:
                server.close()
            shutil.rmtree(handshake_dir, ignore_errors=True)

    def test_commands_reject_corrupt_and_stale_source_without_running_tools(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        script_log = self.fixture.logs / "project-script.log"
        receipt_path = self.fixture.source / ".git/tinycast-recipe-receipt.json"
        saved_receipt = receipt_path.read_bytes()
        receipt_path.write_text("not a receipt\n")
        corrupt = self.fixture.command("test")
        self.assertFailsWith(corrupt, "malformed recipe receipt")
        self.assertFalse(script_log.exists())

        receipt_path.write_bytes(saved_receipt)
        write(self.fixture.source / "local-authoring.txt", "unexported authoring state\n")
        patch_text = self.fixture.patch.read_text()
        self.fixture.patch.write_text(patch_text.replace("Subject: [PATCH]", "Subject: [PATCH] changed", 1))
        stale = self.fixture.command("test")
        self.assertFailsWith(stale, "unexported local changes")
        self.assertFalse(script_log.exists())

    def test_save_exports_committed_source_and_preserves_unrelated_index(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        old_patch = (self.fixture.root / ".mine/patches/0001-fork-patch.patch").read_bytes()
        old_root_head = git(self.fixture.root, "rev-parse", "HEAD")
        staged = self.fixture.root / "unrelated-staged.txt"
        write(staged, "must remain staged\n")
        git(self.fixture.root, "add", "--", "unrelated-staged.txt")
        before_index = git(self.fixture.root, "ls-files", "-s", "--", "unrelated-staged.txt")
        source_head = self.fixture.commit_source("saved.txt", "saved source\n", "saved source edit")

        result = self.fixture.run("save")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        saved = json.loads(result.stdout)
        self.assertTrue(saved["exported"])
        self.assertTrue(saved["committed"])
        self.assertEqual(saved["source_head"], source_head)
        self.assertEqual(git(self.fixture.root, "log", "-1", "--format=%s"), "mine: save patches")
        self.assertNotEqual(git(self.fixture.root, "rev-parse", "HEAD"), old_root_head)
        committed_paths = git(self.fixture.root, "show", "--format=", "--name-only", "HEAD").splitlines()
        self.assertEqual(
            committed_paths,
            [".mine/patches/0002-saved-source-edit.patch", ".mine/sources.lock.json"],
        )
        self.assertEqual(git(self.fixture.root, "ls-files", "-s", "--", "unrelated-staged.txt"), before_index)
        self.assertEqual(git(self.fixture.root, "diff", "--cached", "--name-only"), "unrelated-staged.txt")
        self.assertEqual((self.fixture.root / ".mine/patches/0001-fork-patch.patch").read_bytes(), old_patch)
        self.assertEqual(self.fixture.source_fingerprint(), json.loads((self.fixture.root / ".mine/sources.lock.json").read_text())["expected_source"]["fingerprint"])
        receipt = self.fixture.receipt()
        self.assertEqual(receipt["managed_tip"], source_head)
        self.assertEqual(receipt["source_fingerprint"], self.fixture.source_fingerprint())

        saved_root_head = git(self.fixture.root, "rev-parse", "HEAD")
        repeated = self.fixture.run("save")
        self.assertEqual(repeated.returncode, 0, repeated.stdout + repeated.stderr)
        self.assertFalse(json.loads(repeated.stdout)["exported"])
        self.assertEqual(git(self.fixture.root, "rev-parse", "HEAD"), saved_root_head)

        shutil.rmtree(self.fixture.source)
        rebuilt = self.fixture.run()
        self.assertEqual(rebuilt.returncode, 0, rebuilt.stdout + rebuilt.stderr)
        self.assertEqual(self.fixture.source_fingerprint(), json.loads((self.fixture.root / ".mine/sources.lock.json").read_text())["expected_source"]["fingerprint"])

    def test_save_rewrite_requires_flag_keeps_backup_and_rebuilds(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        receipt = self.fixture.receipt()
        base = str(receipt["source_only_base_checkpoint"])
        old_tip = str(receipt["managed_tip"])
        git(self.fixture.source, "branch", "managed-before-rewrite")
        git(self.fixture.source, "checkout", "--quiet", "--detach", base)
        source_head = self.fixture.commit_source("rewritten.txt", "rewritten\n", "rewritten source history")

        rejected = self.fixture.run("save")
        self.assertFailsWith(rejected, "outside managed lineage")

        git(self.fixture.source, "branch", "-D", "managed-before-rewrite")
        accepted = self.fixture.run("save", ["--rewrite"])
        self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
        saved = json.loads(accepted.stdout)
        self.assertTrue(saved["exported"])
        self.assertEqual(saved["source_head"], source_head)
        backup_ref = f"refs/tinycast/rewritten/{old_tip}"
        self.assertEqual(git(self.fixture.source, "rev-parse", backup_ref), old_tip)

        repeated = self.fixture.run("save")
        self.assertEqual(repeated.returncode, 0, repeated.stdout + repeated.stderr)
        self.assertFalse(json.loads(repeated.stdout)["exported"])

        shutil.rmtree(self.fixture.source)
        rebuilt = self.fixture.run()
        self.assertEqual(rebuilt.returncode, 0, rebuilt.stdout + rebuilt.stderr)
        lock = json.loads((self.fixture.root / ".mine/sources.lock.json").read_text())
        self.assertEqual(self.fixture.source_fingerprint(), lock["expected_source"]["fingerprint"])

    def test_save_rewrite_rejects_orphan_history(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        git(self.fixture.source, "checkout", "--quiet", "--orphan", "orphan-history")
        git(self.fixture.source, "rm", "-rf", "--quiet", ".")
        write(self.fixture.source / "orphan.txt", "orphan\n")
        git(self.fixture.source, "add", "orphan.txt")
        git(self.fixture.source, "commit", "--quiet", "-m", "orphan history")

        rejected = self.fixture.run("save", ["--rewrite"])
        self.assertFailsWith(rejected, "outside source-only lineage")

    def test_save_allows_represented_branch_but_rejects_unique_stash(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        git(self.fixture.source, "checkout", "--quiet", "-b", "already-exported")
        no_change = self.fixture.run("save")
        self.assertEqual(no_change.returncode, 0, no_change.stdout + no_change.stderr)
        self.assertFalse(json.loads(no_change.stdout)["exported"])

        write(self.fixture.source / "README.md", "stashed\n")
        git(self.fixture.source, "stash", "push", "--quiet", "-m", "unique unexported stash")
        rejected = self.fixture.run("save")
        self.assertFailsWith(rejected, "unique branches or stashes")
        self.assertIn("refs/stash", git(self.fixture.source, "for-each-ref", "--format=%(refname)"))
        self.assertIn("unique unexported stash", git(self.fixture.source, "stash", "list"))

    def test_save_rejects_dirty_source_and_stale_authoritative_inputs(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        write(self.fixture.source / "uncommitted.txt", "do not export\n")
        dirty = self.fixture.run("save")
        self.assertFailsWith(dirty, "uncommitted, untracked")
        self.assertTrue((self.fixture.source / "uncommitted.txt").exists())

        (self.fixture.source / "uncommitted.txt").unlink()
        write(self.fixture.source / "staged-only.txt", "do not export\n")
        git(self.fixture.source, "add", "staged-only.txt")
        staged = self.fixture.run("save")
        self.assertFailsWith(staged, "uncommitted, untracked")
        git(self.fixture.source, "reset", "--quiet", "HEAD", "--", "staged-only.txt")
        (self.fixture.source / "staged-only.txt").unlink()

        source_head = self.fixture.commit_source("committed.txt", "committed\n", "committed source edit")
        patch = self.fixture.root / ".mine/patches/0001-fork-patch.patch"
        original = patch.read_text()
        patch.write_text(original.replace("Subject: [PATCH]", "Subject: [PATCH] stale", 1))
        stale = self.fixture.run("save")
        self.assertFailsWith(stale, "authoritative lock or patch inputs changed")
        self.assertEqual(git(self.fixture.source, "rev-parse", "HEAD"), source_head)
        self.assertIn("stale", patch.read_text())

    def test_interrupted_save_recovers_old_patch_bytes_before_export(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        build = self.fixture.root / ".build"
        patch_dir = self.fixture.root / ".mine/patches"
        lock_path = self.fixture.root / ".mine/sources.lock.json"
        receipt_path = self.fixture.source / ".git/tinycast-recipe-receipt.json"
        old_patch = (patch_dir / "0001-fork-patch.patch").read_bytes()
        old_root_head = git(self.fixture.root, "rev-parse", "HEAD")
        staged = self.fixture.root / "unrelated-staged.txt"
        write(staged, "must remain staged\n")
        git(self.fixture.root, "add", "--", "unrelated-staged.txt")
        before_index = git(self.fixture.root, "ls-files", "-s", "--", "unrelated-staged.txt")
        source_head = self.fixture.commit_source("recover.txt", "recover\n", "recover source edit")
        old_lock = lock_path.read_bytes()
        old_receipt = receipt_path.read_bytes()

        interrupted = self.run_save_with_publication_fault("exit")
        self.assertEqual(interrupted.returncode, 23, interrupted.stdout + interrupted.stderr)
        journal_path = build / ".source-save-journal.json"
        transaction = self.save_transaction()
        journal = json.loads(journal_path.read_text())
        self.assertEqual(journal["state"], "old-patches-moved")
        self.assertEqual(Path(journal["paths"]["transaction"]).resolve(), transaction.resolve())
        self.assertFalse(patch_dir.exists())
        self.assertEqual((transaction / "old-lock").read_bytes(), old_lock)
        self.assertEqual((transaction / "old-receipt").read_bytes(), old_receipt)
        self.assertEqual(
            (transaction / "previous-patches/0001-fork-patch.patch").read_bytes(), old_patch
        )

        exclude = self.fixture.source / ".git/info/exclude"
        exclude.write_text("local-build-server.json\n")
        ignored = self.fixture.source / "local-build-server.json"
        ignored.write_text('{"local": true}\n')

        result = self.fixture.run("save")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        saved = json.loads(result.stdout)
        self.assertTrue(saved["exported"])
        self.assertTrue(saved["committed"])
        self.assertEqual(saved["source_head"], source_head)
        self.assertEqual((patch_dir / "0001-fork-patch.patch").read_bytes(), old_patch)
        self.assertEqual(
            sorted(path.name for path in patch_dir.glob("*.patch")),
            ["0001-fork-patch.patch", "0002-recover-source-edit.patch"],
        )
        for patch_path in patch_dir.glob("*.patch"):
            self.assertNotIn("local-build-server", patch_path.read_text())
        self.assertEqual(ignored.read_text(), '{"local": true}\n')
        self.assertFalse(journal_path.exists())
        self.assertFalse(transaction.exists())
        self.assertEqual(self.fixture.receipt()["managed_tip"], source_head)
        self.assertEqual(
            self.fixture.source_fingerprint(),
            json.loads(lock_path.read_text())["expected_source"]["fingerprint"],
        )
        self.assertNotEqual(git(self.fixture.root, "rev-parse", "HEAD"), old_root_head)
        committed_paths = git(self.fixture.root, "show", "--format=", "--name-only", "HEAD").splitlines()
        self.assertEqual(
            committed_paths,
            [".mine/patches/0002-recover-source-edit.patch", ".mine/sources.lock.json"],
        )
        self.assertEqual(git(self.fixture.root, "ls-files", "-s", "--", "unrelated-staged.txt"), before_index)
        self.assertEqual(git(self.fixture.root, "diff", "--cached", "--name-only"), "unrelated-staged.txt")

        saved_root_head = git(self.fixture.root, "rev-parse", "HEAD")
        repeated = self.fixture.run("save")
        self.assertEqual(repeated.returncode, 0, repeated.stdout + repeated.stderr)
        self.assertFalse(json.loads(repeated.stdout)["exported"])
        self.assertEqual(git(self.fixture.root, "rev-parse", "HEAD"), saved_root_head)
        guard = self.fixture.run("finish-guard")
        self.assertFailsWith(guard, "ignored files")
        self.assertEqual(ignored.read_text(), '{"local": true}\n')

        fault_head = self.fixture.commit_source("fault.txt", "fault\n", "fault source edit")
        current_lock = lock_path.read_bytes()
        current_receipt = receipt_path.read_bytes()
        failing = self.run_save_with_publication_fault("raise")
        self.assertEqual(failing.returncode, 1, failing.stdout + failing.stderr)
        self.assertIn("previous state was restored", failing.stderr)
        self.assertFalse(journal_path.exists())
        self.assertEqual([path for path in build.glob(".source-save-*") if path.is_dir()], [])
        self.assertEqual((patch_dir / "0001-fork-patch.patch").read_bytes(), old_patch)
        self.assertEqual(
            sorted(path.name for path in patch_dir.glob("*.patch")),
            ["0001-fork-patch.patch", "0002-recover-source-edit.patch"],
        )
        self.assertEqual(lock_path.read_bytes(), current_lock)
        self.assertEqual(receipt_path.read_bytes(), current_receipt)
        self.assertEqual(git(self.fixture.source, "rev-parse", "HEAD"), fault_head)
        self.assertEqual(git(self.fixture.root, "rev-parse", "HEAD"), saved_root_head)
        self.assertEqual(git(self.fixture.root, "diff", "--cached", "--name-only"), "unrelated-staged.txt")
        self.assertEqual(ignored.read_text(), '{"local": true}\n')

    def test_save_preserves_ignored_local_data_without_exporting_it(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        exclude = self.fixture.source / ".git/info/exclude"
        exclude.write_text("local-build-server.json\nlocal-cache/\n")
        ignored_file = self.fixture.source / "local-build-server.json"
        ignored_file.write_text('{"local": true}\n')
        ignored_dir = self.fixture.source / "local-cache"
        ignored_dir.mkdir()
        (ignored_dir / "cache.bin").write_text("cache\n")
        source_head = self.fixture.commit_source(
            "saved-with-ignored.txt", "saved\n", "saved with ignored data"
        )
        result = self.fixture.run("save")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        saved = json.loads(result.stdout)
        self.assertTrue(saved["exported"])
        self.assertTrue(saved["committed"])
        self.assertEqual(saved["source_head"], source_head)
        patch_dir = self.fixture.root / ".mine/patches"
        self.assertEqual(
            sorted(path.name for path in patch_dir.glob("*.patch")),
            ["0001-fork-patch.patch", "0002-saved-with-ignored-data.patch"],
        )
        for patch_path in patch_dir.glob("*.patch"):
            text = patch_path.read_text()
            self.assertNotIn("local-build-server", text)
            self.assertNotIn("local-cache", text)
        self.assertEqual(ignored_file.read_text(), '{"local": true}\n')
        self.assertEqual((ignored_dir / "cache.bin").read_text(), "cache\n")
        self.assertEqual(self.fixture.receipt()["managed_tip"], source_head)
        saved_root_head = git(self.fixture.root, "rev-parse", "HEAD")
        repeated = self.fixture.run("save")
        self.assertEqual(repeated.returncode, 0, repeated.stdout + repeated.stderr)
        self.assertFalse(json.loads(repeated.stdout)["exported"])
        self.assertEqual(git(self.fixture.root, "rev-parse", "HEAD"), saved_root_head)
        self.assertEqual(ignored_file.read_text(), '{"local": true}\n')
        guard = self.fixture.run("finish-guard")
        self.assertFailsWith(guard, "ignored files")
        self.assertEqual(ignored_file.read_text(), '{"local": true}\n')

    def test_interrupted_save_rejects_corrupt_or_missing_rollback_snapshots_before_restore(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        build = self.fixture.root / ".build"
        patch_dir = self.fixture.root / ".mine/patches"
        lock_path = self.fixture.root / ".mine/sources.lock.json"
        receipt_path = self.fixture.source / ".git/tinycast-recipe-receipt.json"
        sentinel = self.fixture.root / "snapshot-sentinel.txt"
        cases = (
            ("old-lock", "corrupt", "rollback lock snapshot"),
            ("old-receipt", "corrupt", "rollback receipt snapshot"),
            ("previous-patches", "corrupt", "rollback patch snapshot"),
            ("old-lock", "missing", "rollback lock snapshot"),
            ("old-lock", "symlink", "rollback lock snapshot"),
        )
        for target, mutation, expected in cases:
            with self.subTest(target=target, mutation=mutation):
                source_head = self.fixture.commit_source(
                    f"recover-{target}-{mutation}.txt", "recover\n", f"recover {target} {mutation}"
                )
                old_lock = lock_path.read_bytes()
                old_receipt = receipt_path.read_bytes()
                interrupted = self.run_save_with_publication_fault("exit")
                self.assertEqual(interrupted.returncode, 23, interrupted.stdout + interrupted.stderr)
                journal_path = build / ".source-save-journal.json"
                transaction = self.save_transaction()
                self.assertTrue(journal_path.exists())
                self.assertFalse(patch_dir.exists())
                snapshot = transaction / target
                sentinel.write_text("preserve me\n")
                original = b""
                if mutation == "corrupt":
                    if target == "previous-patches":
                        snapshot = snapshot / "0001-fork-patch.patch"
                    original = snapshot.read_bytes()
                    snapshot.write_bytes(original + b"tampered\n")
                elif mutation == "missing":
                    original = snapshot.read_bytes()
                    snapshot.unlink()
                else:
                    original = snapshot.read_bytes()
                    snapshot.unlink()
                    snapshot.symlink_to(sentinel)

                rejected = self.fixture.run("save")
                self.assertFailsWith(rejected, expected)
                if mutation == "corrupt":
                    self.assertIn("corrupt", rejected.stderr)
                elif mutation == "missing":
                    self.assertIn("missing", rejected.stderr)
                else:
                    self.assertIn("safely", rejected.stderr)
                self.assertTrue(journal_path.exists())
                self.assertTrue(transaction.exists())
                self.assertFalse(patch_dir.exists())
                self.assertEqual(lock_path.read_bytes(), old_lock)
                self.assertEqual(receipt_path.read_bytes(), old_receipt)
                self.assertEqual(sentinel.read_text(), "preserve me\n")

                if mutation == "symlink":
                    snapshot.unlink()
                snapshot.write_bytes(original)
                completed = self.fixture.run("save")
                self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
                self.assertEqual(self.fixture.receipt()["managed_tip"], source_head)
                self.assertFalse(journal_path.exists())
                self.assertFalse(transaction.exists())

    def test_finish_guard_allows_tooling_only_and_refuses_source_loss(self) -> None:
        tooling_only = self.fixture.run("finish-guard")
        self.assertEqual(tooling_only.returncode, 0, tooling_only.stdout + tooling_only.stderr)
        self.assertIn("no prepared source", tooling_only.stdout)

        self.assertEqual(self.fixture.run().returncode, 0)
        self.fixture.source.joinpath(".git/info/exclude").write_text("ignored-note.txt\n")
        write(self.fixture.source / "ignored-note.txt", "must survive cleanup\n")
        ignored = self.fixture.run("finish-guard")
        self.assertFailsWith(ignored, "ignored files")

        (self.fixture.source / "ignored-note.txt").unlink()
        (self.fixture.source / ".git/info/exclude").write_text("")
        write(self.fixture.source / "unexported.txt", "not saved\n")
        git(self.fixture.source, "add", "unexported.txt")
        git(self.fixture.source, "commit", "--quiet", "-m", "unexported source")
        unexported = self.fixture.run("finish-guard")
        self.assertFailsWith(unexported, "unexported source changes")

        (self.fixture.root / ".build/.source-backup-manual").mkdir()
        predecessor = self.fixture.run("finish-guard")
        self.assertFailsWith(predecessor, "retained or incomplete predecessor")


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(RecipeTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
