# Launchpad

A macOS-style application grid for [Omarchy](https://omarchy.org), as a shell
plugin.

![Launchpad showing a six-by-five grid of application icons over the blurred desktop wallpaper, with a search pill at the top and three page dots at the bottom](preview.png)

A full-screen page of app icons over your own wallpaper, blurred and dimmed,
with a search pill at the top and page dots at the bottom. Type to filter, swipe
or scroll to page, click to launch.

The page is a fixed **6 × 5** shape and every other dimension — cell, icon,
label, padding — is derived from it and from the screen it is on. That is what
makes it read as Launchpad rather than as a generic app menu, and it is why
there is one window per screen: a 5K monitor and a laptop panel each size their
own grid instead of sharing one pixel-fixed icon size.

## Install

```bash
omarchy plugin add https://github.com/AndyWeiBoan/omarchy-launchpad --enable
```

Then bind a key — plugins cannot bind keys themselves. In
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + A", "Launchpad (app grid)",
  "omarchy-shell shell toggle io.github.andyweiboan.launchpad '{}'")
```

For the legacy (non-Lua) Hyprland config format, see
[`install/bindings.conf`](install/bindings.conf).

A touchpad gesture is optional and lives in
[`install/gestures.lua`](install/gestures.lua): four-finger pinch in, the same
gesture macOS uses.

`SUPER+A` rather than `SUPER+SPACE` because Omarchy's own launcher already owns
that, and the two answer different questions — the launcher is for *I know what
I want*, Launchpad is for *show me everything*.

## Removal

```bash
omarchy plugin disable io.github.andyweiboan.launchpad
omarchy plugin remove  io.github.andyweiboan.launchpad
```

Then delete the bind you added to `bindings.lua`, and the gesture from
`input.lua` if you added that.

The plugin writes nothing outside its own folder — no config files, no state, no
autostart entries, nothing in `~/.local`. Removing it leaves nothing behind, and
disabling it is enough to stop it being mounted. The keybinding is the only
thing it asks you to change, and you make that change yourself.

## Keys

| Key | Action |
| --- | --- |
| *(type anything)* | Filter by name or generic name, live |
| `Enter` | Launch the first match |
| `←` `→` | Previous / next page — but only when the search box is empty, so arrow keys still edit the text |
| **Hold an icon** (or right-click it) | Enter jiggle mode — every icon gets a remove badge |
| **Click a remove badge** | Uninstall that app, after a confirmation |
| Click an icon while jiggling | Leave jiggle mode (it does **not** launch) |
| `Esc`, click the backdrop | Back out one layer: dialog, then jiggle mode, then Launchpad |

It opens on the display you are working on, not on all of them at once.

Scroll or drag sideways to page; click a page dot to jump. A two-finger
touchpad scroll in either axis pages too.

`Enter` deliberately does nothing while the confirmation is up. An alert that
uninstalls on the key you were already pressing to launch something is a trap,
so the answer has to be a deliberate click.

## Uninstalling

Hold an icon and the grid starts wobbling with a remove badge on every app,
exactly as macOS Launchpad does; right-click gets there too, because holding a
mouse button to edit is not a gesture anyone tries on a desktop. Click a badge
and Launchpad asks before doing anything.

It is a mode, not a menu: anything that is not a badge leaves it, including
clicking an icon — so the click that stops editing never also launches
something. Typing leaves it as well, since a search is a request to find
something rather than to keep editing.

The removal itself is entirely Omarchy's. Confirming calls the shell's own
`AppLibrary.remove()`, which runs `omarchy-remove-launcher-entry` — that decides
for itself whether the entry is a web app, a terminal wrapper, a hand-written
`.desktop` file, a system package or a Flatpak. Where elevated rights are
needed it opens a floating terminal, so the authentication prompt is visible to
you rather than happening somewhere you cannot see.

Note that the system-package branch removes unused dependencies along with the
application, so uninstalling one thing can remove several packages. That is
Omarchy's behaviour rather than this plugin's, and the terminal lists everything
before you confirm.

**This plugin contains no privilege escalation, no package-manager command, and
no shell string.** That is the difference between delegating a privileged action
and performing one, and it is deliberate. If the host does not provide an
`AppLibrary`, the badge does nothing rather than falling back to something
homemade.

Names taken from `.desktop` files are stripped of control characters before they
are displayed or handed on. `printf %q` protects a shell correctly, but escape
sequences survive it and reach the terminal emulator, which is a different
reader with different rules.

## Requirements

No external dependencies to install — it is QML, and everything it uses ships
with Omarchy.

- Omarchy with shell plugin support (`omarchy plugin list` works)
- `uwsm-app` and `gtk-launch`, used to start the application you pick. Both come
  with Omarchy. Going through `uwsm-app` is what keeps launched apps out of the
  compositor's own systemd scope, which is the same path Omarchy's menu uses.


Applications come from `DesktopEntries`, Quickshell's own XDG `.desktop` index,
so installs and removals are picked up live with no watcher and no cache of our
own. Entries marked `NoDisplay` are skipped.

## Theming

The backdrop is the **compositor's** blur of whatever is behind the grid — this
plugin reads no wallpaper file of its own, so it always matches the current
theme and background without being told. It needs the layer rule in
[`install/looknfeel.lua`](install/looknfeel.lua) and blur enabled globally.

Earlier versions loaded Omarchy's wallpaper and blurred it in QML. Doing that
safely means validating a file whose path something else controls, and a check
that finishes before the read cannot bind what the read consumes. Handing the
job to the compositor removes the file and the question with it.

**Known issue, not caused by this plugin.** With hyprbars installed, Hyprland
0.56 flickers window title bars whenever blur runs and `decoration:rounding` is
non-zero — its blur path invalidates the stencil buffer hyprbars masks its
rounded corners into ([hyprwm/hyprland-plugins#697](https://github.com/hyprwm/hyprland-plugins/issues/697)).
It is most visible just after this grid closes, because tearing down a
full-screen blurred layer triggers a burst of blur passes. Leaving the layer
rule out avoids triggering it, at the cost of an unblurred backdrop.

## Performance

The plugin declares `keepLoaded: true`, so the shell mounts it at startup and it
stays mounted, hidden, until summoned. That is not an optimisation detail, it is
the difference between usable and not: a standalone predecessor launched a
Quickshell process per keypress and took **~340ms** before anything appeared —
~145ms of Qt/QML startup plus ~190ms decoding a 5120×2880 wallpaper, neither
avoidable per launch. Giving the `Image` a smaller `sourceSize` measured
*slower*, because Qt still parses the whole JPEG and then adds a scale on top.

Mounted once, a toggle is ~80ms, and the cost while hidden is the decoded
wallpaper it is holding — the icon grid is built from a model that is already
in memory.

Being mounted is also why the search box and page index are reset explicitly on
every open: the QML tree outlives any one opening, and Launchpad always opens on
page one with an empty box.

## Security

A `.desktop` file is not a trusted document — anything that can write to
`~/.local/share/applications` chooses the name and icon strings, and they arrive
in a long-lived process that owns the whole shell surface. So:

- **the model is bounded at construction, not at display.** At most 512 entries
  and 128 KB of retained text; each field is capped at 128 characters and the
  lowercase search key is computed once, when the record is built. Capping a
  label as it is *drawn* does nothing for the work already spent counting,
  sorting and re-filtering an unbounded set on every keystroke — in a process
  that stays mounted for the whole session. If a limit is reached the model
  stops consuming and the grid says so rather than quietly showing a short list.
- every `Text` that shows a name sets `textFormat: Text.PlainText`, because
  QML's default `AutoText` sniffs for HTML and switches to rich text, which
  follows markup into resource handling
- names are capped at 128 characters and stripped of control characters
- **icons resolve through the icon theme only.** No path from a `.desktop` entry
  ever reaches the image loader: the entry is as untrusted as anything else that
  can be written into `~/.local/share/applications`, and QML cannot tell a
  regular file from a FIFO or a device node. Anything that is not a
  well-formed theme name falls back to the generic icon.
- a desktop id is shape-checked before it is used, and the launch goes through
  `Quickshell.execDetached` with an argument array — never a shell string

## Licence

MIT — see [LICENSE](LICENSE).
