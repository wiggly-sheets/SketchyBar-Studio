# Plugin Store

The Store browses a curated catalogue of SketchyBar plugins and whole setups,
fetches an entry only when the user asks for it, and installs it safely:

- a plugin becomes one file under `plugins/` in the config folder, plus one
  loader line;
- a setup becomes a new profile, next to the config the user already has.

The catalogue is embedded in the app in
`Sources/SketchyBarStudio/Models/StoreCatalogue.swift`. There is no catalogue
server and no update file: an entry ships with the app.

## Catalogue format

One `StoreEntry` describes one installable thing.

| Field | Meaning |
| --- | --- |
| `id` | Stable identifier. Must be unique. |
| `kind` | `.plugin` (one file) or `.setup` (whole tree). |
| `name` | Name shown to the user. |
| `author` | The repository owner, as credited by the repository. |
| `repository` | `owner/repo`, exactly one slash. |
| `path` | File path for a plugin. Subdirectory for a setup (`""` is the whole repository). |
| `ref` | A tag or a commit. Never a branch. |
| `licence` | `StoreLicence`, or nil when no licence was verified. |
| `licenceURL` | Link to the repository `LICENSE` at the pinned ref. |
| `summary` | One or two sentences on what it shows and what it needs. |
| `tags` | Free-form search labels. |

A plugin entry installs **one file**. A plugin that only works with helpers,
themes or a binary from its own repository does not belong in the catalogue as
a single-file plugin; list the whole repository as a setup, or leave it out.

## Adding an entry

Do this for every entry, and do it again when the pin changes:

1. Open the repository and read its files. Decide whether it is a plugin or a
   setup, and whether it really runs on its own.
2. Fetch `LICENSE` at the exact tag or commit, not at the default branch.
   Confirm the licence is in the allowed set below.
3. Read the header of the file (or the entrypoint of the setup). If it names a
   licence, it must match `LICENSE`. If it names none, the repository
   `LICENSE` governs.
4. Confirm the entry path answers at that ref:
   `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>` must return
   the file, not a 404.
5. Use a tag or a commit SHA as `ref`. Never `main`, `master`, `HEAD` or a
   release channel name. Branches move, so a pinned entry would start
   installing different code without review.
6. Write the `licenceURL` as
   `https://github.com/<owner>/<repo>/blob/<ref>/LICENSE`.
7. Run `swift test --filter StoreTests`. The catalogue test enforces the
   licence set, the pinned ref, the repository shape, the path safety and a
   unique `id`.
8. If anything cannot be verified, leave the entry out. An empty catalogue is
   correct; a guessed entry is not.

## Licence policy

Only these licences are accepted:

- MIT
- Apache-2.0
- BSD-2-Clause
- BSD-3-Clause
- ISC
- Unlicense
- CC0-1.0

An entry with no licence, an unverified licence, or a copyleft licence is not
installable. It may be listed, but `licence` is nil, every fetch refuses it, and
the UI marks it "No verified licence". The app never guesses a licence from a
`README`, a package manifest or a username.

## README in the detail pane

Selecting an entry fetches one README, in this order:

1. `README.md` in the directory of the entry. A setup path is that directory;
   a plugin path is a file, so its parent directory is used.
2. `README.md` at the repository root.
3. `readme.md` at the repository root.
4. `README` at the repository root.

The first file that answers is shown; a 404 moves to the next candidate. The
fetch is capped at 256 KB and cached in memory for the (entry id, ref) pair, so
returning to an entry does not fetch it again. A failed lookup is cached too.
When nothing answers, the pane shows "README unavailable" and the last source
URL it tried; it never shows an empty area.

The README is rendered as Markdown with `AttributedString(markdown:)`, with a
Rendered/Raw switch. If parsing fails, the plain text is shown instead. A
README is untrusted text: it is rendered as text, never executed, and no link
or code block is turned into a shell command. The licence name and link sit in
the README header as well as in the metadata rows.

## Setup staging

Selecting a setup fetches its tarball once into a temporary staging directory.
The detail pane shows the README, the list of files with their sizes and the
total. If the tarball breaks a limit, the refusal is shown in place of the file
list, with a Try Again button.

The staged tree is the one that is installed: confirming the install copies
from that same directory, so the tarball is not fetched twice. The staging
directory is discarded when the detail selection changes and when the install
sheet is dismissed. A setup cannot be installed until it is staged, and the
Inspect Files button stages it again after a dismissal.

A plugin keeps its single-file content preview, and its README is shown below
that preview.

## Security policy

- Downloaded code is **never executed by the app**. The app writes bytes and
  edits a loader line. It does not run the plugin, the setup or any script from
  an archive.
- The user sees the exact file content before it is written. The install sheet
  shows the bytes that will land on disk and requires an explicit licence
  acknowledgement.
- Only the pinned file or tree is fetched. A setup installs into a new profile;
  the live config is not merged, rewritten or restored.
- The archive is fetched from `codeload.github.com` and unpacked with
  `/usr/bin/tar`. Before unpacking, every member name is checked: no absolute
  paths, no `..`, no backslashes. Symbolic and hard links are refused by their
  mode in the listing, and the extracted tree is walked again to refuse links,
  count files and cap the unpacked size.
- Uninstall trusts **only** the manifest in Application Support. It removes the
  recorded path and reverts the recorded loader line. It never deletes by
  wildcard. A manifest whose path is absolute, contains `..`, leaves the config
  folder or points at a profile that is not a direct child of the profile folder
  is refused before anything is touched.
- A loader line that changed on disk is not guessed at: uninstall refuses and
  names the file, and the user removes the line by hand.
- Plugin writes go through the `backups/` mirror of the app, so the previous
  file content is kept.
- The pinned ref is checked at runtime too. A branch name in the catalogue is
  rejected before a request is made.

## Offline behaviour

The Store needs the network only to fetch content. It does not use the GitHub
API, a token, GraphQL or HTML scraping:

- one file: `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>`
- one tree: `https://codeload.github.com/<owner>/<repo>/tar.gz/<ref>`

When the network is unavailable, the fetch ends with an inline message and a
Retry button. Nothing is cached and nothing is written. The installed list
still works offline, because it comes from the local manifest.

## Limits

- 20 MB per download. The transport aborts past the cap instead of buffering
  it. The same cap applies to the staged setup tree, because the staging fetch
  uses the same archive path.
- 256 KB per README. A larger file is reported as unavailable instead of
  rendering.
- 2000 files per archive, and 200 MB unpacked.
- 30 second request timeout.
- No GitHub token and no API calls, so the anonymous rate limit does not apply
  and there is no secret to store.
- No branch refs. Tags and commits only.
- A plugin entry is one file. Everything else is a setup.
- README lookups are cached per (entry id, ref) for the life of the window;
  there is no on-disk cache.
- The tar listing is line-based, so an archive member whose name contains a
  newline is not fully validated. The catalogue pins one reviewed repository
  per entry, so the input is an allowlist; upgrade to a tar parser before
  accepting arbitrary repositories.
