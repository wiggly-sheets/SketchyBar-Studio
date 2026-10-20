# Reference

The factual appendix for the bar renderer. Every claim about SketchyBar behaviour cites `file:line` in the reference checkout `/Users/Zeb/Developer/SketchyBar` at `v2.24.0-50-gf23f4f4`, unless it is marked UNVERIFIED. The installed `sketchybar` 2.24.1 is the same wiggly-sheets fork.

## How SketchyBar renders today

Every function named below has its file and line in the C source references at the end of this file. The facts a stage file also needs live in that stage file: the window-server calls in [Stage 1](phase-1-vendor-core.md), the defaults in [Stage 3](phase-3-config-bridge.md), the layout entanglement in [Stage 4](phase-4-layout-and-render.md), and the points-versus-pixels rule in [Stage 2](phase-2-headless-core.md).

**The render path is already offscreen.** `src/context.c:11-26` creates a plain `CGBitmapContextCreate`, `src/surface.c:67-75` (`surface_flush`) turns it into a `CGImage` and pushes it into a CALayer (`src/layer.m:48-55`), and `bar_item_draw` (`src/bar_item.c:842-856`) with its whole subtree (background, text, image, ring, slider, graph, alias, badge) is pure CoreGraphics/CoreText with no window-server dependency.

**Build shape.** The project has a `makefile` only: one binary, one main plus 36 objects, `-fvisibility=hidden` (`makefile:1`). The full binary links Carbon, AppKit, QuartzCore, CoreAudio, CoreWLAN, CoreVideo, IOKit and the private SkyLight, DisplayServices and MediaRemote frameworks (the `LIBS` block, `makefile:3-13`). There is **no cairo and no yabai**; rendering is CoreGraphics plus CoreText. The source tree is about 14,300 lines (roughly 11,070 `.c`, 790 `.m`, 2,450 `.h`), measured on 2026-10-20 over `src/`; `wc -l` over `src/` reproduces the figure.

**Text measurement is CoreText.** `src/text.c:80-93` uses `CTLineGetTypographicBounds` and `CTLineGetBoundsWithOptions(..., kCTLineBoundsUseGlyphPathBounds)`; width is `(uint32_t)(bounds.width + 1.5)`, height likewise. Length is width plus text padding left and right (`src/text.c:817-841`). Vertical centring is `y − (ascent − descent)/2` (`src/text.c:868-869`). **Fonts.** Defaults are "Hack Nerd Font" / "Bold" / 14 (`src/font.c:152-158`); `font_create_ctfont` builds a `CTFont` with `CTFontCreateWithFontDescriptor` from family, style and size (`src/font.c:24-150`); the config syntax is `Family:Style:Size` parsed with `sscanf` (`src/font.c:217-235`); `--load-font` registers fonts at process scope (`src/font.c:5-22`, `src/message.c:743-745`).

**Config loading** (`src/hotload.c:46-70`): SketchyBar sets `CONFIG_DIR`, chdirs into the config dir, chmod +x the rc, then `fork_exec` → `sync_exec` → `execvp("/usr/bin/env", {"env","sh","-c", path, NULL})` (`src/misc/helpers.h:441-461`). `sh -c` execs the file, and the **kernel** reads the shebang of the file, so a `#!/usr/bin/env lua` rc runs under lua. SketchyBar itself has **zero** Lua support; all Lua is SbarLua. Hot reload is an FSEvents watcher (`src/hotload.c:72-112`).

**Windows.** The bar window holds only the background (`src/bar.c:146-154`). Each item is its own SkyLight window positioned by `window_set_frame` (`src/bar_item.c:556-583`), ordered by `bar_order_item_windows` (`src/bar.c:82-111`). A SketchyBar window cannot be parented into an NSView. `sticky` defaults to true, so the daemon creates its own Space (`src/window.c:95-119`). The bar bitmap renders at a **fixed scale of 2.0**, independent of the display (`src/surface.c:37`, `src/surface.c:47`, `src/surface.c:53`, `src/window.c:81`, `src/layer.m:19`, `src/layer.m:53`). The points-versus-pixels rule is in [Stage 2](phase-2-headless-core.md) and [Stage 4](phase-4-layout-and-render.md).

## Item semantics that matter for exactness

* Item padding belongs to the item *background* (`src/bar_item.c:1343-1356`).
* Text padding belongs to the *text* (`src/text.c:1124-1136`).
* `align` shifts content inside a constant width: centre adds `(len − content)/2`, right adds `(len − content)` (`src/bar_item.c:641-645`).
* The label starts at the icon's *text* width, with no gap unless text padding says so (`src/bar_item.c:647-650`).
* `width` is `has_const_width + custom_width` (`src/bar_item.h:41-45`, `src/bar_item.c:517-532`).
* `y_offset` shifts icon, label and background together.
* `max_chars` truncates and re-measures (`src/text.c:12-48`).
* `scroll_texts` animates (`src/text.c:914-951`).
* `space` is a marker item with a default script `sketchybar -m --set $NAME icon.highlight=$SELECTED` (`src/bar_item.c:430`, in the block `src/bar_item.c:407-447`), `updates=false`, and the environment variables `SELECTED`, `SID`, `DID`. The `-m` is the message marker (`src/sketchybar.c:17-18`), and the client strips it before it sends the message (`src/sketchybar.c:170-172`).
* `bracket`/group draws **one** background spanning the first to the last member: `group_calculate_bounds` calls `background_calculate_bounds(&group->members[0]->background, …, group_get_length(…), …)` (`src/group.c:133-137`), and `group_get_length` spans the first to the last member (`src/group.c:77-85`).
* `alias` draws a captured window image (`src/alias.c:260-300`), and the capture itself is `window_capture` (`src/alias.c:237`).
* Popups are separate windows: the window is created at `src/popup.c:383` and framed at `src/popup.c:375`. The bar-item anchor math is `src/bar.c:33-80`.

## The bar defaults

```
background height      25                      src/bar_manager.c:51
padding_left           20                      src/bar_manager.c:53
padding_right          20                      src/bar_manager.c:54
notch_width            200                     src/bar_manager.c:39
background color       0x44000000              src/bar_manager.c:57
border color           0xffff0000              src/bar_manager.c:56
position               top                     src/bar_manager.c:31
sticky                 true                    src/bar_manager.c:45
show_in_fullscreen     false                   src/bar_manager.c:47
window level           kCGBackstopMenuLevel    src/bar_manager.c:37
font                   Hack Nerd Font / Bold / 14   src/font.c:152-158
```

The whole block is `src/bar_manager.c:21-58`.

## The layout algorithm, structurally

This is a reading aid for the implementer. The vendored code is the authority, and [Stage 8](phase-8-exactness-and-diff.md) checks this summary against it. The file and line of every function is in the C source references below.

```
bar_calculate_bounds(bar, displays)                      src/bar.c:426-435
    for each display:
        frame = display.bounds inset by 2 * bar.margin  src/bar.c:437-494
        if bar.position is top or bottom:
            bar_calculate_bounds_top_bottom(...)         src/bar.c:200-318
        if bar.position is left or right:
            bar_calculate_bounds_left_right(...)         src/bar.c:320-424

bar_calculate_bounds_top_bottom(...)
    group the items by position: left, center, right
    for each side:
        length = bar_manager_length_for_bar_side(side)  src/bar_manager.c:323-342
        for each item of the side, in order:
            item_calculate_bounds(item, length)          src/bar_item.c:634-713
                width  = has_const_width + custom_width   src/bar_item.c:517-532
                align shifts the content inside the width src/bar_item.c:641-645
                the label starts at the icon's text width src/bar_item.c:647-650
            the item's frame is recorded (window_set_frame in the real app)
            the item is drawn                              src/bar_item.c:842-856

text_calculate_bounds_at(text)                           src/text.c:857-898
    CTLineGetTypographicBounds + kCTLineBoundsUseGlyphPathBounds   src/text.c:80-93
    width  = (uint32_t)(bounds.width + 1.5)
    height = (uint32_t)(bounds.height + 1.5)
    length = width + padding_left + padding_right       src/text.c:817-841
    y      = y - (ascent - descent) / 2                  src/text.c:868-869

group_calculate_bounds(group)                            src/group.c:109-138
    one background spans the first to the last member    src/group.c:77-85
```

The layout math is about 455 lines in total, in the eight functions cited above. The item semantics that decide the result are in the section above.

## The CLI reference

```
sketchybar --set <alias> <prop>=<val> [<prop>=<val> ...]
    the server side is src/message.c:623-663; the client sends a NUL-separated
    argv payload, src/sketchybar.c:60-108

sketchybar -m --set <alias> <prop>=<val> ...
sketchybar --message --set <alias> <prop>=<val> ...
    -m and --message are the same message marker (src/sketchybar.c:17-18); the
    client strips it before it sends the message (src/sketchybar.c:170-172).
    The fork's own space item uses this form (src/bar_item.c:430).

sketchybar --default <prop>=<val> ...
    this changes the DEFAULT ITEM, not the bar: src/misc/help.h:12-13 routes it
    to bar_item_parse_set_message(&g_bar_manager.default_item, ...), src/message.c:335

sketchybar --bar <prop>=<val> ...
sketchybar --query bar
sketchybar --query <item>
    the reply is close to valid JSON but is not always valid JSON. The real
    breakers are escape_string, which does not escape the backslash
    (src/misc/helpers.h:83-103), and the error path, which returns "[!] ..."
    (src/message.c:512, src/message.c:529). The parser is [Stage 8](phase-8-exactness-and-diff.md).
    The item reply holds "geometry" and "bounding_rects", src/bar_item.c:1080-1094.

sketchybar --reload
    the config is reloaded through the FSEvents watcher, src/hotload.c:72-112

the reply goes to stdout, errors go to stderr as "[!] ..." and are detected by
the client on the second character, src/sketchybar.c:99-105

--dump and --list DO NOT EXIST in 2.24. Never build on them.
```

The `--query` command is declared at `src/misc/defines.h:159`; its domain at `src/message.c:716-719` and its handler at `src/message.c:502-534`. The `--set` handler is `src/message.c:623-663`. The add, clone, subscribe, push, update, trigger, reorder, move and remove handlers are `src/message.c:693-729`. The value transport is `get_key_value_pair` and `pack_key_value_pair` (`src/misc/helpers.h:126-149`) and the NUL-terminated token reader `get_token` (`src/misc/helpers.h:260-276`); the pair is re-split on the first `=` only by `reformat_batch_key_value_pair` (`src/message.c:468-478`, which calls `get_key_value_pair` at `src/misc/helpers.h:126-147`). Nothing in this path splits a value on spaces.

IPC: the Mach bootstrap service is named `git.felix.<basename(argv[0])>` (`src/mach.h:9`, `src/sketchybar.c:203`); the lock file is `/tmp/<name>_<USER>.lock` with `fcntl(F_SETLK)` (`src/sketchybar.c:15`, `src/sketchybar.c:110-127`, `src/sketchybar.c:137`, `src/sketchybar.c:215`). The SF Symbol size model: SketchyBar draws symbols at a 32pt base and derives the drawn size from the symbol's pixel height divided by 32, times the scale (`src/image.c:261-277`).

## The C source references

```
src/context.c:11-26              CGBitmapContextCreate: the offscreen render target
src/surface.c:67-75              surface_flush: bitmap -> CGImage -> CALayer
src/layer.m:48-55                the CALayer that receives the frame
src/bar_item.c:842-856           bar_item_draw: the draw entry of an item
src/bar.c:200-318                bar_calculate_bounds_top_bottom
src/bar.c:320-424                bar_calculate_bounds_left_right
src/bar.c:426-435                bar_calculate_bounds
src/bar.c:437-494                the bar frame: display width minus twice the margin
src/bar.c:33-80                  the popup anchor math for a bar item
src/bar.c:82-111                 bar_order_item_windows
src/bar.c:146-154                the bar window holds only the background
src/bar.c:280                    the window_set_frame call, top/bottom layout
src/bar.c:404                    the window_set_frame call, left/right layout
src/bar.c:543                    SLSSpaceGetType(g_connection, ...): needs a stub
src/bar_item.c:556-583           bar_item_get_window: creates a window on demand
src/bar_item.c:570               window_open
src/bar_item.c:634-713           bar_item_calculate_bounds
src/bar_item.c:641-645           align: centre and right shift inside a const width
src/bar_item.c:647-650           the label starts at the icon's text width
src/bar_item.c:506-554           bar_item_get_length / height / content_length
src/bar_item.c:517-532           width = has_const_width + custom_width
src/bar_item.h:41-45             the width fields
src/bar_item.c:68                bar_item_init inherits from the default item
src/bar_item.c:883-933           bar_item_inherit_from_item: the inheritance body
src/bar_item.c:1080-1094         the "bounding_rects" of --query <item>, in POINTS
src/bar_item.c:1198-1203         icon = "..." routes to text_parse_sub_domain
src/bar_item.c:1343-1356         item padding belongs to the item background
src/bar_item.c:407-447           the space item and its default script
src/bar_item.c:430               the space default script: sketchybar -m --set ...
src/bar_item.c:166-168           the item script runs through fork_exec
src/bar_manager.c:21-58          the bar defaults
src/bar_manager.c:323-342        bar_manager_length_for_bar_side
src/bar_manager.c:463            bar_item_init(bar_item, &default_item): the snapshot
src/bar_manager.c:956            SLSSpaceGetType(g_connection, ...): needs a stub
src/text.c:12-48                 max_chars truncates and re-measures
src/text.c:80-93                 the CoreText measurement
src/text.c:817-841               the length of a text: width plus text paddings
src/text.c:857-898               text_calculate_bounds_at
src/text.c:868-869               the vertical centring
src/text.c:914-951               scroll_texts
src/text.c:1124-1136             text padding belongs to the text
src/text.c:1180-1186             a text value is set as TEXT
src/group.c:77-85                group_get_length: first to last member
src/group.c:109-138              group_calculate_bounds
src/group.c:133-137              the one background of a group
src/font.c:24-150                font_create_ctfont
src/font.c:5-22                  --load-font registers at process scope
src/font.c:152-158               the font defaults (Hack Nerd Font / Bold / 14)
src/font.c:217-235               the Family:Style:Size syntax
src/image.c:46-95                the IMAGE domain: image, background.image
src/image.c:56-90                image_load: app., space., media.artwork, sf.
src/image.c:82-94                the "sf." branch of image_load
src/image.c:261-277              the symbol size model: 32pt base, height / 32 * scale
src/window.c:65                  SLSNewWindowWithOpaqueShapeAndContext
src/window.c:81                  SLSSetWindowResolution(..., 2.0f): the fixed scale
src/window.c:95-119              sticky: the daemon creates its own Space
src/window.c:158-170             window_set_frame: pure bookkeeping
src/window.c:347-378             SLSCaptureWindowsContentsToRectWithOptions
src/alias.c:237                  window_capture: the captured window image
src/alias.c:260-300              alias draws a captured window image
src/popup.c:375                  window_set_frame of the popup window
src/popup.c:383                  window_open of the popup window
src/hotload.c:46-70              the config load: execvp("/usr/bin/env", {"env","sh","-c"})
src/hotload.c:72-112             the FSEvents hot reload watcher
src/mach.h:9                     MACH_BS_NAME_FMT "git.felix.%s"
src/sketchybar.c:15              the lock file path
src/sketchybar.c:17-18           the message marker: --message and -m
src/sketchybar.c:60-108          the client sends a NUL-separated argv payload
src/sketchybar.c:99-105          the reply goes to stdout, errors to stderr as "[!] ..."
src/sketchybar.c:110-127         the lock file, fcntl(F_SETLK)
src/sketchybar.c:170-172         the message marker is stripped before sending
src/sketchybar.c:203             the bootstrap name from argv[0]
src/sketchybar.c:208             setenv("BAR_NAME", ...)
src/message.c:335                --default routes to the default item
src/message.c:468-478            reformat_batch_key_value_pair: the first "=" only
src/message.c:502-534            the --query handler
src/message.c:512                the "[!] ..." error reply of a failed query
src/message.c:529                the "[!] ..." error reply of an invalid query
src/message.c:623-663            the --set handler
src/message.c:693-729            the add, clone, subscribe, push, update, trigger,
                                 reorder, move and remove handlers
src/message.c:716-719            the --query domain
src/message.c:743-745            --load-font
src/misc/defines.h:159           the query command
src/misc/helpers.h:20            extern int g_connection
src/misc/helpers.h:79-81         format_bool: "on" and "off" as quoted strings
src/misc/helpers.h:83-103        escape_string: no backslash escape
src/misc/helpers.h:126-149       get_key_value_pair, pack_key_value_pair
src/misc/helpers.h:260-276       get_token: NUL-terminated tokens
src/misc/helpers.h:441-461       sync_exec and fork_exec
src/misc/helpers.h:454-462       fork_exec
src/misc/helpers.h:468           SLSCopyManagedDisplaySpaces(g_connection)
src/misc/helpers.h:496           SLSCopyManagedDisplaySpaces(g_connection)
src/misc/helpers.h:524           SLSHWCaptureSpace(g_connection, ...)
src/misc/helpers.h:537           SLSCopyManagedDisplayForSpace(g_connection, ...)
src/misc/help.h:12-13            --default: "Change default properties for new items"
src/surface.c:37                 SLSSetSurfaceResolution(..., 2.0): the fixed scale
src/surface.c:47                 context_create(frame.size, 2.0f): the fixed scale
src/surface.c:53                 context_create(frame.size, 2.0f) on resize
src/layer.m:19                   calayer.contentsScale = 2.0
src/layer.m:53                   typed_layer.contentsScale = 2.0
makefile:1                       -fvisibility=hidden
makefile:3-13                    the framework list of the full binary (LIBS)
LICENSE.md:1-3                   GPL-3.0
LICENSE.md:379-380               §7(e), the trademark carve-out
```

## The gap list of the current preview

The current preview is `Sources/SketchyBarStudio/Views/BarPreviewView.swift`. It is a draft bar preview for editing: one preview row per **file**, not per item, drawn with SwiftUI. It is useful for reordering and width editing and it stays.

```
one preview row per FILE, not per item
sbar.default({...}) / --default inheritance        not applied
drawing = false                                    not honoured
text-level paddings                                not read
item types other than "item"                       not drawn
positions q / e / popup.<host>                     not accepted
align                                              not applied
width = dynamic                                    not handled
max_chars                                          not applied
scroll_texts                                       not animated
bar height / margin / y_offset / notch             not applied
popups                                             not drawn
brackets and groups                                not drawn
real text metrics (CoreText)                       not used
SF Symbol size model (32pt base, height / 32)      not used, a fixed 16pt is drawn
```

(One line per gap.) The concrete places: the app reads item-level `padding_left` / `padding_right` only (`BarPreviewView.swift:185-187`); `BarPreviewItem.init` only accepts left / center / right (`BarPreviewView.swift:174-180`); and the app draws a symbol at a fixed 16pt (`BarPreviewView.swift:341`).

## The repository files this plan touches

`Package.swift`, `Sources/SketchyBarStudio/Stores/SketchyBarStore.swift` (the apply and reload path), `Sources/SketchyBarStudio/Services/SbarLuaItemParser.swift` (the SbarLua item parser), `Sources/SketchyBarStudio/Services/LuaTableParser.swift` (the table and call parser), `Sources/SketchyBarStudio/Models/StructuredItem.swift` (the alias and the key path), `Sources/SketchyBarStudio/Views/BarPreviewView.swift` (the current mock preview), `Sources/SketchyBarStudio/Views/DetailView.swift`, `Sources/SketchyBarStudio/Views/SettingsView.swift`, `Sources/SketchyBarStudio/Support/SketchyBarIcon.swift` (the icon value reader), `Tests/SketchyBarStudioTests` (the suite run by `swift test`) and `script/build_and_run.sh`.

## Open questions

Every item in this section is **UNVERIFIED** and must be confirmed against the source or by experiment before the stage that depends on it starts.

1. **UNVERIFIED — does the SketchyBar `--set` server re-split a `property=value` argument on spaces?** This decides whether a label containing a space can be pushed to the live bar. The transport preserves spaces: the client sends argv NUL-separated (`src/sketchybar.c:60-108`) and the server reads NUL-terminated tokens (`src/misc/helpers.h:260-276`). The pair is then re-split on the first `=` (`src/message.c:468-478`). What is not confirmed is the per-property parse (`bar_item_parse_set_message` and the text parser). Confirm by experiment: run `sketchybar --set <alias> label="a b"` against a scratch daemon and read the value back with `--query`.
2. **UNVERIFIED — does the vendored subset compile cleanly after the private-framework files are removed?** [Stage 1](phase-1-vendor-core.md) answers this. The set of remaining calls into `window.c`, `display.c` and the private frameworks is only known after the first compile.
3. **UNVERIFIED — what exactly does `sbar.default({...})` do when a script overrides it?** The defaults are applied to `default_item` (`src/bar_item.c:883-933`), but the order between a default set at load time and a later `--default` at runtime, and the behaviour when an item script sets a property that a default also sets, is not confirmed.
4. **UNVERIFIED — do the `Highlight` / `icon` image-versus-text semantics match the fork's man page?** The man page `sketchybarrc-items.5` sections around `:275-283`, `:729` and `:853` are the evidence. The man pages are **not** present in the local `v2.24.0-50-gf23f4f4` checkout, so they must come from the installed package or from upstream. Confirm before relying on either reading.
5. **UNVERIFIED — what happens to `src/display_nsscreen.m` in the vendored subset?** The drop list does not name it. It provides the NSScreen-backed display provider, and the preview needs a virtual display instead.
6. **UNVERIFIED — how does the fork's `space` item behave in a preview?** It needs a Space capture, which needs the window server. The placeholder and its geometry are decided in [Stage 4](phase-4-layout-and-render.md).
7. **UNVERIFIED — how long does a typical item script take, and what timeout is right?** The value is a project decision, informed by measurement.

## The `icon` prefix semantics — a question to confirm

`Sources/SketchyBarStudio/Support/SketchyBarIcon.swift` treats an item `icon` value with the prefix `sf.` or `app.` as an SF Symbol or an app icon (`SketchyBarIcon.parse`, `Support/SketchyBarIcon.swift:31-52`; `app.` and `media.artwork` are handled at `:41-49`).

The man page of SketchyBar 2.24 documents the `icon` property as **text** and puts the `sf.` / `app.` / `media.artwork` forms in the **image** domain (`image`, `background.image`). The evidence is the man page `sketchybarrc-items.5` sections around `:275-283`, `:729` and `:853`, and `src/image.c:56-90`, where `image_load` handles the `app.`, `space.`, `media.artwork` and `sf.` forms.

The source says the same. The `icon` property is routed to `text_parse_sub_domain` with `PROPERTY_STRING` (`src/bar_item.c:1198-1203`), and the text domain sets a value as TEXT (`src/text.c:1180-1186`). The **image** domain is a different one (`src/image.c:46-95`), and `src/image.c:82-95` turning an `sf.` value into an image is evidence about the IMAGE domain, not about the `icon` property.

**This is to be confirmed against the source before any change.** Do not change `SketchyBarIcon` on the strength of this note. If it is confirmed, the fix belongs in the [config bridge](phase-3-config-bridge.md) and in the preview, not in a blind edit of `SketchyBarIcon`, and the existing app behaviour for the `icon` property stays as it is until then.

The counter-evidence has to be read, not assumed. The `sf.` branch of `image_load` (`src/image.c:82-94`, `src/image.c:82-95`) does draw an `sf.` value as a symbol, so the fork may already handle `icon = "sf.x"` correctly. The real counter-evidence is the man page, and the man page is **absent from this checkout**: there is no `man/` directory in the repository root of `v2.24.0-50-gf23f4f4`, so it has to come from the installed package or from upstream. That is why the question is still open. There is no confirmed bug here.
