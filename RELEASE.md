# LeVoice release runbook

This is the step-by-step playbook for cutting a new build of LeVoice. It
covers two paths:

1. **Test build** — unsigned, for your own Mac or a friend who's willing to
   `xattr -cr` to bypass Gatekeeper. No Apple Developer account needed.
2. **Distribution build** — signed with a Developer ID certificate, notarized
   by Apple, stapled, and ready to ship via DMG to anyone. Requires the
   `$99/year` Apple Developer Program enrollment first (see
   `levoice-commercial-prep.md`).

The first build of any new version uses the same procedure for both paths up
through "Build the .app". Signing and notarization diverge after that.

---

## Prerequisites (one-time)

- macOS 14.0+ (Apple Silicon recommended).
- Xcode 16 (matches `project.yml`'s `xcodeVersion: "16.0"`).
- XcodeGen: `brew install xcodegen`.
- For distribution builds only:
  - Apple Developer Program enrollment (active).
  - A Developer ID Application certificate installed in your login Keychain.
    Verify with: `security find-identity -v -p codesigning` — you should see
    a line like `Developer ID Application: Arya Teja Rudraraju (XXXXXXXXXX)`.
  - notarytool credentials stored once per machine:

    ```bash
    xcrun notarytool store-credentials notarytool \
      --apple-id YOUR_APPLE_ID \
      --team-id YOUR_TEAM_ID \
      --password YOUR_APP_SPECIFIC_PASSWORD
    ```

    The app-specific password is generated at appleid.apple.com under
    Sign-In and Security → App-Specific Passwords. Anything that says
    "notarytool" is fine — the keychain profile name is referenced
    elsewhere in this script.

---

## Cut a release

Replace `0.0.X` and `BUILD_N` with the new version and build number
throughout. The procedure assumes you're running from
`$REPO_ROOT/`.

### 1. Decide the version

Follow Semantic Versioning, as documented at the top of `CHANGELOG.md`:

- Patch (`0.0.X`) for bug fixes only.
- Minor (`0.X.0`) for new features.
- Major (`X.0.0`) for anything that breaks user expectations.

If you're unsure, default to a patch bump — it's easy to upgrade to minor
later, harder to walk back a premature minor.

### 2. Update version strings

Two files carry the version:

- `pepperbox/LeVoice/Info.plist` — `CFBundleShortVersionString` (the
  human-facing version, e.g. `0.0.2`) and `CFBundleVersion` (a monotonically
  increasing build number; bump by 1 every time you cut a build, even
  rebuilds of the same version).

That's it. There is no separate version file. The build script
(`scripts/build-dmg.sh`) reads from `Info.plist` automatically.

### 3. Update CHANGELOG.md

Open `pepperbox/CHANGELOG.md`. Move work from `[Unreleased]` into a new
heading right under it:

```markdown
## [0.0.2] (build 2) — YYYY-MM-DD

One-line summary of what this build is about.

### Added
- ...

### Changed
- ...

### Fixed
- ...

### Known issues
- ...
```

Sections without entries can be omitted. **Always include a Known issues
section** if the build has any — even for test builds. This is the user's
only window into what's broken.

If anything in the release affects security posture (new permissions, new
network calls, new on-disk storage of user data), add a `### Security notes`
section.

### 4. Regenerate the Xcode project

Only needed if you changed `project.yml`. Skip otherwise.

```bash
cd "$REPO_ROOT"
xcodegen generate
```

Quit Xcode first if it's open, or it'll hold file handles and the regen
will be incomplete.

### 5. Build the .app

Two options.

#### Option A: Test build (unsigned, for your own Mac or trusted friends)

In Xcode: **Product → Archive → Distribute App → Copy App → macOS** → save
somewhere. Drag the resulting `LeVoice.app` to `/Applications`. Done.

To run on a different Mac without Gatekeeper friction:

```bash
xattr -cr /Applications/LeVoice.app
```

(Strips the quarantine flag. The recipient still gets the "unidentified
developer" warning the first time, but they can right-click → Open.)

This is the path you should use until your Apple Developer enrollment
finishes. Do **not** post unsigned builds publicly.

#### Option B: Distribution build (signed, notarized, DMG)

```bash
cd "$REPO_ROOT"
export LEVOICE_SIGNING_IDENTITY="Developer ID Application: Arya Teja Rudraraju (XXXXXXXXXX)"
export LEVOICE_TEAM_ID="XXXXXXXXXX"
./scripts/build-dmg.sh
```

The script will:

1. Clean `build/` and recreate the staging directory.
2. Run `xcodebuild` in Release configuration with manual signing.
3. Re-sign every binary, framework, and XPC bundle inside the .app with
   `--timestamp --options runtime` (Hardened Runtime is required for
   notarization).
4. Verify the signature with `codesign --verify --deep --strict`.
5. Stage the .app + an `/Applications` symlink in a folder.
6. Create a UDZO-compressed DMG.
7. Sign the DMG.
8. Submit to Apple's notary service via `notarytool submit --wait`. This
   takes 5–15 minutes the first time, usually under 5 thereafter.
9. If notarization is **Accepted**, staple the ticket onto the DMG so it
   verifies offline.
10. Generate a Sparkle ed25519 signature for the DMG (printed to stdout —
    you'll paste this into `appcast.xml` later).

Final output: `build/LeVoice.dmg`.

If notarization fails, the script prints the notarytool output and
continues without stapling. Look for:

- `status: Invalid` → some binary wasn't signed correctly. Re-run the
  script; the most common cause is a new dependency that doesn't have
  the Hardened Runtime entitlement.
- `Status: In Progress` and the script timed out → wait, then run
  `xcrun notarytool history --keychain-profile notarytool` to find your
  submission and `xcrun notarytool log <UUID> --keychain-profile notarytool`
  to see what's wrong.
- `Status: Accepted` but stapling failed → run
  `xcrun stapler staple build/LeVoice.dmg` manually.

### 6. Verify the build

```bash
spctl -a -t exec -vv build/LeVoice.dmg     # should say "accepted source=Notarized Developer ID"
xcrun stapler validate build/LeVoice.dmg   # should say "validates"
```

For a sanity check, drag the .app out of the DMG to `/Applications` on a
**different Mac** (or wipe Gatekeeper state on yours with
`xattr -cr /Applications/LeVoice.app`). It should open without any
"Apple could not verify" warning.

### 7. Update appcast.xml (Sparkle auto-update feed)

Once the LeSearch AI release host is configured (see
`levoice-commercial-prep.md` step 5), every release needs an entry added to
`appcast.xml`. Open it and prepend a new `<item>` inside `<channel>`:

```xml
<item>
  <title>0.0.2</title>
  <link>https://levoice.lesearch.ai/releases/0.0.2/</link>
  <sparkle:version>2</sparkle:version>
  <sparkle:shortVersionString>0.0.2</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <pubDate>YYYY-MM-DDTHH:MM:SS+0000</pubDate>
  <description><![CDATA[
    <ul>
      <li>What's new in this release (mirrors CHANGELOG.md).</li>
    </ul>
  ]]></description>
  <enclosure
    url="https://levoice.lesearch.ai/releases/0.0.2/LeVoice.dmg"
    sparkle:edSignature="THE_SIGNATURE_BUILD_DMG_SH_PRINTED"
    length="DMG_SIZE_IN_BYTES"
    type="application/octet-stream"/>
</item>
```

`sparkle:version` matches `CFBundleVersion`. `sparkle:shortVersionString`
matches `CFBundleShortVersionString`. The signature was printed at the end
of the build script run.

Do **not** edit the appcast for a test build — Sparkle is currently
disabled in `Info.plist` (`SUFeedURL` removed) until the release host is
up.

### 8. Tag and publish

```bash
git add pepperbox/LeVoice/Info.plist pepperbox/CHANGELOG.md pepperbox/appcast.xml
git commit -m "Release 0.0.2 (build 2)"
git tag v0.0.2
git push origin main --tags
```

Upload the DMG to your release host (GitHub Releases, S3, Cloudflare R2,
whatever) at the URL referenced in the appcast.

### 9. Post-release sanity check

- Trigger an in-app **Check for Updates** from the menu (once Sparkle is
  re-enabled). It should detect the new version and prompt to install.
- Verify the previous-version → new-version upgrade path works:
  install the previous DMG, launch, accept the Sparkle prompt, confirm the
  app relaunches at the new version.

---

## When something goes wrong

### Notarization rejected with "The signature does not include a secure timestamp"

Some binary in the bundle was signed without `--timestamp`. The
`build-dmg.sh` script re-signs everything; if a new dependency landed,
make sure its embedded binaries are picked up by the `find` glob in steps
3a–3c of the script. Add to the find pattern if needed.

### Notarization rejected with "Hardened Runtime is not enabled"

Same fix — missing `--options runtime` on a binary. Same pattern in the
script.

### Build is huge

The Whisper and Qwen models are NOT bundled — they're downloaded on first
launch. If your DMG suddenly grew by 500MB+, check for an accidentally
checked-in model file under `LeVoice/Resources/Models/`.

### Sparkle update doesn't trigger

Three things to check:

1. `SUFeedURL` is set in `Info.plist` (currently removed; re-add when
   the release host exists).
2. `SUPublicEDKey` is set in `Info.plist` and matches the key used to
   sign the appcast entry.
3. The new appcast entry's `sparkle:version` is **higher** than the
   currently-installed `CFBundleVersion`. Sparkle uses the build number,
   not the marketing version, for the comparison.

### "Killed: 9" when launching after a fresh DMG install

The Hardened Runtime is rejecting something in the bundle. Look at
Console.app filtered to LeVoice — usually a missing
`com.apple.security.cs.disable-library-validation` entitlement on a third-
party framework that does runtime code generation. Most common with
LLM.swift's llama.cpp dylibs. The `LeVoice.entitlements` file is the right
place to add the necessary `com.apple.security.cs.*` keys.

---

## Quick reference

| What           | Where                                              |
|----------------|----------------------------------------------------|
| Version        | `pepperbox/LeVoice/Info.plist`                     |
| Changelog      | `pepperbox/CHANGELOG.md`                           |
| Project gen    | `pepperbox/project.yml` → `xcodegen generate`      |
| Build script   | `pepperbox/scripts/build-dmg.sh`                   |
| Appcast        | `pepperbox/appcast.xml` (currently disabled)       |
| Entitlements   | `pepperbox/LeVoice/LeVoice.entitlements`           |
| Signing TODO   | `LEVOICE_SIGNING_IDENTITY` + `LEVOICE_TEAM_ID` env |

For the bigger commercial-distribution picture (Apple Developer enrollment,
Sparkle hosting, payment channels), see `levoice-commercial-prep.md`.
