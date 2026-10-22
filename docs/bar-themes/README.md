# Bar themes

SketchyBar Studio can apply a named colour palette to the real SketchyBar config and put the
previous theme back. The feature edits an existing theme pattern only. It never rewrites a config
that keeps its colours in a hardcoded `colors.lua`.

## The detected pattern

The config must follow the pointer pattern of the maintainer's own config:

```
sketchybar/
  colors.lua
  themes/
    Black.lua
    White.lua
    Tokyo Night Transparent.lua
    current_theme          <- pointer file, one line: "Tokyo Night Transparent"
```

`colors.lua` reads `themes/current_theme`, clears the Lua module cache and loads
`themes.<name>.lua`. A pointer file is detected when all of these are true:

- `themes/` is a folder.
- A regular file in `themes/` is not a `.lua` or `.sh` file, and is not hidden.
- The trimmed content of that file is a single line that names a theme.
- `current_theme` wins when several files match. Otherwise the first file name in sort order wins.

Detection reports one of:

| Result | Meaning |
| --- | --- |
| `.themedPointer(name:)` | A pointer file names a theme. |
| `.luaVariable(name:, fileURL:, literalRange:)` | A Lua variable holds the name and a computed `require("themes.<name>")` reads it. |
| `.literalRequire(name:, fileURL:, literalRange:)` | A `require("themes.<name>")` call holds the name directly. |
| `.themedPointerMissing` | The `themes/` folder exists, but no pointer file matches. |
| `.noThemesFolder` | The config has no `themes/` folder. |
| `.ambiguous(reason:)` | More than one file or literal names a theme. |
| `.shellConfigUnsupported` | The config is a shell config, which this feature does not edit. |

The pointer file wins when it exists. Then a single Lua variable plus computed require wins. Then a single literal require wins. More than one Lua candidate is refused as ambiguous. A shell config is reported as unsupported rather than silently skipped.

The active theme file is read as text. Only top level `key = 0x…` entries take part in the role
mapping. A nested table, a number, a function, a comment and every other byte stay as they are.

## Apply

Apply writes `themes/<palette display name>.lua`. The new file has the same key set, the same key
order and the same layout as the active theme. The pointer file then names the new theme.

A value that is a plain 8 digit `0x` hex colour keeps its original alpha bytes. When the active
theme has `hover = 0x40FFFFFF` and the new foreground is `#d8dee9`, the new value is
`0x40d8dee9`. A 6 digit `0x` value becomes six digits again. Any other hex form is copied
unchanged.

The pointer is backed up first through the normal `backups/.sketchybar-studio/` mirror. The new
theme file is not a replacement, so there is nothing to back up for it. File permissions and line
endings are preserved.

Apply refuses, with the reason shown in the setting, when:

- The config has no `themes/` folder.
- The config has no pointer file.
- The theme the pointer names is missing or unreadable.
- `themes/<palette>.lua` already exists with different content. A theme written by the user is
  never overwritten.

If `themes/<palette>.lua` already exists with identical content, apply is a no-op success. It only
writes the pointer when the pointer still names another theme.

## Role mapping order

Every key is checked in this order. The first match wins.

1. **Semantic name.** The key names a part of the bar.
2. **Hue name.** The key names a colour. The key takes the palette swatch of the nearest hue.
3. **Luminance.** The key takes a role by its brightness.

### Semantic names

| Role | Key names |
| --- | --- |
| background | `black`, `bg`, `base`, `bar`, `*_bg`, names containing `background` |
| foreground | `white`, `fg`, names containing `foreground`, `text` or `label` |
| accent | names containing `accent` or `highlight`, and `primary` |
| accentSecondary | the second accent key of the file |
| muted | names containing `subtext`, `muted`, `secondary` or `dim` |
| border | names containing `line` or `border` |

### Hue names

| Hue | Target | Example keys |
| --- | --- | --- |
| red | 0° | `red`, `battery_red` |
| orange, brown | 30° | `orange`, `bar_brown` |
| yellow | 60° | `yellow` |
| green | 120° | `green` |
| cyan, teal | 180° | `cyan`, `teal` |
| blue | 240° | `blue` |
| purple | 270° | `purple` |
| magenta | 300° | `magenta` |
| pink | 330° | `pink` |

A key takes the swatch whose hue is nearest to the target. A swatch counts only when its
saturation is at least 0.20 and its hue is within 45 degrees of the target. Swatches are the same
strip the settings shows. Grey and gray take the muted role, white takes foreground, and black
takes background. When no swatch is close enough, the key falls to the luminance rule.

### Luminance

A key that still has no match is sorted by brightness. The darkest key gets background, the
lightest gets foreground, and every key between them gets muted. A single remaining key gets
muted. Every key of the old file appears exactly once, in the same order.

## Palette sources

Every value below is copied from the official palette file of the project. A palette that could
not be verified is not shipped.

| Palette | Mode | Background | Foreground | Accent | Source | Licence |
| --- | --- | --- | --- | --- | --- | --- |
| Nord | Dark | `#2e3440` | `#d8dee9` | `#88c0d0` | [nord.scss](https://github.com/nordtheme/nord/blob/develop/src/nord.scss) | MIT |
| Catppuccin Mocha | Dark | `#1e1e2e` | `#cdd6f4` | `#cba6f7` | [mocha.lua](https://github.com/catppuccin/nvim/blob/main/lua/catppuccin/palettes/mocha.lua) | MIT |
| Catppuccin Macchiato | Dark | `#24273a` | `#cad3f5` | `#c6a0f6` | [macchiato.lua](https://github.com/catppuccin/nvim/blob/main/lua/catppuccin/palettes/macchiato.lua) | MIT |
| Catppuccin Frappé | Dark | `#303446` | `#c6d0f5` | `#ca9ee6` | [frappe.lua](https://github.com/catppuccin/nvim/blob/main/lua/catppuccin/palettes/frappe.lua) | MIT |
| Catppuccin Latte | Light | `#eff1f5` | `#4c4f69` | `#8839ef` | [latte.lua](https://github.com/catppuccin/nvim/blob/main/lua/catppuccin/palettes/latte.lua) | MIT |
| Solarized Dark | Dark | `#002b36` | `#839496` | `#268bd2` | [solarized.vim](https://github.com/altercation/solarized/blob/master/vim-colors-solarized/colors/solarized.vim) | MIT |
| Solarized Light | Light | `#fdf6e3` | `#657b83` | `#268bd2` | [solarized.vim](https://github.com/altercation/solarized/blob/master/vim-colors-solarized/colors/solarized.vim) | MIT |
| One Dark | Dark | `#282c34` | `#abb2bf` | `#61afef` | [colors.less](https://github.com/atom/one-dark-syntax/blob/master/styles/colors.less) | MIT |
| One Light | Light | `#fafafa` | `#383a42` | `#4078f2` | [colors.less](https://github.com/atom/one-light-syntax/blob/master/styles/colors.less) | MIT |
| Dracula | Dark | `#282a36` | `#f8f8f2` | `#bd93f9` | [dracula.toml](https://github.com/dracula/alacritty/blob/master/dracula.toml) | MIT |
| Tokyo Night | Dark | `#1a1b26` | `#c0caf5` | `#7aa2f7` | [night.lua](https://github.com/folke/tokyonight.nvim/blob/main/lua/tokyonight/colors/night.lua) | Apache-2.0 |
| Tokyo Night Storm | Dark | `#24283b` | `#c0caf5` | `#7aa2f7` | [storm.lua](https://github.com/folke/tokyonight.nvim/blob/main/lua/tokyonight/colors/storm.lua) | Apache-2.0 |
| Tokyo Night Moon | Dark | `#222436` | `#c8d3f5` | `#82aaff` | [moon.lua](https://github.com/folke/tokyonight.nvim/blob/main/lua/tokyonight/colors/moon.lua) | Apache-2.0 |
| Gruvbox Dark | Dark | `#282828` | `#ebdbb2` | `#83a598` | [gruvbox.vim](https://github.com/morhetz/gruvbox/blob/master/colors/gruvbox.vim) | MIT |
| Gruvbox Light | Light | `#fbf1c7` | `#3c3836` | `#458588` | [gruvbox.vim](https://github.com/morhetz/gruvbox/blob/master/colors/gruvbox.vim) | MIT |
| Rosé Pine | Dark | `#191724` | `#e0def4` | `#c4a7e7` | [palette.json](https://github.com/rose-pine/palette/blob/main/palette.json) | MIT |
| Rosé Pine Moon | Dark | `#232136` | `#e0def4` | `#c4a7e7` | [palette.json](https://github.com/rose-pine/palette/blob/main/palette.json) | MIT |
| Rosé Pine Dawn | Light | `#faf4ed` | `#464261` | `#907aa9` | [palette.json](https://github.com/rose-pine/palette/blob/main/palette.json) | MIT |
| Everforest Dark | Dark | `#2d353b` | `#d3c6aa` | `#a7c080` | [everforest.vim](https://github.com/sainnhe/everforest/blob/master/autoload/everforest.vim) | MIT |
| Everforest Light | Light | `#fdf6e3` | `#5c6a72` | `#8da101` | [everforest.vim](https://github.com/sainnhe/everforest/blob/master/autoload/everforest.vim) | MIT |
| Kanagawa Wave | Dark | `#1f1f28` | `#dcd7ba` | `#7e9cd8` | [colors.lua](https://github.com/rebelot/kanagawa.nvim/blob/master/lua/kanagawa/colors.lua) | MIT |
| Kanagawa Dragon | Dark | `#181616` | `#c5c9c5` | `#8ba4b0` | [colors.lua](https://github.com/rebelot/kanagawa.nvim/blob/master/lua/kanagawa/colors.lua) | MIT |
| Ayu Dark | Dark | `#0f1419` | `#e6e1cf` | `#f29718` | [ayu.vim](https://github.com/ayu-theme/ayu-vim/blob/master/colors/ayu.vim) | Apache-2.0 |
| Ayu Light | Light | `#fafafa` | `#5c6773` | `#ff6a00` | [ayu.vim](https://github.com/ayu-theme/ayu-vim/blob/master/colors/ayu.vim) | Apache-2.0 |
| Ayu Mirage | Dark | `#212733` | `#d9d7ce` | `#ffcc66` | [ayu.vim](https://github.com/ayu-theme/ayu-vim/blob/master/colors/ayu.vim) | Apache-2.0 |
| Iceberg Dark | Dark | `#161821` | `#c6c8d1` | `#84a0c6` | [iceberg.vim](https://github.com/cocopon/iceberg.vim/blob/master/colors/iceberg.vim) | MIT |
| Monokai | Dark | `#272822` | `#f8f8f2` | `#66d9ef` | [monokai.yaml](https://github.com/tinted-theming/base16-schemes/blob/main/monokai.yaml) | MIT |

The two One palettes are published as HSL values. The hex values above are the exact conversion
of those HSL values.

### Monokai decision

Monokai ships as the Base16 Monokai scheme. That scheme file is part of the Tinted Theming Base16
scheme set, which is MIT licensed and credits Wimer Hazenberg as the author of the scheme. The
Monokai Pro themes are commercial and are not shipped. The repository of the Monokai organisation
has no public palette file with a redistribution licence.

## Limits

- Only the pointer pattern is supported. A config with a hardcoded `colors.lua` is refused,
  because the app cannot know which values the config really reads.
- Only top level hex entries are remapped. A colour inside a nested table, such as `bar.bg`,
  keeps its value.
- The app creates a theme file and edits one pointer file. It never edits `colors.lua`, items,
  scripts or the bar layout.
- The theme name is the display name of the palette. An existing file with that name and
  different content is refused, not merged.
- macOS keeps the config root as it is. A symlinked config folder or a symlinked file still
  receives the write at its real target.

## Revert

Before the pointer changes, apply stores the older pointer text per config root in
`UserDefaults`. "Restore previous theme" writes that text back to the pointer file only. It does
not delete the theme file that apply created, so the user can pick the same palette again or move
the file. The stored value is cleared after a restore. The restore uses the same backup mirror as
apply.
