# Release Checklist

1. Update `CHANGELOG.md`. Add a section for the version, because the release uses that section as the release notes.
2. Confirm the `vX.Y.Z` version/tag name.
3. Run local checks:

   ```bash
   make build
   make test
   make app
   make verify
   lipo -archs dist/arm64/SketchyBarStudio.app/Contents/MacOS/SketchyBarStudio
   lipo -archs dist/x86_64/SketchyBarStudio.app/Contents/MacOS/SketchyBarStudio
   codesign --verify --deep --strict dist/arm64/SketchyBarStudio.app
   codesign --verify --deep --strict dist/x86_64/SketchyBarStudio.app
   ```

4. Manually open the bundle of the host Mac, `dist/arm64/` on Apple silicon or
   `dist/x86_64/` on Intel.
5. Test with:
   - Lua config
   - shell/sketchybarrc config
   - color picker
   - font picker
   - activation toggle
   - Save & Apply
   - backup mirror under `backups/`
6. Commit release changes.
7. Build the artifacts, create the tag and push it:

   ```bash
   make release VERSION=X.Y.Z
   git push origin master
   git push origin vX.Y.Z
   ```

8. GitHub Actions `Release` workflow will automatically:
   - build the Apple silicon and the Intel app
   - create one DMG per architecture with `create-dmg@8.1.0`
   - write `release/checksums.txt` with one line per DMG and verify it
   - upload `SketchyBarStudio-<version>-arm64.dmg`, `SketchyBarStudio-<version>-x86_64.dmg` and `checksums.txt`
   - publish the release with the download, Homebrew and notes blocks, the changelog section of that version and both SHA-256 digests
9. Download the release DMG and smoke test it.

## Daemon-dependent tests

Two test suites require the SketchyBar daemon to be running. They are skipped (not failed) when the daemon is absent, so they never cause a build failure on CI or headless machines. They pass when the daemon is present. The two tests are:

- **Differential test** (`LiveBarPushTests.testThePushAndTheRestorePutTheLiveBarBack`): compares item rectangles from the vendored renderer against the `bounding_rects` reported by `sketchybar --query <item>` on the live daemon. It reads layout data only — it never calls `--set` or modifies the bar.
- **Isolation test** (`PreviewIsolationTests.testTheScriptsOfThePreviewCannotChangeTheLiveBar`): runs item scripts inside the preview and verifies that they cannot modify the live bar, by comparing the bar state before and after the preview cycle. It requires a live daemon to query the initial state.

Both tests throw `XCTSkip` with the message "the daemon of SketchyBar is not running" when the daemon does not answer. A green build without a running daemon is expected and correct.
