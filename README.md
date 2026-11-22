# JPortal for iOS

A native SwiftUI port of [JPortal for Android](https://github.com/codelif/jportal-android), the JIIT web portal as an app.

Unofficial. Not affiliated with or endorsed by JIIT.

## What's in it

The same features as the Android app:

- **Attendance:** every subject counted class by class, how many classes you can skip or need to attend, recent-class dots, the wavy ring that flattens when you drop below your goal
- **Subject pages:** a per-day attendance calendar, a trend chart, L/T/P components with their teachers, marks and grade
- **Academics:** SGPA, CGPA, a credits bar, a CGPA what-if chart (drag a future semester), and an SGPA/CGPA calculator; grade cards per semester; marks read out of the portal's marks PDF
- **Exams:** a date sheet with rooms, seats, clashes, countdowns and free days, "Add to calendar", and optional automatic sync to a calendar you pick (EventKit)
- **Subjects:** search, filters, subject choices and MOOC status
- **Planner:** your weekly timetable from [jiit-planner-cdn](https://github.com/codelif/jiit-planner-cdn), with the batch picked up from the portal and electives pre-filled from your registration
- **Me:** profile, fees, bank details, hostel, and teacher feedback with a review step before anything is sent
- Works offline from the on-device cache, light and dark themes plus pure black, and a **Demo** mode with a made-up student

## Building

Needs Xcode 16 or newer (the project uses synchronized folders). Built and tested with Xcode 27.2 and the iOS 27 simulator. The deployment target is iOS 17.

```sh
open JPortal.xcodeproj
```

Pick a simulator and run. To run on a real iPhone, set your team under Signing & Capabilities.

Debug builds (Xcode's Run) install as **JPortal Dev** with the bundle ID `com.jportal.ios.dev`. Release builds (Product → Archive, which is what goes to TestFlight) are **JPortal** with `com.jportal.ios`. So a build from Xcode and one from TestFlight can sit side by side on the same phone. If you fork this, change both IDs to your own. Raise `CURRENT_PROJECT_VERSION` (the build number) for every upload.

From the command line:

```sh
xcodebuild -project JPortal.xcodeproj -scheme JPortal -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## How it's put together

| Folder | What's there |
|---|---|
| `JPortal/Portal` | The portal client, a port of [ktjiit](https://github.com/codelif/ktjiit): the daily-rotating AES `LocalName` header, the `{status, response}` envelope, server-clock skew correction, retries, every API call, and the marks-PDF table parser (built on CoreGraphics' `CGPDFScanner`) |
| `JPortal/Data` | Cached stores (paint from disk, refresh over the network, keep old data on failure), the session sealed in the Keychain (this device only), prefs, the planner's CBOR+gzip timetable decoder, calendar sync, demo data |
| `JPortal/Domain` | Attendance math, GPA projection, the exam plan, the planner's day plan, and text helpers |
| `JPortal/UI` | SwiftUI screens and components |
| `JPortalTests` | Unit tests using ktjiit's own fixtures: the cipher test vectors, all 14 sample marks PDFs, captured portal responses, and the live timetable file |

### Sign-in

Same approach as the Android app: Google's own sign-in button is served from the portal's origin inside a `WKWebView` that identifies as Safari, so the portal's Google client ID accepts it. The Google ID token is exchanged for a portal session. Two fallbacks exist: signing in on the portal's own page (the app reads its login response), and pasting a session code from another device running JPortal. Session codes are compatible with the Android app's.

## Status

- Verified with a real JIIT account, on an iPhone and in the simulator: Google sign-in, loading real data, and every screen. Testing with real data turned up several bugs in logic ported from the Android app (how the current semester and course length are picked, the hostel error, title casing), which are fixed here and covered by `JPortalTests/RealDataFixesTests.swift`.
- Verified in the simulator: every screen in Demo mode, in light and dark.
- Silent re-sign-in (when the 2-hour token expires) differs from Android. One Tap runs in an iframe where WebKit hides Google's cookies, so it can't work on iOS. Instead a hidden web view opens Google's OAuth endpoint as the top-level page with `prompt=none`. Google's cookies are first-party there, and Google redirects straight back to the portal's origin (a redirect the portal's client ID accepts) with a fresh ID token, which goes through the same token exchange. The renewed session is only used if it's the same student. If Google needs you (signed out, or several accounts and no hint yet), the app shows a "Sign in again" sheet over your cached data. See `JPortal/Portal/GoogleSilentAuth.swift`. This has been verified in the simulator with an expired real session, but **not yet on a physical iPhone**.
- Release builds for a device compile cleanly. TestFlight setup is described in [TESTFLIGHT.md](TESTFLIGHT.md).
- Left out from the Android version: the GitHub update checker (that's the App Store's job on iOS), the wallpaper colour palette and the app-icon switcher.

## License

GPL-3.0-only, same as JPortal for Android and ktjiit, which this port is derived from. See [LICENSE](LICENSE). The frog artwork is from JPortal for Android.

Big ❤️ Energy lives on in [Yash Malik](https://github.com/codeblech).
