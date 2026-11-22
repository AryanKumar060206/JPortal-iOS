# Getting JPortal onto TestFlight

The project is ready to upload: bundle ID `com.jportal.ios`, version 1.0.0 (build 1), iPhone only, with the app icon, the privacy manifest and the export-compliance answer all included. Everything left needs your Apple account, so you do these steps yourself.

## 1. Join the Apple Developer Program (one time)

Right now your Xcode team is a free **Personal Team**, and TestFlight needs the paid membership.

- Enrol at <https://developer.apple.com/programs/enroll/>, or in the **Apple Developer** app on your iPhone. Choose **Individual**.
- It costs US$99 a year, or whatever price it shows you in your currency.
- Apple usually approves within 48 hours and may ask you to verify your ID.

## 2. Point the project at your new team

Once you're approved, open Xcode → **Settings → Accounts**. A second team with your name, marked "Individual", appears under your Apple ID.

Then open the project, select the **JPortal** target, go to **Signing & Capabilities**, and pick that team. Do the same for the **JPortalTests** target. (Or send me the new Team ID, shown at developer.apple.com → Account → Membership details, and I'll set it.)

## 3. Create the app in App Store Connect

Go to <https://appstoreconnect.apple.com>, open **Apps**, click **+**, then **New App**:

| Field | What to enter |
|---|---|
| Platform | iOS |
| Name | `JPortal`. If it's taken, try a variant. This is only the store listing name; the name on the home screen stays JPortal |
| Primary language | English |
| Bundle ID | `com.jportal.ios`. If it isn't in the list yet, add it under developer.apple.com → Certificates, IDs & Profiles → Identifiers, or do step 4 first, since archiving registers it |
| SKU | anything, e.g. `jportal-ios` |

## 4. Upload a build

1. In Xcode's toolbar, set the run destination to **Any iOS Device (arm64)**.
2. Choose **Product → Archive**. The Organizer opens when it's done.
3. Click **Distribute App**, choose **TestFlight & App Store**, then **Distribute**. Xcode handles the signing.
4. Apple processes the build, which takes about 5 to 30 minutes, and emails you when it's ready.

## 5. Install it yourself (internal testing)

In App Store Connect, open the app → **TestFlight** → **Internal Testing**, click **+**, and add yourself. Internal testing doesn't need a review. Install the **TestFlight** app on your iPhone and JPortal shows up there.

## 6. Share it with friends (external testing)

1. Under **TestFlight → External Testing**, click **+**, create a group (e.g. "Friends"), and add the build.
2. Fill in **Test Information**:
   - **Beta App Description**: "An unofficial, student-made client for the JIIT web portal: attendance, marks, grades, exams, timetable and an SGPA/CGPA calculator."
   - **Feedback email**: your email.
3. Fill in **Beta App Review Information**:
   - Untick **Sign-in required**, since reviewers don't have JIIT accounts.
   - Add this note: "Tap **Demo** on the sign-in screen to explore the app with sample data. Real sign-in needs a JIIT student account."
4. Submit for review. The first build is usually approved within a day, and later builds are often approved automatically.
5. Turn on the **Public Link** and send it to friends, or invite them by email. Each person installs the TestFlight app, opens the link and taps **Install**.

## Every update after that

- **Raise the build number** for each upload. Either leave **Manage Version and Build Number** ticked in the Distribute dialog, or bump `CURRENT_PROJECT_VERSION` yourself. Change the version (1.0.0 → 1.1.0) when there's something new to tell people about.
- **Builds expire 90 days** after upload, so upload a new one before then to keep testers going.

## Good to know

- **Two copies on one phone:** a build from Xcode's Run button installs as **JPortal Dev** (`com.jportal.ios.dev`), and the TestFlight one is **JPortal** (`com.jportal.ios`), so both can be installed at once.
- **The old copy:** the copy installed earlier under `com.example.jportal` is a separate app. Delete it once the new one works, and sign in again in the new one.
- **Encryption question:** App Store Connect won't ask about it. The app only uses HTTPS and the portal's AES login header, which counts as exempt, and that answer is already built into the app.
