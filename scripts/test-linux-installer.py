#!/usr/bin/env python3
"""Exercise install.sh with local release archives; no network or user config."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
INSTALLER = ROOT / "install.sh"
TARGETS = ("linux-x64", "linux-arm64", "linux-x64-musl", "linux-arm64-musl", "macos-x64", "macos-arm64")


class LinuxInstallerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="codeaw-install-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.user_home = self.directory / "user's home"
        self.user_home.mkdir()
        self.downloads = self.directory / "downloads"
        self.downloads.mkdir()
        self.stubs = self.directory / "stubs"
        self.stubs.mkdir()
        self.application = self.user_home / ".local/share/codeaw-bridge"
        self.command = self.user_home / ".local/bin/codeaw-bridge"
        self.env = {
            "PATH": f"{self.stubs}:/usr/bin:/bin",
            "HOME": str(self.user_home),
            "TEST_ROOT": str(self.directory),
            "TEST_MACHINE": "x86_64",
            "TEST_OS": "Linux",
            "TEST_LIBC": "glibc",
        }
        self.stub("uname", 'case "$1" in -s) echo "$TEST_OS";; -m) echo "$TEST_MACHINE";; esac')
        self.stub("ldd", '''
if [ "$TEST_LIBC" = musl ]; then echo 'musl libc' >&2; exit 1; fi
echo 'ldd (GNU libc)'
''')
        self.stub("curl", '''
output=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        --retry|--connect-timeout|--max-time|--proto|--proto-redir) shift 2 ;;
        --*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf '%s\\n' "$url" >> "$TEST_ROOT/requests"
[ "${TEST_DOWNLOAD_FAIL:-0}" = 0 ] || exit 22
cp "$TEST_ROOT/downloads/${url##*/}" "$output"
''')
        if not shutil.which("sha256sum", path="/usr/bin:/bin"):
            self.stub("sha256sum", 'exec /usr/bin/shasum -a 256 "$@"')
        self.stub("mv", '''
if [ "${TEST_FAIL_LINK:-0}" = 1 ] && [ "$1" = -f ]; then exit 1; fi
exec /bin/mv "$@"
''')
        self.make_release()

    def stub(self, name, body):
        target = self.stubs / name
        target.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
        target.chmod(0o755)

    def make_release(self, text="first", web=True, executable=True, runnable=True):
        files = {"LICENSE": b"fixture license", "codeaw-menu": b"#!/bin/sh\nexit 0\n"}
        if executable:
            files["codeaw-bridge"] = f"#!/bin/sh\n[ \"$1\" = --help ] || exit 1\necho '{text}'\n".encode()
            if not runnable:
                files["codeaw-bridge"] = b"#!/bin/sh\nexit 1\n"
        if web:
            files["web/index.html"] = text.encode()
        sums = []
        for target in TARGETS:
            name = f"codeaw-bridge-{target}.tar.gz"
            archive = self.downloads / name
            with tarfile.open(archive, "w:gz") as bundle:
                for member, data in files.items():
                    info = tarfile.TarInfo("./" + member)
                    info.size = len(data)
                    info.mode = 0o755 if member in ("codeaw-bridge", "codeaw-menu") else 0o644
                    bundle.addfile(info, io.BytesIO(data))
            sums.append(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {name}\n")
        (self.downloads / "SHA256SUMS").write_text("".join(sums))

    def install(self, *args, success=True, piped=False):
        result = subprocess.run(
            ["sh", "-s", "--", *args] if piped else ["sh", str(INSTALLER), *args],
            input=INSTALLER.read_text() if piped else None,
            env=self.env, text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def assert_clean(self):
        self.assertFalse(list(self.application.parent.glob(".codeaw-install.*")))

    def test_platforms_and_piped_install(self):
        for machine, libc, target in (
            ("x86_64", "glibc", "linux-x64"),
            ("aarch64", "glibc", "linux-arm64"),
            ("x86_64", "musl", "linux-x64-musl"),
            ("aarch64", "musl", "linux-arm64-musl"),
        ):
            with self.subTest(target=target):
                self.env.update(TEST_MACHINE=machine, TEST_LIBC=libc)
                self.install(piped=True)
                self.assertIn(f"/nightly/codeaw-bridge-{target}.tar.gz", (self.directory / "requests").read_text())
                self.assertEqual(self.command.resolve(), self.application / "codeaw-bridge")
                self.assertEqual((self.application / "web/index.html").read_text(), "first")
                self.assertEqual(subprocess.check_output([self.command, "--help"], text=True).strip(), "first")
                self.assert_clean()

    def test_macos_platforms_and_menu_bar(self):
        self.env["TEST_OS"] = "Darwin"
        for machine, target in (("x86_64", "macos-x64"), ("arm64", "macos-arm64")):
            with self.subTest(target=target):
                self.env["TEST_MACHINE"] = machine
                result = self.install(piped=True)
                self.assertIn(target, result.stdout)
                self.assertIn("autostart install", result.stdout)
                self.assertTrue((self.application / "codeaw-menu").is_file())
                self.assert_clean()

    def test_upgrade_preserves_config_and_replaces_web(self):
        config = self.user_home / ".codeaw/config.yaml"
        config.parent.mkdir()
        config.write_text("agents: {}\n")
        self.install()
        (self.application / "web/obsolete.js").write_text("old")
        self.make_release("second")
        self.install()
        self.assertEqual(config.read_text(), "agents: {}\n")
        self.assertEqual((self.application / "web/index.html").read_text(), "second")
        self.assertFalse((self.application / "web/obsolete.js").exists())
        self.assert_clean()

    def test_pinned_and_stable_releases(self):
        for version, fragment in (("latest", "/releases/latest/download/"), ("v0.2.0", "/releases/download/v0.2.0/")):
            self.install("--version", version)
            self.assertIn(fragment + "SHA256SUMS", (self.directory / "requests").read_text())

    def test_custom_directories_and_path_hint(self):
        self.application = self.directory / "custom app"
        self.command = self.directory / "custom bin's/codeaw-bridge"
        result = self.install("--install-dir", str(self.application), "--bin-dir", str(self.command.parent))
        self.assertTrue(self.command.is_symlink())
        hint = next(line.strip() for line in result.stdout.splitlines() if line.strip().startswith("export PATH="))
        actual = subprocess.check_output(["sh", "-c", hint + '\nprintf "%s" "$PATH"'], env=self.env, text=True)
        self.assertEqual(actual, str(self.command.parent) + ":" + self.env["PATH"])
        self.assert_clean()

    def test_xdg_data_directory(self):
        self.env["XDG_DATA_HOME"] = str(self.directory / "data")
        self.install()
        self.assertEqual(self.command.resolve(), self.directory / "data/codeaw-bridge/codeaw-bridge")

    def test_bad_download_leaves_install_untouched(self):
        self.install()
        self.make_release("second")
        archive = self.downloads / "codeaw-bridge-linux-x64.tar.gz"
        archive.write_bytes(archive.read_bytes() + b"corrupted")
        result = self.install(success=False)
        self.assertIn("Checksum verification failed", result.stderr)
        self.assertEqual((self.application / "web/index.html").read_text(), "first")
        self.assert_clean()

    def test_missing_duplicate_checksums_and_download_failure(self):
        sums = self.downloads / "SHA256SUMS"
        original = sums.read_text()
        for contents in ("", original + original):
            sums.write_text(contents)
            self.install(success=False)
            self.assertFalse(self.application.exists())
            self.assert_clean()
        sums.write_text(original)
        self.env["TEST_DOWNLOAD_FAIL"] = "1"
        self.install(success=False)
        self.assertFalse(self.application.exists())
        self.assert_clean()

    def test_incomplete_archive_keeps_previous_install(self):
        self.install()
        for web, executable in ((False, True), (True, False)):
            self.make_release("second", web=web, executable=executable)
            self.install(success=False)
            self.assertEqual((self.application / "web/index.html").read_text(), "first")
            self.assert_clean()

    def test_failed_command_install_rolls_back(self):
        self.install()
        self.make_release("second")
        self.env["TEST_FAIL_LINK"] = "1"
        self.install(success=False)
        self.assertEqual((self.application / "web/index.html").read_text(), "first")
        self.assertEqual(subprocess.check_output([self.command, "--help"], text=True).strip(), "first")
        self.assert_clean()

    def test_unusable_executable_keeps_previous_install(self):
        self.install()
        self.make_release("second", runnable=False)
        result = self.install(success=False)
        self.assertIn("cannot run on this system", result.stderr)
        self.assertEqual((self.application / "web/index.html").read_text(), "first")
        self.assert_clean()

    def test_failed_fresh_install_cleans_application(self):
        self.env["TEST_FAIL_LINK"] = "1"
        self.install(success=False)
        self.assertFalse(self.application.exists())
        self.assertFalse(self.command.exists())
        self.assert_clean()

    def test_refuses_application_symlink(self):
        original = self.directory / "original"
        original.mkdir()
        (original / ".codeaw-installer").touch()
        (original / "keep.txt").write_text("keep")
        self.application.parent.mkdir(parents=True)
        self.application.symlink_to(original, target_is_directory=True)
        self.install(success=False)
        self.assertEqual((original / "keep.txt").read_text(), "keep")
        self.assertTrue(self.application.is_symlink())

    def test_refuses_unrelated_files(self):
        self.application.mkdir(parents=True)
        original = self.application / "keep.txt"
        original.write_text("keep")
        self.install(success=False)
        self.assertEqual(original.read_text(), "keep")
        self.command.parent.mkdir(parents=True, exist_ok=True)
        self.command.write_text("existing command")
        self.install("--install-dir", str(self.directory / "another app"), success=False)
        self.assertEqual(self.command.read_text(), "existing command")

    def test_invalid_arguments_and_platforms_make_no_downloads(self):
        for args in (("--version",), ("--unknown",), ("--version", "../bad"), ("--install-dir", "/"), ("--bin-dir", "relative")):
            self.install(*args, success=False)
        for machine, system in (("armv7l", "Linux"), ("x86_64", "FreeBSD")):
            self.env.update(TEST_MACHINE=machine, TEST_OS=system)
            self.install(success=False)
        self.install("--help")
        self.assertFalse((self.directory / "requests").exists())

    @unittest.skipUnless(os.environ.get("CODEAW_TEST_PACKAGE"), "set CODEAW_TEST_PACKAGE to test a compiled release")
    def test_native_release_and_bundled_web(self):
        archive = self.downloads / "codeaw-bridge-linux-x64.tar.gz"
        shutil.copyfile(os.environ["CODEAW_TEST_PACKAGE"], archive)
        (self.downloads / "SHA256SUMS").write_text(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")
        self.install()
        # The existing smoke checks self-relaunch, serving web/, and clean shutdown
        # through the installed command, with its own isolated config.
        subprocess.run([shutil.which("node"), str(ROOT / "bridge/scripts/background-smoke.mjs"), str(self.command)], check=True, timeout=90)


if __name__ == "__main__":
    unittest.main(verbosity=2)
