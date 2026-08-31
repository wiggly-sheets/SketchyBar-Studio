# Security Policy

SketchyBar Studio edits local configuration files and may run `sketchybar --reload`.

## Supported Versions

Security fixes target the latest release and the current `master` branch.

## Reporting a Vulnerability

Open a private security advisory on GitHub if available, or contact the maintainer directly.

Please include:

- affected version or commit
- macOS version
- description of the issue
- reproduction steps
- whether arbitrary command execution or file overwrite is involved

## Local File Safety

The app should:

- write mirrored copies under the selected config's `backups/` folder before modifying configs
- avoid destructive rewrites
- preserve unrelated file content
- ask the system to run only expected local tools, such as `sketchybar --reload`

Report any behavior that writes outside the selected SketchyBar config folder unexpectedly.
