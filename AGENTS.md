# NABCAM IRL iOS working agreement

- Canonical iOS checkout: `C:\Users\jester\Documents\ChatGPT\nabcam-ios`.
- Android lives separately in `C:\Users\jester\Documents\ChatGPT\gnab-gcam`; do not change Android as part of iOS work.
- The original untracked Android-side `ios` folder is the starter snapshot, not the active iOS checkout.
- Native SwiftUI UI, HaishinKit camera/encoder/RTMP/SRT integration, and pure Swift core tests. Follow the pinned dependency APIs, not examples from a different version.
- Generate the Xcode project from `ios/project.yml` with XcodeGen on macOS. Run `swift test` in `ios/Core` and the manual iOS checks workflow. No Xcode build can run on this Windows host.
- Never claim SRTLA bonding, multiple cellular paths, background capture, USB support, or phone-tested streaming based only on compilation. Unsupported features must be visibly unavailable, not simulated.
- Never log destination URLs, stream keys, access tokens or signing secrets. Store persistent connection credentials in Keychain when that feature is introduced.
- Apple provisioning and distribution credentials must remain outside Git and use repository secrets. Do not copy another app's bundle ID, product IDs, ad IDs or provisioning profile.
- Keep permission declarations and privacy manifests aligned with actual code and dependencies. No advertising or tracking SDK is included in the initial port.
- TestFlight publication is the requested delivery goal. Public App Store release requires separate approval.
