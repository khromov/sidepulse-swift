---
name: release
description: Release a new SidePulse version. Bumps SidePulseConstants.version, runs the tests, builds and notarizes dist/SidePulse-VERSION.zip with scripts/release.sh, verifies it and writes the signed Sparkle update feed with scripts/appcast.sh. Only after the user confirms does it push the commit and publish the GitHub release with the zip and the feed. Use when the user asks to release, ship or publish a new version, cut a release, or bump the version for a release.
argument-hint: "[X.Y.Z | patch | minor | major]"
---

# Release a new SidePulse version

Everything up to step 6 is local and can be undone. Pushing and publishing (step 8) happen **only after the user explicitly confirms** in step 7. A confirmation earlier in the conversation does not count.

## 1. Preflight

Run these checks and stop with a clear message if one fails:

```sh
git status --short                    # must be clean
git fetch -q origin && git status -sb # on main, not behind origin/main
gh auth status                        # logged in with access to khromov/sidepulse-swift
xcrun notarytool history --keychain-profile "${SIDEPULSE_NOTARY_PROFILE:-notary}" >/dev/null
security find-identity -v -p codesigning | grep "Developer ID Application"
gh release list --limit 5             # the latest published version
swift package resolve                 # fetches Sparkle and its tools
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p   # must print SUPublicEDKey from Resources/Info.plist
```

- **Uncommitted changes:** ask the user what to do. Never commit their unrelated work as part of the release.
- **Notary profile:** notarytool keeps its profiles where the `security` CLI can't see them, so always check it with `notarytool history`.
- **Sparkle key:** installed apps accept only feeds signed with the key whose public half is `SUPublicEDKey` in `Resources/Info.plist`. If `generate_keys -p` fails or prints another key, stop. Never generate a new key and never change `SUPublicEDKey`: that strands every installed copy. The user has to import the backup with `generate_keys -f FILE`.

## 2. Pick the version

- The current version is `public static let version = "X.Y.Z"` in `Sources/SidePulseCore/Support/Paths.swift`.
- Use the version the user gave, or apply `patch`/`minor`/`major` to the current one. With no argument, suggest a patch bump and confirm it with the user.
- The format is plain `X.Y.Z` and the tag is `vX.Y.Z`. Refuse if the tag already exists:
  ```sh
  git ls-remote --tags origin "refs/tags/vX.Y.Z"
  gh release view vX.Y.Z   # must fail
  ```

## 3. Bump and test

- Edit only that one line in `Paths.swift`. Keep its exact shape, because `scripts/build-app.sh` reads the version with `sed`.
- The `"0.1.0"` strings in the tests are made-up ping replies; leave them alone.
- Run the full suite, including the integration tests:
  ```sh
  swift build && SIDEPULSE_INTEGRATION=1 swift test
  ```
  On failure, stop, revert the bump (`git checkout -- Sources/SidePulseCore/Support/Paths.swift`) and report.
- Commit, but don't push yet:
  ```sh
  git commit -am "Release X.Y.Z"
  ```

## 4. Build and notarize

Run `scripts/release.sh` in the background with a long timeout; notarization usually takes a few minutes. Don't run any other `swift build` or `swift test` in this checkout while it runs: every build config shares one output directory, and the script's arm64 check fails on swapped binaries.

The script:
- builds arm64-only binaries with `build-app.sh --distribution` (the only build that keeps the update feed URL);
- signs them with the Developer ID identity (hardened runtime, secure timestamp);
- notarizes the app, then staples and checks the ticket;
- writes `dist/SidePulse-X.Y.Z.zip`, deletes a stale `dist/appcast.xml` and prints the zip's SHA-256.

When it fails:
- **Status other than Accepted:** it prints Apple's log. Show it to the user and stop.
- **No final status** (for example `notarytool info` failed): it prints the submission id and the commands that finish the release by hand. Follow them **without rebuilding**, because the notarization ticket covers these exact binaries.

## 5. Verify the zip

Unpack a copy in the scratchpad and check it. Don't launch the app, and never run a binary from inside a hand-made `.app` bundle.

```sh
Z=dist/SidePulse-X.Y.Z.zip; X=<scratchpad>/release-check
rm -rf "$X" && mkdir -p "$X" && ditto -x -k "$Z" "$X"
xcrun stapler validate "$X/SidePulse.app"
spctl -a -vv -t exec "$X/SidePulse.app"                # accepted, source=Notarized Developer ID
codesign --verify --deep --strict "$X/SidePulse.app"
lipo -archs "$X/SidePulse.app/Contents/MacOS/SidePulse" # arm64
lipo -archs "$X/SidePulse.app/Contents/Helpers/sidepulse"
lipo -archs "$X/SidePulse.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
plutil -extract SUFeedURL raw -o - "$X/SidePulse.app/Contents/Info.plist"   # .../releases/latest/download/appcast.xml
"$X/SidePulse.app/Contents/Helpers/sidepulse" version   # sidepulse X.Y.Z
unzip -l "$Z" | grep -c '/\._'                          # 0
shasum -a 256 "$Z"
```

## 6. Draft the release notes and the update feed

Write two files in the scratchpad. Summarize the user-visible changes since the previous tag (`git log --oneline vPREV..HEAD`), and leave out refactors and test-only changes.

`update-notes.md` is what the in-app update window shows, so it holds only the summary and the changes:

```markdown
<One or two sentences on what this version brings.>

### Changes
- <user-visible change>
```

`release-notes.md` is the GitHub release body: the same text, followed by:

```markdown
**Requirements:** macOS 26 or later on Apple silicon. On an Intel Mac, build from source with `scripts/install.sh`.

### Install
1. If you use the official Python version, uninstall it first: `sidepulse agent-monitor uninstall all`.
2. Download `SidePulse-X.Y.Z.zip`, unzip it, and move `SidePulse.app` to `~/Applications` or `/Applications` **before** opening it.
3. On a first install, open SidePulse and install the agent hooks from **Settings › Hooks**.

**Upgrading:** SidePulse updates itself: use **Check for Updates...** in the menu, or wait for the daily check. Version 0.1.0 has no updater, so from 0.1.0 quit SidePulse and replace the app by hand once.

The app is signed with a Developer ID certificate, and notarized and stapled by Apple.

SHA-256 of `SidePulse-X.Y.Z.zip`: `<sha256>`
```

Then write the feed:

```sh
scripts/appcast.sh dist/SidePulse-X.Y.Z.zip <scratchpad>/update-notes.md
```

It checks that the zip's `SUPublicEDKey` matches the keychain key and verifies the signature it wrote. macOS may ask the user to let `generate_appcast` use the key; tell them to click **Always Allow**. Check `dist/appcast.xml`:
- `<sparkle:version>X.Y.Z</sparkle:version>`;
- the enclosure URL is `https://github.com/khromov/sidepulse-swift/releases/download/vX.Y.Z/SidePulse-X.Y.Z.zip`;
- `<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>`;
- the release notes are in `<description sparkle:format="markdown">`.

## 7. Ask before publishing

Show the user:
- the version and the commit (`git log --oneline -1`);
- the zip's size and SHA-256;
- the step 5 results;
- the full release notes, and the update notes the in-app window will show;
- exactly what will happen next: push `main` to origin, then create the public release `vX.Y.Z` with the zip and `appcast.xml` attached. From that moment, every installed SidePulse that has the updater (anything after 0.1.0) is offered this version.

Then ask with AskUserQuestion. Offer to publish, to edit the notes first, or to stop here. The repository is public, so a published release is visible to everyone at once.

If the user stops here, leave the local commit and the zip as they are. Tell them the commit is not pushed, and that `git reset --soft HEAD~1` undoes the bump if they want.

## 8. Publish (only after confirmation)

```sh
git push origin main
gh release create vX.Y.Z dist/SidePulse-X.Y.Z.zip dist/appcast.xml \
  --target "$(git rev-parse HEAD)" --title "SidePulse X.Y.Z" \
  --notes-file <scratchpad>/release-notes.md --latest
```

Then verify:
- Download the asset back and compare its SHA-256 with the local zip:
  ```sh
  gh release download vX.Y.Z -D <scratchpad>/gh-dl
  ```
- Check that the tag points at the release commit:
  ```sh
  git fetch -q --tags origin && git rev-parse --short "vX.Y.Z^{commit}"
  ```
- Check that the feed installed apps read is this release's, and that its download works:
  ```sh
  curl -fsSL https://github.com/khromov/sidepulse-swift/releases/latest/download/appcast.xml | grep '<sparkle:version>'   # X.Y.Z
  curl -fsSIL -o /dev/null -w '%{http_code}\n' https://github.com/khromov/sidepulse-swift/releases/download/vX.Y.Z/SidePulse-X.Y.Z.zip   # 200
  ```
- Report the release URL.

Finally, offer to run `scripts/install.sh`, so the app installed on this Mac matches the release. An ad-hoc install makes macOS ask for removable-volume access again.
