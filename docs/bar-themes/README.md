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
| `.themedPointerMissing` | The `themes/` folder exists, but no pointer file matches. |
| `.noThemesFolder` | The config has no `themes/` folder. |

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

## Role table

The role of a key comes from its name first.

| Role | Key names |
| --- | --- |
| background | `black`, `bg`, `base`, `bar`, `*_bg`, names containing `background` |
| foreground | `white`, `fg`, names containing `foreground`, `text` or `label` |
| accent | names containing `accent` or `highlight`, and `primary` |
| accentSecondary | the second accent key of the file |
| muted | names containing `subtext`, `muted`, `secondary` or `dim` |
| border | names containing `line` or `border` |

A key that no rule matches is assigned by luminance. The darkest remaining key gets background,
the lightest gets foreground, and every key between them gets muted. A single remaining key gets
muted. Every key of the old file appears in the new file.

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
| Tokyo Night | Dark | `#1a1b26` | `#c0caf5` | `#7aa2f7` | [storm.lua](https://github.com/folke/tokyonight.nvim/blob/main/lua/tokyonight/colors/storm.lua) and [night.lua](https://github.com/folke/tokyonight.nvim/blob/main/lua/tokyonight/colors/night.lua) | Apache-2.0 |
| Gruvbox Dark | Dark | `#282828` | `#ebdbb2` | `#83a598` | [gruvbox.vim](https://github.com/morhetz/gruvbox/blob/master/colors/gruvbox.vim) | MIT |
| Gruvbox Light | Light | `#fbf1c7` | `#3c3836` | `#458588` | [gruvbox.vim](https://github.com/morhetz/gruvbox/blob/master/colors/gruvbox.vim) | MIT |
| Rosé Pine | Dark | `#191724` | `#e0def4` | `#c4a7e7` | [palette.json](https://github.com/rose-pine/palette/blob/main/palette.json) | MIT |
| Rosé Pine Moon | Dark | `#232136` | `#e0def4` | `#c4a7e7` | [palette.json](https://github.com/rose-pine/palette/blob/main/palette.json) | MIT |

The two One palettes are published as HSL values. The hex values above are the exact conversion
of those HSL values.

Monokai is not shipped. The Monokai organisation has no public palette file with a licence, and
the Monokai Pro files are commercial. A guessed Monokai palette would not meet the rule that every
palette comes from its official source.

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
