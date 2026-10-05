import copy
import datetime
import hashlib
import os
import pathlib
import subprocess
import sys
import unittest
from local_signing import validate_profile


class SigningPreflightTests(unittest.TestCase):
    def setUp(self):
        self.team = "TEST123456"
        self.now = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
        self.cert = b"synthetic certificate test fixture, not a real credential"
        self.identities = {hashlib.sha1(self.cert).hexdigest().upper()}
        self.profile = {
            "TeamIdentifier": [self.team], "ApplicationIdentifierPrefix": [self.team],
            "Entitlements": {"com.apple.developer.team-identifier": self.team,
                "application-identifier": self.team + ".com.gnabcamirl.app", "get-task-allow": False},
            "ExpirationDate": datetime.datetime(2027, 1, 1),
            "UUID": "12345678-1234-1234-1234-123456789ABC", "DeveloperCertificates": [self.cert],
        }

    def test_matching_profile(self):
        uuid, fingerprint = validate_profile(self.profile, self.team, self.identities, self.now)
        self.assertEqual(uuid, self.profile["UUID"])
        self.assertIn(fingerprint, self.identities)

    def test_wrong_app_team_expiry_and_distribution(self):
        mutations = [
            lambda p: p["Entitlements"].update({"application-identifier": self.team + ".com.other.app"}),
            lambda p: p["Entitlements"].update({"application-identifier": self.team + ".*"}),
            lambda p: p.update({"TeamIdentifier": ["OTHER12345"]}),
            lambda p: p.update({"ExpirationDate": datetime.datetime(2020, 1, 1)}),
            lambda p: p["Entitlements"].update({"get-task-allow": True}),
            lambda p: p.update({"ProvisionedDevices": ["test-device"]}),
            lambda p: p.update({"ProvisionsAllDevices": True}),
            lambda p: p.update({"UUID": "-" * 36}),
        ]
        for mutate in mutations:
            profile = copy.deepcopy(self.profile)
            mutate(profile)
            with self.assertRaises(ValueError):
                validate_profile(profile, self.team, self.identities, self.now)

    def test_requires_matching_installed_private_identity(self):
        with self.assertRaises(ValueError):
            validate_profile(self.profile, self.team, set(), self.now)

    def test_ci_refused_before_any_profile_access(self):
        result = subprocess.run(
            [sys.executable, str(pathlib.Path(__file__).with_name("local_signing.py"))],
            env={**os.environ, "CI": "true"}, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("never in CI", result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
