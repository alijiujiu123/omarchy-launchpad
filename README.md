# Launchpad

A macOS-style application grid for [Omarchy](https://omarchy.org), as a shell
plugin.

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
| **Right-click an icon** | Uninstall it, after a confirmation |
| `Esc`, click the backdrop | Close the dialog if one is up, otherwise close Launchpad |

Scroll or drag sideways to page; click a page dot to jump. A two-finger
touchpad scroll in either axis pages too.

`Enter` deliberately does nothing while the confirmation is up. An alert that
uninstalls on the key you were already pressing to launch something is a trap,
so the answer has to be a deliberate click.

## Uninstalling

Right-click an icon and Launchpad asks whether to uninstall it. macOS does this
with a long press into jiggle mode and an X badge; right-click is the same idea
in a form that does not fight with drag-to-page.

The removal itself is entirely Omarchy's. Confirming calls the shell's own
`AppLibrary.remove()`, which runs `omarchy-remove-launcher-entry` — that decides
for itself whether the entry is a web app, a terminal wrapper, a hand-written
`.desktop` file, a pacman package or a Flatpak, and for the privileged cases
opens a floating terminal so the sudo prompt is visible to you.

**This plugin contains no `sudo`, no package manager, and no shell string.**
That is the difference between delegating a privileged action and performing
one, and it is deliberate. If the host does not provide an `AppLibrary`, the
right-click does nothing rather than falling back to something homemade.

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

The background is your real wallpaper, read from Omarchy's
`current/background` link, so a theme switch is picked up with no reload.

The blur is done **in QML**, on the wallpaper image, not by the compositor. Do
not add a `blur = true` layer rule for the `launchpad` namespace: with hyprbars
installed, a full-screen blurred layer makes title bars flicker between
transparent and coloured on every redraw, and
`decoration:blur:new_optimizations = false` does not stop it. Blurring the image
ourselves keeps Hyprland's blur machinery out of it entirely, so there is
nothing left to flicker.

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

- every `Text` that shows a name sets `textFormat: Text.PlainText`, because
  QML's default `AutoText` sniffs for HTML and switches to rich text, which
  follows markup into resource handling
- names are capped at 128 characters at the point of display, not merely elided
  (eliding still lays the whole string out)
- an icon value is used as a file path only when the entry gives an absolute one,
  and as an icon **theme name** only when it looks like one; anything else falls
  back to the generic icon rather than being sanitised
- a desktop id is shape-checked before it is launched, and the launch goes
  through `Quickshell.execDetached` with an argument array — never a shell
  string

## Licence

MIT — see [LICENSE](LICENSE).
