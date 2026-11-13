import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import macos_distribution as packaging

spec = importlib.util.spec_from_file_location("sign_notarize", SCRIPTS / "sign-notarize.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
build_spec = importlib.util.spec_from_file_location("build_local_app", SCRIPTS / "build-local-app.py")
builder = importlib.util.module_from_spec(build_spec)
build_spec.loader.exec_module(builder)
PRODUCT = {"name": "Cachora", "version": "0.1.0-beta.1", "build": "1",
           "bundle_identifier": "io.github.example.cachora", "github_repository": "example/cachora", "beta": True, "chinese_name": "轻盘", "storage_directory": "Cachora"}
IDENTITY = {"fingerprint": "A" * 40, "name": "Developer ID Application: Example (ABCDEFGHIJ)"}
SUBMISSION = "11111111-2222-3333-4444-555555555555"


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cachora-distribution-test-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.app = self.folder / "Cachora.app"
        executable = self.app / "Contents/MacOS/PureMac"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"disposable executable fixture")
        executable.chmod(0o755)
        self.info = {"CFBundleName": "Cachora", "CFBundleShortVersionString": PRODUCT["version"],
                     "CFBundleVersion": "1", "CFBundleIdentifier": PRODUCT["bundle_identifier"],
                     "CFBundleExecutable": "PureMac", "SafeCleanupBeta": True}
        self.write_info()

    def write_info(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    def manifest(self):
        return {"product": PRODUCT.copy(), "identity": IDENTITY.copy(),
                "notary_profile": "test-profile", "distribution_ready": False,
                "app_digest": packaging.bundle_digest(self.app)}

    def record(self, filename, status="In Progress"):
        file = self.folder / filename
        file.write_bytes(b"disposable archive")
        return {"archive": filename, "sha256": packaging.sha256(file), "id": SUBMISSION, "status": status}

    def test_normal_bundle_accepted(self):
        self.assertEqual(packaging.validate_app(self.app, PRODUCT), self.info)

    def test_stable_channel_is_encoded_and_checked(self):
        product = dict(PRODUCT, version="0.1.0", build="18", beta=False)
        self.info = builder.bundle_metadata(self.info, product)
        self.write_info()
        self.assertFalse(packaging.validate_app(self.app, product)["SafeCleanupBeta"])
        self.info["SafeCleanupBeta"] = True
        self.write_info()
        with self.assertRaisesRegex(packaging.DistributionError, "channel"):
            packaging.validate_app(self.app, product)

    def test_version_and_channel_must_agree(self):
        for version, beta in [("0.1.0", True), ("0.1.0-beta.1", False), ("0.1.0", "false"), ("../release", False)]:
            with self.subTest(version=version, beta=beta):
                with self.assertRaises(packaging.DistributionError):
                    packaging.validate_product(dict(PRODUCT, version=version, beta=beta))

    def test_stable_fixture_stays_isolated_and_cannot_be_distributed(self):
        product = dict(PRODUCT, version="0.1.0", build="18", beta=False)
        self.info = builder.bundle_metadata(self.info, product, self.folder / "sample", self.folder)
        self.write_info()
        self.assertIn("PureMacFixtureRoot", self.info)
        self.assertNotIn("NSServices", self.info)
        with self.assertRaisesRegex(packaging.DistributionError, "test fixture"):
            packaging.validate_app(self.app, product)

    def test_repackaging_rejects_missing_or_changed_source_digest(self):
        with self.assertRaises(packaging.DistributionError):
            builder.verify_compiled_sources(self.folder, "current-source")
        (self.folder / "app-source-sha256.txt").write_text("old-source")
        with self.assertRaises(packaging.DistributionError):
            builder.verify_compiled_sources(self.folder, "current-source")
        (self.folder / "app-source-sha256.txt").write_text("current-source")
        builder.verify_compiled_sources(self.folder, "current-source")

    def test_stable_local_installer_does_not_claim_beta_or_notarization(self):
        product = dict(PRODUCT, version="0.1.0", build="18", beta=False)
        with patch.object(packaging, "run"):
            packaging.make_dmg(self.app, self.folder / "stable.dmg", self.folder, product, preview=True)
        notices = list(self.folder.glob("disk-layout-*/安装说明.txt"))
        self.assertEqual(len(notices), 1)
        text = notices[0].read_text()
        self.assertIn("0.1.0（Build 18）", text)
        self.assertNotIn("内测", text)
        self.assertIn("未获 Apple 发行签名和公证", text)

    def test_fixture_even_with_empty_marker_refused(self):
        self.info["PureMacFixtureRoot"] = ""
        self.write_info()
        with self.assertRaisesRegex(packaging.DistributionError, "test fixture"):
            packaging.validate_app(self.app, PRODUCT)

    def test_stale_and_wrong_product_refused(self):
        for key, value in [("CFBundleVersion", "9"), ("CFBundleIdentifier", "wrong.application")]:
            with self.subTest(key=key):
                old = self.info[key]
                self.info[key] = value
                self.write_info()
                with self.assertRaises(packaging.DistributionError):
                    packaging.validate_app(self.app, PRODUCT)
                self.info[key] = old

    def test_external_bundle_link_refused(self):
        sentinel = self.folder / "outside.txt"
        sentinel.write_text("preserve me")
        (self.app / "Contents/external").symlink_to(sentinel)
        with self.assertRaisesRegex(packaging.DistributionError, "external symbolic link"):
            packaging.validate_app(self.app, PRODUCT)
        self.assertEqual(sentinel.read_text(), "preserve me")

    def test_nested_code_requires_explicit_plan(self):
        framework = self.app / "Contents/Frameworks/Example.framework"
        framework.mkdir(parents=True)
        with self.assertRaisesRegex(packaging.DistributionError, "signing plan"):
            packaging.validate_app(self.app, PRODUCT)

    def test_fingerprint_detects_content_and_permission_changes(self):
        executable = self.app / "Contents/MacOS/PureMac"
        original = packaging.bundle_digest(self.app)
        executable.chmod(0o700)
        self.assertNotEqual(original, packaging.bundle_digest(self.app))
        executable.chmod(0o755)
        self.assertEqual(original, packaging.bundle_digest(self.app))
        executable.write_bytes(b"changed")
        self.assertNotEqual(original, packaging.bundle_digest(self.app))

    def test_signing_identity_must_match_exactly(self):
        self.assertEqual(signing.select_identity([IDENTITY], IDENTITY["name"]), IDENTITY)
        self.assertEqual(signing.select_identity([IDENTITY], "a" * 40), IDENTITY)
        for available, requested in [([IDENTITY], "Developer ID"), ([IDENTITY, IDENTITY], None), ([], None)]:
            with self.assertRaises(packaging.DistributionError):
                signing.select_identity(available, requested)

    def test_attempts_preserve_old_results_and_reject_path_traversal(self):
        first = signing.new_attempt(self.folder, PRODUCT)
        (first / "keep.txt").write_text("old result")
        second = signing.new_attempt(self.folder, PRODUCT)
        self.assertNotEqual(first, second)
        self.assertEqual((first / "keep.txt").read_text(), "old result")
        with self.assertRaises(packaging.DistributionError):
            signing.new_attempt(self.folder, dict(PRODUCT, version="../../outside"))

    def test_pending_submission_resumes_without_duplicate_upload(self):
        archive = self.folder / "payload.zip"
        archive.write_bytes(b"disposable payload")
        manifest = self.manifest()
        responses = [json.dumps({"id": SUBMISSION, "status": "In Progress"}),
                     json.dumps({"id": SUBMISSION, "status": "In Progress"}),
                     json.dumps({"id": SUBMISSION, "status": "Accepted"})]
        with patch.object(signing, "run", side_effect=responses) as command:
            signing.submit_once(self.folder, manifest, "app", archive)
            self.assertFalse(signing.ensure_accepted(self.folder, manifest, "app"))
            resumed = json.loads((self.folder / "state.json").read_text())
            signing.submit_once(self.folder, resumed, "app", archive)
            self.assertTrue(signing.ensure_accepted(self.folder, resumed, "app"))
            self.assertEqual(sum("submit" in call.args[0] for call in command.call_args_list), 1)

    def test_unknown_submission_outcome_is_not_silently_reuploaded(self):
        archive = self.folder / "payload.zip"
        archive.write_bytes(b"disposable payload")
        manifest = self.manifest()
        with patch.object(signing, "run", side_effect=packaging.DistributionError("network lost")) as command:
            with self.assertRaises(packaging.DistributionError):
                signing.submit_once(self.folder, manifest, "app", archive)
            signing.submit_once(self.folder, manifest, "app", archive)
            with self.assertRaisesRegex(packaging.DistributionError, "outcome unknown"):
                signing.ensure_accepted(self.folder, manifest, "app")
            command.assert_called_once()

    def test_tampered_submission_never_contacts_apple(self):
        manifest = self.manifest()
        manifest["app"] = self.record("payload.zip")
        (self.folder / "payload.zip").write_bytes(b"tampered")
        with patch.object(signing, "run") as command:
            with self.assertRaisesRegex(packaging.DistributionError, "archive changed"):
                signing.ensure_accepted(self.folder, manifest, "app")
            command.assert_not_called()

    def test_mismatched_apple_submission_id_refused(self):
        manifest = self.manifest()
        manifest["app"] = self.record("payload.zip")
        with patch.object(signing, "run", return_value=json.dumps({"id": "other", "status": "Accepted"})):
            with self.assertRaisesRegex(packaging.DistributionError, "mismatched"):
                signing.ensure_accepted(self.folder, manifest, "app")

    def test_pending_app_cannot_generate_public_installer(self):
        manifest = self.manifest()
        manifest["app"] = self.record("notary-submission.zip")
        with patch.object(signing, "verify_developer_signature"), patch.object(signing, "make_dmg") as dmg:
            with patch.object(signing, "run", return_value=json.dumps({"id": SUBMISSION, "status": "In Progress"})):
                self.assertFalse(signing.finish_release(self.folder, manifest)["distribution_ready"])
            dmg.assert_not_called()
        self.assertFalse((self.folder / "dist").exists())

    def test_rejected_dmg_blocks_public_output_even_after_app_acceptance(self):
        manifest = self.manifest()
        manifest.update(app_stapled=True, app=self.record("notary-submission.zip", "Accepted"))
        manifest["dmg"] = self.record("Cachora-0.1.0-beta.1-arm64.dmg")
        with patch.object(signing, "verify_developer_signature"), patch.object(signing, "run", side_effect=[
                json.dumps({"id": SUBMISSION, "status": "Invalid"}), "log saved"]):
            with self.assertRaisesRegex(packaging.DistributionError, "Apple rejected dmg"):
                signing.finish_release(self.folder, manifest)
        self.assertFalse((self.folder / "dist").exists())

    def test_adhoc_signature_is_never_an_apple_distribution_signature(self):
        result = type("Result", (), {"stdout": "", "stderr": "Signature=adhoc\nflags=runtime\nTimestamp=now"})()
        with patch.object(signing, "assess_app"), patch.object(signing.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(packaging.DistributionError, "Developer ID"):
                signing.verify_developer_signature(self.app, IDENTITY)

    def accepted_release(self):
        manifest = self.manifest()
        manifest.update(app_stapled=True, dmg_stapled=True,
                        app=self.record("notary-submission.zip", "Accepted"))
        manifest["dmg"] = self.record("Cachora-0.1.0-beta.1-arm64.dmg", "Accepted")
        self.record("Cachora-0.1.0-beta.1-arm64.zip", "Accepted")
        return manifest

    def test_success_publishes_only_after_both_tickets_and_install_checks(self):
        manifest = self.accepted_release()
        with patch.object(signing, "verify_developer_signature"), patch.object(signing, "run") as command:
            with patch.object(signing, "verify_installers", return_value={"round_trip": "passed"}) as check:
                result = signing.finish_release(self.folder, manifest)
                check.assert_called_once()
        self.assertTrue(result["distribution_ready"])
        dist = self.folder / "dist"
        self.assertEqual(len(list(dist.iterdir())), 4)
        report = json.loads((dist / "verification.json").read_text())
        self.assertTrue(report["notarized"])
        self.assertNotIn("notary_profile", report)
        for name, digest in report["artifacts"].items():
            self.assertEqual(packaging.sha256(dist / name), digest)
        self.assertTrue(any("spctl" in str(call.args[0][0]) for call in command.call_args_list))

    def test_gatekeeper_failure_retains_candidates_without_public_output(self):
        manifest = self.accepted_release()
        def command(args):
            if str(args[0]).endswith("spctl"):
                raise packaging.DistributionError("Gatekeeper refused")
            return ""
        with patch.object(signing, "verify_developer_signature"), patch.object(signing, "run", side_effect=command):
            with self.assertRaisesRegex(packaging.DistributionError, "Gatekeeper"):
                signing.finish_release(self.folder, manifest)
        self.assertFalse((self.folder / "dist").exists())
        self.assertTrue((self.folder / manifest["dmg"]["archive"]).exists())

    def test_changed_staged_application_stops_before_any_network_or_signing(self):
        manifest = self.accepted_release()
        (self.app / "Contents/MacOS/PureMac").write_bytes(b"changed application")
        with patch.object(signing, "verify_developer_signature") as signature:
            with self.assertRaisesRegex(packaging.DistributionError, "application changed"):
                signing.finish_release(self.folder, manifest)
            signature.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
