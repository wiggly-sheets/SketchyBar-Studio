# Release Checklist

1. Update `CHANGELOG.md`. Add a section for the version, because the release uses that section as the release notes.
2. Confirm the `vX.Y.Z` version/tag name.
3. Run local checks:

   ```bash
   make build
   make test
   make app-universal
   lipo -info dist/SketchyBarStudio.app/Contents/MacOS/SketchyBarStudio
   codesign --verify --deep --strict dist/SketchyBarStudio.app
   ```

4. Manually open `dist/SketchyBarStudio.app`.
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
   - build the universal app
   - create a DMG with `create-dmg@8.1.0`
   - write the checksum sidecar next to the DMG
   - publish the release with the notes of the changelog section of that version
9. Download the release DMG and smoke test it.
