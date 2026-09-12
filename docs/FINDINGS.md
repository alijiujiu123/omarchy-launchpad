# Findings

Everything here was measured or hit in practice on Omarchy + Hyprland with
Quickshell 0.3.x. Numbers come from a 3840×2400 laptop panel and a 5120×2880
external display.

## 1. Why not nwg-drawer

nwg-drawer is the obvious existing answer and it was the first attempt. It
cannot do the three things that make a grid read as Launchpad:

- a **fixed rows × columns page**, so the same app is in the same place every
  time
- **page dots**, and therefore a notion of pages at all
- an **icon size derived from the screen**, so a 5K display and a laptop panel
  are both right

Those three are the whole visual identity. Without them it is an app menu with a
wallpaper behind it.

## 2. Launching per keypress costs ~340ms, and it is not fixable

Timed to first pixel, launching a Quickshell config per keypress:

| Stage | Cost |
| --- | --- |
| Empty layer surface, nothing in it | ~5 ms |
| Qt/QML engine startup | ~145 ms |
| Decoding the 5120×2880 wallpaper JPEG | ~190 ms |
| **Total** | **~340 ms** |

That is visible as lag, and neither of the two large terms can be avoided *per
launch*. The only fix is to pay them once.

**`sourceSize` on the wallpaper is a pessimisation, not an optimisation.**
Asking the `Image` for a smaller decode measured **slower** — Qt still parses
the whole JPEG and then adds a smooth scale on top. Do not retry this.

## 3. `keepLoaded` replaces an entire hand-rolled daemon

The standalone predecessor was a resident `qs -d -p` process with a Bash wrapper
in front of it. Everything in that wrapper existed to reimplement what the
plugin host already provides, and all of it is now deleted:

| Hand-rolled | Replaced by |
| --- | --- |
| `qs -d -p` daemon | the shell mounting the plugin |
| `autostart.lua` entry (`sleep 2 && launchpad daemon`) | `keepLoaded: true` |
| `flock` around every invocation | nothing — there is one mount |
| socket liveness probe | nothing |
| `~/.local/bin/launchpad` toggle wrapper | `omarchy-shell shell toggle <id>` |

It also removes a second Qt process from the session. The traps that wrapper
existed to dodge are recorded here because they are real and undiscoverable, and
because anyone porting *from* such a setup will meet them:

- **`qs -d -p` does not refuse to start a second instance.** It starts one, and
  `qs ipc` then talks to the oldest while the newer sits there invisible. Two
  quick keypresses were enough to do it, hence the lock.
- **Liveness cannot be `pgrep`.** The daemon's command line keeps its flags
  (`qs -d -p <config>`), so a `qs -p <config>` pattern does not match it and the
  wrapper launches a second, foreground instance on every keypress. Probe the
  IPC socket instead.
- **The daemon inherits the lock fd** unless it is closed (`9>&-`), and being
  long-lived it then holds the `flock` forever, deadlocking every later
  invocation.
- **An `IpcHandler` function must not be called `show`.** `qs ipc` has its own
  subcommands — `show`, `call`, `wait`, `listen`, `prop` — and its parser claims
  those words wherever they appear, so `qs ipc call launchpad show` never
  reaches the object: it prints the function list and exits **0**, silently.

## 4. Plugin contract

- **`close()` must not call `shell.hide()`.** The shell calls `close()` when
  *it* closes the plugin, so calling back recurses until the stack is exhausted
  — and because the exception aborts the close, the overlay is left **stuck on
  screen covering everything**. Closing on our own initiative (Escape, backdrop,
  launching something) goes through a separate `dismiss()`, which does both.
- **`opened` must be the intent, not the on-screen state.** The shell reads it
  to decide what `toggle` means.
- **Default `shown` to false.** A plugin that shows itself on load flashes the
  whole grid across the screen at every login.

## 5. Being resident changes what has to be reset

The QML tree outlives any one opening, so anything the user left behind is still
there next time. Launchpad always opens on page one with an empty search box, so
both are reset — on **open**, not on hide, where a stale frame of the reset could
be visible.

**Focus has to be taken back explicitly.** The layer surface is torn down on
hide and the `TextInput` loses focus with it; without `forceActiveFocus()` on
reopen, typing goes nowhere from the second opening onwards.

## 6. Paging

The grid is a `ListView` with `interactive: false`, and paging is driven by
panel-level handlers. This is deliberate:

- With `SnapOneItem` + `StrictlyEnforceRange`, a free drag has to cross **half a
  page** to commit. On a 5K screen that is an enormous sweep; anything less slid
  a little and sprang back. The explicit version commits at **one twelfth** of
  the screen width.
- A self-flicking `ListView` fights the panel handlers and swallows their
  events, hence `interactive: false`.

**`WheelHandler.orientation` defaults to `Qt.Vertical` and silently drops
horizontal wheel events.** That is why a sideways two-finger swipe did nothing
while an up/down one paged fine. Two handlers are needed, one per axis.

**A touchpad scroll is a burst, not a notch.** Deltas are accumulated and a page
turns once the total passes 120. That alone is not enough: the tail of a single
flick kept re-crossing the threshold and ran to the last page, so a `paging`
latch swallows the rest of the gesture and only clears after 300 ms of quiet.
One physical swipe, one page.

**Backdrop dismissal is a `TapHandler`, not a `MouseArea`.** A `MouseArea` grabs
the press, and the `DragHandler` then never sees a swipe. Pointer handlers
cooperate — a drag simply is not a tap.

## 7. Do not let the compositor do the blur

The background is blurred **in QML**, on the wallpaper `Image`, with a dark tint
over it.

A `blur = true` Hyprland layer rule on a full-screen layer makes hyprbars' title
bars flicker between transparent and coloured whenever they redraw, and
`decoration:blur:new_optimizations = false` is **not** enough to stop it.
Blurring the image ourselves keeps Hyprland's blur machinery out of it entirely,
so there is nothing left to flicker.

**The wallpaper loads synchronously on purpose.** Asynchronous loading painted
the icon grid first and blurred the background a beat later, which read as the
window opening in two steps. A local JPEG costs a few ms and, mounted, is paid
once rather than per opening.

## 8. Untrusted input

A `.desktop` file is not a trusted document. Anything that can write to
`~/.local/share/applications` — an installer, an extracted archive, a script the
user ran once — chooses the `Name` and `Icon` strings, and they arrive in a
long-lived process that owns the whole shell surface.

| Input | Sink | Guard |
| --- | --- | --- |
| `entry.name` | `Text.text` | `textFormat: Text.PlainText`, capped at 128 chars |
| `entry.icon` (absolute path) | `Image.source` as `file://` | rejected if it contains `..`; only honoured from the entry itself |
| `entry.icon` (theme name) | `Quickshell.iconPath` | must match `^[A-Za-z0-9][A-Za-z0-9._+-]*$`, ≤128 chars |
| `entry.id` | `execDetached` argv | must match the same filename shape, ≤255 chars |

Two of these are worth spelling out:

- **QML `Text` defaults to `Text.AutoText`**, which sniffs the string for HTML
  and switches to rich text when it finds any — and rich text follows markup
  into resource handling. A name is data, never markup.
- **The length cap is applied at the point of display**, not left to `elide`.
  Eliding only stops the string being *drawn*; the whole thing is still laid
  out.

Rejected values fall back to a generic icon or to doing nothing, rather than
being sanitised. There is nothing to salvage in a hostile value when a generic
icon is a perfectly good answer.

The Omarchy marketplace's automated security review **does not read QML** — it
scans manifests and shell scripts. None of the above will be pointed out for
you.

## 9. `shell` is null during `Component.onCompleted`

The host injects `shell` and `manifest` as properties **after** the object is
constructed, so a probe in `Component.onCompleted` reports `shell=null` and
concludes, wrongly, that the plugin cannot reach the session's services. React
to `onShellChanged`, or evaluate lazily through a binding, as `appLibrary` and
`canUninstall` do here.

Measured during bring-up: `Component.onCompleted` → `shell=null`;
`onShellChanged` → `shell=yes appLibrary=yes remove=yes launch=yes`.

## 10. Uninstall is delegated, not implemented

`shell.appLibrary` is the session-wide application service — the same object the
bar menu and Omarchy's own launcher use — and it is reachable from a third-party
plugin, on the same injected object as `shell.hide()`.

`appLibrary.remove(desktopId, name)` runs
`$OMARCHY_PATH/bin/omarchy-remove-launcher-entry`, which sorts out for itself
whether the entry is:

| Kind | What happens |
| --- | --- |
| web app | `omarchy-webapp-remove` |
| terminal wrapper (`$TERMINAL … -e`) | `omarchy-tui-remove` |
| a file under `~/.local/share/applications` | plain `rm` + `update-desktop-database` |
| owned by a package (`pacman -Qqo`) | a floating terminal running `sudo pacman -Rns` |
| a Flatpak | a floating terminal running `flatpak uninstall` |

So the plugin contains no `sudo`, no package manager, and no shell string, and
the password prompt happens in a terminal the user can see. A plugin that
shelled out to `sudo pacman -Rns` itself would deserve to be rejected; this is
the same action, delegated to the first party that owns it.

Omarchy's own launcher already exposes this on the **Delete** key with a confirm
dialog. Launchpad does not bind Delete, because it has no keyboard selection
model — the search box always holds focus and there is no "current" icon for a
key to act on. Right-click is the only trigger.

## 11. What the conversion actually saved

Measured on this machine, PSS (RSS overstates it — the two processes share Qt's
libraries):

| | PSS |
| --- | --- |
| omarchy-shell + standalone launchpad daemon | 417 MB + 293 MB = **710 MB** |
| omarchy-shell with the plugin mounted | **511 MB** |

**~199 MB**, one sample each, taken shortly after a shell restart with the grid
opened once so the wallpaper was decoded in both cases. What is saved is the
duplicated QML engine, scene graph and GPU context — not Launchpad's own data,
which still exists, just in the other process.

## 12. Jiggle mode, and why the badge is a `MouseArea`

The first version put uninstall on a right-click straight into a confirm dialog.
It worked and looked wrong — a modal card is a menu's answer to the question,
and Launchpad's answer is a *mode*. So: hold an icon (450 ms) and the grid
wobbles with a remove badge on every app, the way macOS does. Right-click enters
the same mode, because holding a mouse button to edit is not a gesture anyone
tries on a desktop.

Two things this design has to get right:

- **Anything that is not a badge leaves the mode**, including clicking an icon.
  Launching out of jiggle mode would mean the click meant to stop editing also
  started something.
- **One shared phase drives the whole grid.** Each tile binds
  `rotation: 1.6 * sin(phase + offset)` with the offset derived from its index,
  so neighbours are out of step — in lockstep it reads as the grid sliding
  rather than each icon being loose. Binding rather than animating per tile also
  means leaving the mode returns every icon to level for free; thirty separate
  animations would be thirty things to stop, each frozen at whatever angle it
  had reached.

**The badge must be a `MouseArea`, not a `TapHandler`.** It sits inside the
tile, which has a `TapHandler` of its own, and pointer handlers *cooperate*
rather than block — both fire, so clicking the badge also counted as tapping the
icon and dropped straight back out of edit mode. A `MouseArea` takes the press
exclusively. This is the same property that made a `MouseArea` the **wrong**
choice for the backdrop, where a drag still has to reach the `DragHandler`:
grabbing is the point in one case and the bug in the other.

## 13. Verified end to end

Both removal branches were exercised on a live system:

- a hand-written entry under `~/.local/share/applications` — removed with a
  plain `rm`, no prompt, no package touched
- `tigervnc`, a pacman-owned application — the floating terminal opened, asked
  for the password, and `pacman -Rns` took the package **and five orphaned
  dependencies** (`xorg-xsetroot`, `xorg-xinit`, `xorg-xrdb`, `xorg-xmodmap`,
  `fltk1.3`) with it

That cascade is worth knowing about: uninstalling one application can remove
several packages. It is `-Rns` doing its job, it is Omarchy's choice rather than
this plugin's, and the terminal lists everything before the user confirms.
