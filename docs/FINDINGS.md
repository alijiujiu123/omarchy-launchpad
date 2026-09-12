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
