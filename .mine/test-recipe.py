#!/usr/bin/env python3
"""Real-CLI tests for the pinned Tinycast source recipe."""

from __future__ import annotations

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
        self.processes: list[subprocess.Popen[str]] = []
        self.upstream = self.root / "upstream.git"
        self.space = self.root / "space.git"
        self._make_upstream()
        self._make_space()
        self._make_patch()
        self._write_lock()

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
        path.mkdir(parents=True)
        git(path, "init", "--quiet")
        git(path, "config", "user.name", "Recipe Fixture")
        git(path, "config", "user.email", "fixture@localhost")

    def _make_upstream(self) -> None:
        self._init(self.upstream)
        write(self.upstream / "README.md", "upstream\n")
        write(self.upstream / "project.yml", "name: Fixture\n")
        write(self.upstream / ".github/workflows/upstream.yml", "name: upstream\n")
        git(self.upstream, "add", "-A")
        git(self.upstream, "commit", "--quiet", "-m", "upstream base")
        self.upstream_commit = git(self.upstream, "rev-parse", "HEAD")

    def _make_space(self) -> None:
        self._init(self.space)
        write(
            self.space / ".space/apply.sh",
            "#!/bin/sh\n"
            "set -eu\n"
            "if [ \"${RECIPE_TEST_HANDSHAKE:-0}\" = 1 ]; then\n"
            "  \"${RECIPE_TEST_HELPER:?}\" -c 'import os, socket; s=socket.socket(socket.AF_UNIX); s.connect(os.environ[\"RECIPE_TEST_SOCKET\"]); s.sendall(b\"ready\\n\"); s.recv(1); s.close()'\n"
            "fi\n"
            "printf '%s\\n' applying-space-pipeline\n"
            "printf '%s\\n' generated > generated.txt\n",
            0o755,
        )
        write(self.space / ".space/README.md", "fixture Space\n")
        write(self.space / ".github/workflows/space.yml", "name: space\n")
        git(self.space, "add", "-A")
        git(self.space, "commit", "--quiet", "-m", "Space snapshot")
        self.space_commit = git(self.space, "rev-parse", "HEAD")

    def _make_patch(self) -> None:
        patch_work = self.root / "patch-work"
        git(self.root, "clone", "--quiet", str(self.upstream), str(patch_work))
        git(patch_work, "config", "user.name", "Recipe Fixture")
        git(patch_work, "config", "user.email", "fixture@localhost")
        write(patch_work / "fork.txt", "fork patch\n")
        git(patch_work, "add", "fork.txt")
        git(patch_work, "commit", "--quiet", "-m", "fork patch")
        patch = subprocess.run(
            ["git", "-C", str(patch_work), "format-patch", "--stdout", "--no-stat", f"{self.upstream_commit}..HEAD"],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout
        self.patch = self.root / ".mine/patches/0001-fork.patch"
        self.patch.write_bytes(patch)

    def _expected_fingerprint(self) -> str:
        expected = self.root / "expected"
        git(self.root, "clone", "--quiet", str(self.upstream), str(expected))
        space_checkout = self.root / "space-checkout"
        git(self.root, "clone", "--quiet", str(self.space), str(space_checkout))
        git(space_checkout, "checkout", "--quiet", "--detach", self.space_commit)
        workflows = expected / ".github/workflows"
        shutil.rmtree(workflows)
        shutil.copytree(space_checkout / ".github/workflows", workflows)
        shutil.copytree(space_checkout / ".space", expected / ".space")
        subprocess.run(["bash", str(expected / ".space/apply.sh")], cwd=expected, check=True, capture_output=True)
        git(expected, "add", "-A")
        git(expected, "commit", "--quiet", "-m", "Space base")
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
            "schema": 1,
            "original_reference_revision": self.upstream_commit,
            "upstream": {
                "url": self.upstream.resolve().as_uri(),
                "commit": self.upstream_commit,
                "release_tag": "v1.2.3",
                "release_version": "1.2.3",
            },
            "space": {
                "url": self.space.resolve().as_uri(),
                "commit": self.space_commit,
                "source_paths": [".space", ".github/workflows"],
            },
            "expected_source": {
                "fingerprint": self._expected_fingerprint(),
                "record_format": "git-ls-tree-z-v1",
                "excluded_paths": [".mine/", "Makefile"],
            },
        }
        write(self.root / ".mine/sources.lock.json", json.dumps(lock, indent=2) + "\n")

    @property
    def source(self) -> Path:
        return self.root / ".build/source"

    def run(
        self,
        command: str = "prepare",
        extra_env: dict[str, str] | None = None,
        timeout: float = 120,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [sys.executable, str(self.root / ".mine/recipe.py"), command],
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

    def receipt(self) -> dict[str, object]:
        return json.loads((self.source / ".git/tinycast-recipe-receipt.json").read_text())


class RecipeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = Fixture()

    def tearDown(self) -> None:
        self.fixture.close()

    def assertFailsWith(self, result: subprocess.CompletedProcess[str], text: str) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(text, result.stderr)

    def test_pristine_repeat_independent_source_and_status(self) -> None:
        first = self.fixture.run()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        first_json = json.loads(first.stdout)
        self.assertTrue(first_json["fresh"])
        self.assertFalse(first_json["reused"])
        self.assertIn("applying-space-pipeline", first.stderr)
        first_head = git(self.fixture.source, "rev-parse", "HEAD")
        self.assertTrue((self.fixture.source / ".git").is_dir())
        self.assertEqual(git(self.fixture.source, "remote"), "")
        self.assertEqual(git(self.fixture.source, "for-each-ref", "--format=%(refname)"), "")
        self.assertFalse((self.fixture.source / ".git/objects/info/alternates").exists())
        receipt = self.fixture.receipt()
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
        receipt["locked"]["space"] = "0" * 40
        receipt_path.write_text(json.dumps(receipt))
        self.assertFailsWith(self.fixture.run(), "malformed recipe receipt")
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


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(RecipeTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
