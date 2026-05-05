# Release Checklist

1. Update `CHANGELOG.md`.
2. Confirm version/tag name.
3. Run:

   ```bash
   swift build
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
6. Create tag:

   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

7. Download GitHub Actions release artifact and smoke test it.
