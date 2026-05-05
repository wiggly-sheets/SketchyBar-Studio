# Contributing

Thanks for helping make SketchyBar Studio better.

## Development

Requirements:

- macOS 14 or newer
- Xcode with Swift 5.9 or newer
- SketchyBar installed if testing live reload/apply behavior

Build:

```bash
swift build
```

Run:

```bash
./script/build_and_run.sh
```

## Pull Requests

Please include:

- what changed
- how you tested it
- config shape used for testing, if relevant
- screenshots for UI changes when possible

Keep changes focused. Parser behavior should be conservative: preserve user files unless the app can make a narrow, predictable edit.

## Parser Changes

When adding parser support, prefer:

- preserving original file layout
- touching only the specific value span being edited
- writing a backup before changes
- adding support for both active and commented loader lines when relevant

Avoid broad rewrites of config files.
