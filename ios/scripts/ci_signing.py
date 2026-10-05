"""Manually authorized GitHub signing/upload. Never exports signing artifacts."""
import base64
import hashlib
import os
import pathlib
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import datetime
from local_signing import BUNDLE, validate_profile


def validate_context(env):
    if (env.get('GITHUB_ACTIONS') != 'true' or env.get('GITHUB_REPOSITORY') != 'gnaboret/nabcam-ios'
            or env.get('GITHUB_REF') != 'refs/heads/main' or env.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'):
        raise ValueError('Signing requires a manual main-branch run in gnaboret/nabcam-ios.')
    number = env.get('GNAB_BUILD_NUMBER', '')
    if not re.fullmatch(r'[1-9][0-9]{0,8}', number):
        raise ValueError('Build number must be a positive integer of at most nine digits.')
    if env.get('GNAB_UPLOAD') not in ('true', 'false'):
        raise ValueError('Choose explicitly whether to upload to TestFlight.')
    return number


def validate_archive(info, privacy, number):
    expected = {'CFBundleIdentifier': BUNDLE, 'CFBundleDisplayName': 'GNAB CAM IRL',
                'CFBundleVersion': number, 'DTPlatformName': 'iphoneos'}
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError('Archive identity, build number, or platform is wrong.')
    if privacy.get('NSPrivacyTracking') is not False:
        raise ValueError('Unexpected privacy tracking declaration.')


def child_environment(env):
    # Build tools need only the installed temporary identity, not the raw P12,
    # password, profile blob, or API private key inherited in their environment.
    return {key: value for key, value in env.items()
            if not key.startswith(('APPLE_', 'APP_STORE_CONNECT_'))}


def main():
    number = validate_context(os.environ)
    if sys.platform != 'darwin':
        raise ValueError('The signing job requires a GitHub-hosted Mac.')
    os.umask(0o077)
    root = pathlib.Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix='gnab-signing-', dir=root))
    keychain = work / 'signing.keychain-db'
    password = secrets.token_hex(32)
    installed = []
    original_keychains = []
    secret_values = [value for key, value in os.environ.items()
                     if key.startswith(('APPLE_', 'APP_STORE_CONNECT_')) and value]
    secret_values.append(password)

    def run(args, *, private=False):
        result = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors='replace', check=False,
                                env=child_environment(os.environ))
        if result.returncode:
            if not private:
                detail = result.stdout[-10000:]
                for value in secret_values:
                    detail = detail.replace(value, '[REDACTED]')
                print(detail, flush=True)
            raise ValueError(f'{pathlib.Path(str(args[0])).name} failed (exit {result.returncode}).')
        return result.stdout

    def decoded(name, filename):
        data = base64.b64decode(os.environ[name], validate=True)
        if not data or len(data) > 1024 * 1024:
            raise ValueError('Missing or oversized signing input.')
        path = work / filename
        path.write_bytes(data)
        return path

    try:
        p12 = decoded('APPLE_CERTIFICATE_P12_BASE64', 'identity.p12')
        profile_path = decoded('APPLE_PROVISIONING_PROFILE_BASE64', 'profile.mobileprovision')
        original_keychains = shlex.split(run(['security', 'list-keychains', '-d', 'user'], private=True))
        run(['security', 'create-keychain', '-p', password, keychain], private=True)
        run(['security', 'set-keychain-settings', '-lut', '7200', keychain], private=True)
        run(['security', 'unlock-keychain', '-p', password, keychain], private=True)
        run(['security', 'import', p12, '-P', os.environ['APPLE_CERTIFICATE_PASSWORD'],
             '-T', '/usr/bin/codesign', '-T', '/usr/bin/security', '-t', 'cert', '-f', 'pkcs12', '-k', keychain], private=True)
        run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain], private=True)
        run(['security', 'list-keychains', '-d', 'user', '-s', keychain, *original_keychains], private=True)
        identities = set(re.findall(r'\b[A-F0-9]{40}\b', run(['security', 'find-identity', '-v', '-p', 'codesigning', keychain], private=True)))
        profile = plistlib.loads(run(['security', 'cms', '-D', '-i', profile_path], private=True).encode())
        team = os.environ['APPLE_TEAM_ID']
        uuid, certificate = validate_profile(profile, team, identities, datetime.datetime.now(datetime.timezone.utc))
        for directory in [pathlib.Path.home() / 'Library/MobileDevice/Provisioning Profiles',
                          pathlib.Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles']:
            directory.mkdir(parents=True, exist_ok=True)
            target = directory / f'{uuid}.mobileprovision'
            if target.exists():
                if target.read_bytes() != profile_path.read_bytes():
                    raise ValueError('Refusing to overwrite an unrelated installed profile.')
            else:
                target.write_bytes(profile_path.read_bytes())
                installed.append(target)
        print('Validated GNAB-only distribution profile and installed temporary signing identity.', flush=True)
        archive = work / 'GnabCam.xcarchive'
        run(['xcodebuild', 'archive', '-project', 'NabcamIOS.xcodeproj', '-scheme', 'NabcamIOS',
             '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-archivePath', archive,
             f'DEVELOPMENT_TEAM={team}', 'CODE_SIGN_STYLE=Manual', f'CODE_SIGN_IDENTITY={certificate}',
             f'PROVISIONING_PROFILE_SPECIFIER={uuid}', f'CURRENT_PROJECT_VERSION={number}'])
        app = archive / 'Products/Applications/NabcamIOS.app'
        validate_archive(plistlib.loads((app / 'Info.plist').read_bytes()),
                         plistlib.loads((app / 'PrivacyInfo.xcprivacy').read_bytes()), number)
        if not (app / 'ThirdPartyNotices.txt').is_file():
            raise ValueError('Open-source notices are missing from the archive.')
        run(['codesign', '--verify', '--deep', '--strict', app])
        options = {'method': 'app-store-connect', 'destination': 'export', 'teamID': team,
                   'signingStyle': 'manual', 'signingCertificate': certificate,
                   'provisioningProfiles': {BUNDLE: uuid}, 'uploadSymbols': True,
                   'manageAppVersionAndBuildNumber': False}
        export_options = work / 'ExportOptions.plist'
        export_options.write_bytes(plistlib.dumps(options))
        run(['xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', work / 'export',
             '-exportOptionsPlist', export_options])
        ipas = list((work / 'export').glob('*.ipa'))
        if len(ipas) != 1:
            raise ValueError('Expected exactly one signed IPA.')
        digest = hashlib.sha256(ipas[0].read_bytes()).hexdigest()
        print(f'Signed device archive and IPA verified: build {number}; SHA256 {digest}', flush=True)
        if os.environ['GNAB_UPLOAD'] == 'true':
            key_id = os.environ['APP_STORE_CONNECT_API_KEY_ID']
            issuer = os.environ['APP_STORE_CONNECT_ISSUER_ID']
            if not re.fullmatch(r'[A-Z0-9]{10}', key_id) or not re.fullmatch(r'[A-Fa-f0-9-]{36}', issuer):
                raise ValueError('Invalid App Store Connect key identifiers.')
            key_path = decoded('APP_STORE_CONNECT_API_KEY_BASE64', f'AuthKey_{key_id}.p8')
            secret_values.append(key_path.read_text())
            options['destination'] = 'upload'
            export_options.write_bytes(plistlib.dumps(options))
            run(['xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', work / 'upload',
                 '-exportOptionsPlist', export_options, '-allowProvisioningUpdates',
                 '-authenticationKeyPath', key_path, '-authenticationKeyID', key_id,
                 '-authenticationKeyIssuerID', issuer])
            print(f'Build {number} uploaded to App Store Connect. Apple processing and tester availability must be checked separately.', flush=True)
        else:
            print('Signing check only; no upload requested. IPA will be removed with temporary files.', flush=True)
    finally:
        if original_keychains:
            subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *original_keychains],
                           capture_output=True, env=child_environment(os.environ))
        subprocess.run(['security', 'delete-keychain', str(keychain)], capture_output=True,
                       env=child_environment(os.environ))
        for target in installed:
            target.unlink(missing_ok=True)
        if work.parent == root and work.name.startswith('gnab-signing-'):
            shutil.rmtree(work)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error) if isinstance(error, ValueError) else 'Signing failed; private input details suppressed.', file=sys.stderr)
        sys.exit(1)
