# Release Checklist

1. Update `CHANGELOG.md`.
2. Confirm version/tag name, for example `v1.0.1`.
3. Run local checks:

   ```bash
   swift build
   swift test
   ./script/build_and_run.sh --universal-package
   lipo -info dist/SketchyBarStudio.app/Contents/MacOS/SketchyBarStudio
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
7. Create and push tag:

   ```bash
   git tag -a v1.0.1 -m "SketchyBar Studio 1.0.1"
   git push origin master
   git push origin v1.0.1
   ```

8. GitHub Actions `Release` workflow will automatically:
   - build the universal app
   - create a DMG with `create-dmg@8.1.0`
   - upload the DMG and checksum
   - create or update the GitHub release
9. Download the release DMG and smoke test it.
