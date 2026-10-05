"""Validate a local GNAB profile and prepare export options; never import keys."""
import datetime
import hashlib
import os
import pathlib
import plistlib
import re
import subprocess
import sys

BUNDLE = "com.gnabcamirl.app"


def validate_profile(profile, team, identities, now):
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Use the Apple team ID for this app.")
    entitlements = profile.get("Entitlements", {})
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    if profile.get("TeamIdentifier") != [team] or entitlements.get("com.apple.developer.team-identifier") != team:
        raise ValueError("The provisioning profile belongs to a different team.")
    if not any(entitlements.get("application-identifier") == f"{prefix}.{BUNDLE}" for prefix in prefixes):
        raise ValueError("An explicit GNAB CAM IRL provisioning profile is required.")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime) or expires.replace(tzinfo=datetime.timezone.utc) <= now:
        raise ValueError("The provisioning profile has expired or has no valid expiration.")
    if entitlements.get("get-task-allow") is not False or "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices"):
        raise ValueError("Use an App Store distribution profile, not development, ad hoc, or enterprise.")
    uuid = profile.get("UUID", "")
    if not re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", uuid):
        raise ValueError("The profile UUID is invalid.")
    certificates = profile.get("DeveloperCertificates", [])
    candidates = [hashlib.sha1(cert).hexdigest().upper() for cert in certificates if isinstance(cert, bytes)]
    matching = next((fingerprint for fingerprint in candidates if fingerprint in identities), None)
    if matching is None:
        raise ValueError("No valid local signing identity matches this profile. Install your distribution certificate and private key on the approved Mac first.")
    return uuid, matching


def main():
    if os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS") or sys.platform != "darwin":
        raise ValueError("Signing is permitted only on your approved local Mac, never in CI.")
    if len(sys.argv) != 3:
        raise ValueError("Run archive-local.sh with GNAB_TEAM_ID, GNAB_PROFILE_PATH and GNAB_BUILD_NUMBER set.")
    profile_path = pathlib.Path(os.environ["GNAB_PROFILE_PATH"]).expanduser().resolve(strict=True)
    repository = pathlib.Path(__file__).resolve().parents[2]
    if profile_path.is_relative_to(repository):
        raise ValueError("Keep the provisioning profile outside this Git checkout.")
    decoded = subprocess.run(["security", "cms", "-D", "-i", str(profile_path)], capture_output=True, check=True)
    profile = plistlib.loads(decoded.stdout)
    available = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True, check=True)
    identities = set(re.findall(r"\b[A-F0-9]{40}\b", available.stdout))
    team = os.environ["GNAB_TEAM_ID"]
    uuid, certificate = validate_profile(profile, team, identities, datetime.datetime.now(datetime.timezone.utc))
    options = {
        "method": "app-store-connect", "destination": "export", "teamID": team,
        "signingStyle": "manual", "signingCertificate": certificate,
        "provisioningProfiles": {BUNDLE: uuid}, "uploadSymbols": True,
        "manageAppVersionAndBuildNumber": False,
    }
    pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(options))
    # Identifiers only, consumed locally by the shell; never certificates/passwords.
    pathlib.Path(sys.argv[2]).write_text(uuid + "\n" + certificate + "\n", encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        # External command stderr can contain account information: never echo it.
        print(str(error) if isinstance(error, ValueError) else "Local signing preflight failed. Check the profile path, team ID, and installed signing identity.", file=sys.stderr)
        sys.exit(1)
