import unittest
import os
from unittest.mock import patch
from ci_signing import validate_context, validate_archive, child_environment, main


class GitHubSigningTests(unittest.TestCase):
    def setUp(self):
        self.env = dict(GITHUB_ACTIONS='true', GITHUB_REPOSITORY='gnaboret/nabcam-ios',
                        GITHUB_REF='refs/heads/main', GITHUB_EVENT_NAME='workflow_dispatch',
                        GNAB_BUILD_NUMBER='1', GNAB_UPLOAD='false')

    def test_only_manual_main_runs_allowed(self):
        self.assertEqual(validate_context(self.env), '1')
        for key, bad in [('GITHUB_ACTIONS', 'false'), ('GITHUB_REPOSITORY', 'fork/nabcam-ios'),
                         ('GITHUB_REF', 'refs/pull/1/merge'), ('GITHUB_EVENT_NAME', 'pull_request'),
                         ('GNAB_UPLOAD', 'yes')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_context({**self.env, key: bad})

    def test_build_numbers_cannot_inject_arguments(self):
        for bad in ['', '0', '-1', '1; echo bad', '1\n2', '1000000000', '1.2']:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                validate_context({**self.env, 'GNAB_BUILD_NUMBER': bad})

    def test_archive_must_be_correct_device_build(self):
        info = dict(CFBundleIdentifier='com.gnabcamirl.app', CFBundleDisplayName='GNAB CAM IRL',
                    CFBundleVersion='1', DTPlatformName='iphoneos')
        validate_archive(info, {'NSPrivacyTracking': False}, '1')
        for key, value in [('CFBundleIdentifier', 'com.other.app'), ('CFBundleDisplayName', 'Other'),
                           ('CFBundleVersion', '2'), ('DTPlatformName', 'iphonesimulator')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_archive({**info, key: value}, {'NSPrivacyTracking': False}, '1')
        with self.assertRaises(ValueError):
            validate_archive(info, {'NSPrivacyTracking': True}, '1')

    def test_build_children_do_not_inherit_raw_signing_secrets(self):
        env = {'PATH': '/usr/bin', 'RUNNER_TEMP': '/tmp/test', 'GNAB_BUILD_NUMBER': '1',
               'APPLE_CERTIFICATE_PASSWORD': 'synthetic', 'APPLE_CERTIFICATE_P12_BASE64': 'synthetic',
               'APP_STORE_CONNECT_API_KEY_BASE64': 'synthetic'}
        self.assertEqual(child_environment(env), {'PATH': '/usr/bin', 'RUNNER_TEMP': '/tmp/test',
                                                  'GNAB_BUILD_NUMBER': '1'})
        self.assertIn('APPLE_CERTIFICATE_PASSWORD', env)

    def test_untrusted_context_stops_before_files_or_processes(self):
        with patch.dict(os.environ, {}, clear=True), patch('ci_signing.tempfile.mkdtemp') as temporary, \
                patch('ci_signing.subprocess.run') as process:
            with self.assertRaises(ValueError):
                main()
            temporary.assert_not_called()
            process.assert_not_called()


if __name__ == '__main__':
    unittest.main()
