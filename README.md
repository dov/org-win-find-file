# org-win-find-file

Open one or more files or org links in a freshly built, possibly
nested window layout, via a `win:` org link.

## Installation

Not yet on MELPA. Until then, clone this repo and add it to your
`load-path`:

```elisp
(add-to-list 'load-path "/path/to/org-win-find-file")
(require 'org-win-find-file)
```

## Usage

The link path is an expression built from targets and two split
operators:

- `|` horizontal split -- windows placed side by side (left to right)
- `÷` vertical split -- windows stacked (top to bottom)

Parentheses group sub-layouts. `÷` binds looser than `|`, so
`a|b÷c` is read as `(a|b) ÷ c`.

Each target is either another org link (e.g. `info:emacs#Windows`),
opened through org's own link machinery, or a plain file path opened
with `find-file`.

A target may carry a suffix of window options, written between
guillemets (`«...»`) immediately after the target. Options are
separated by commas; each is a single-letter key, optionally
`key=value`:

| Key | Meaning |
| --- | --- |
| `s` | sticky -- dedicate the window to its buffer |
| `f` | focus -- leave point in this window once the layout is built |
| `r` | read-only -- visit the buffer in `read-only-mode` |
| `o` | no-other-window -- skip this window when cycling with `C-x o` |
| `a` | auto-revert -- enable `auto-revert-mode` in the buffer |
| `F` | fit -- shrink the window to its buffer's contents |
| `w=SIZE` | size -- give the window SIZE along its split axis, as a percentage (`40%`) or an absolute number of columns/lines (`80`) |

Several options may be combined, e.g. `target«s,r,w=40%»`. A link
whose final target carries a suffix must be written in bracketed
form (`[[win:...]]`), since a plain link would lose its trailing
guillemet.

### Examples

```
[[win:info:emacs#Windows]]
```
Open the "Windows" node of the Emacs manual in a single window.

```
[[win:info:emacs#Windows|info:emacs#Frames]]
```
Two windows side by side: the "Windows" node on the left, the
"Frames" node on the right.

```
[[win:info:emacs#Windows«s,f»|doc.org«r,w=40%»]]
```
The "Windows" node sticky and focused on the left; `doc.org`
read-only on the right, sized to 40% of the split.

```
[[win:foo.bar÷(wuz.bar|maz.bar)]]
```
`foo.bar` on top; below it `wuz.bar` and `maz.bar` side by side.

```
[[win:/etc/fstab÷/backup/etc/fstab]]
```
Two plain files stacked top over bottom.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
