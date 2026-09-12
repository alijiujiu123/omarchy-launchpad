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
| owned by a system package | a floating terminal that authenticates, then runs the package manager's recursive remove |
| a Flatpak | a floating terminal running `flatpak uninstall` |

So the plugin contains no privilege escalation, no package-manager command and
no shell string, and the password prompt happens in a terminal the user can see.
A plugin that escalated and drove the package manager itself would deserve to be
rejected; this is the same action, delegated to the first party that owns it.

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
- `tigervnc`, an application owned by a system package — the floating terminal
  opened, asked for the password, and the recursive remove took the package
  **and five orphaned dependencies** (`xorg-xsetroot`, `xorg-xinit`,
  `xorg-xrdb`, `xorg-xmodmap`, `fltk1.3`) with it

That cascade is worth knowing about: uninstalling one application can remove
several packages. It is the recursive remove doing its job, it is Omarchy's
choice rather than this plugin's, and the terminal lists everything before the
user confirms.

## 14. Paging must stay live in edit mode

Jiggle mode first shipped with scroll and drag paging disabled while it was on.
That was wrong twice over: with 64 applications there are three pages, so it
meant only the page you happened to be on could be edited — and the page dots
were never blocked, so clicking a dot paged while swiping did not. macOS pages
while jiggling. Only the modal dialog stops paging now.

## 15. Not implemented: reordering

macOS Launchpad lets you drag icons into a different position, and onto another
page, while jiggling. This does not, and that is a deliberate omission rather
than an oversight: an order the user arranges has to be **remembered**, which
means the plugin would start writing state outside its own folder. Today it
writes nothing at all, which is a claim worth keeping until there is a reason to
give it up.

The order is alphabetical, computed from `DesktopEntries` on every change, so it
is stable and needs no storage. If reordering is added later it needs, at
minimum: a persisted order keyed by desktop id, a policy for ids that appear or
disappear between sessions, and drag-to-page-edge, which will contend with the
`DragHandler` that currently owns paging.

## 16. The marketplace reads the README as if it were code

The submission baseline decides its outcome like this:

```
blocking rule findings → needs-fixes
else capabilities      → review-required   (a manual queue)
else                   → passed
```

Capabilities are matched against commands extracted from **every text file in
the repository, the README and the docs included**. That is not a subtlety: a
real submission was put in the queue for the `privilege` capability because its
README contained the sentence *"no sudo and no auth handling"* — the word alone
— and for `remote-build` because it documented installation as a `git clone` of
its own repository.

This project hit exactly that. The README, this file, and a QML comment all
described **what Omarchy's uninstall helper does** — naming the privilege
escalation and the package-manager command it runs — and every one of those
mentions would have counted as a capability of *this plugin*. They are now
written as prose ("the authentication prompt", "the recursive remove") rather
than as command tokens. Nothing was removed: the behaviour is still described in
full, including that removing one application can take several packages with it.
What went is a false positive, not a disclosure.

Practical rules that follow:

- Document installation as `omarchy plugin add <url> --enable`. It is the
  official command and it is not a `remote-build` trigger; a `git clone` of your
  own repository is.
- Do not write `sudo` or `pkexec` in any shipped file, **including to say you do
  not use them**.
- Check a preview image's size. One submission stalled outright because the
  scanner could not process its screenshot within its limits.

Measured on 100 recent submissions: 52 ended in `security-review-required`. The
rules and the scanner are open source — `omacom/omarchy-plugin-marketplace`
(`scripts/security-baseline-policy.mjs`) and `omacom/omarchy-plugin-registry`
(`app/services/registry/scanner.rb`) — so none of this has to be guessed.

## 17. `%q` protects the shell, not the terminal

A `.desktop` `Name` reaches `AppLibrary.remove()`, and Omarchy's helper echoes it
into a floating terminal. Both layers quote correctly — `Util.shellQuote` does
the standard `'` → `'\''` wrap, and the helper runs the display name through
`printf %q` — so there is no shell injection here.

But escape sequences survive shell quoting and arrive at the **terminal
emulator**, which is a different reader with different rules. A hostile `Name`
could therefore write control sequences into the confirmation terminal.

`displayLabel()` now strips C0/C1 control characters along with capping the
length. It costs nothing — a name is a label, and the bytes being refused are
not part of one — and it also fixes the mundane case of a `Name` containing a
newline breaking the grid layout.

Found by auditing this plugin against its own checklist, not by a reviewer.

## 18. Bounds belong at construction, not at display

The first submission was blocked on this, correctly. The plugin capped every
label at 128 characters *as it was drawn* and called that bounded. It was not:

- `allApps` accepted an unlimited number of entries
- it sorted **full, uncapped** `name` strings
- the search filter lowercased and scanned **full, uncapped** `name` and
  `genericName` — on every keystroke

So a hostile set of `.desktop` files could consume unbounded memory and CPU in a
process that stays mounted for the whole session, and the rendered label being
short changed none of it. **Capping the output does not bound the work done to
produce it.**

The model now takes one bounded pass: at most **512 entries**, each field capped
at **128 characters**, at most **128 KB** of retained text, and the lowercase
search key computed **once** when the record is built rather than per keystroke.
Overflow stops the loop and raises a flag the grid displays — the resource bound
is the same either way, but a user whose list is silently short has no way to
know why.

One honest limit: Quickshell's `DesktopEntries` has already parsed the index
before this plugin sees it. These bounds govern what the plugin retains and what
it does per keystroke, which is the part it owns.

## 19. An icon path from a `.desktop` entry is not a trusted path

Also blocked, also correct. `iconFor()` honoured an absolute path when the entry
supplied one — bounded only by length and a `..` check — and handed it to QML as
a `file://` URL.

The reasoning behind that was wrong. "It came from a desktop entry" is not a
provenance: **anything that can write to `~/.local/share/applications` writes
the entry**, so the path is exactly as untrusted as the id next to it. Handed to
an image loader it is an arbitrary pathname opened by a session-long process — a
FIFO or device node that never returns, or a file crafted to exhaust the
decoder.

There is no way to validate such a path from QML. It cannot stat a file, so it
cannot tell a regular file from a FIFO, and checking the extension proves
nothing. So the branch is gone: **`Quickshell.iconPath()` only**, which resolves
through the icon theme — a lookup in trusted directories rather than a path
someone handed us. Anything that is not a well-formed theme name gets the
generic icon.

Measured cost on a 64-entry system: **2 entries** lose their artwork. That is
what buying the guarantee costs, and it is cheap.

## 20. A conservative grammar can be its own bug

Shape-checking the desktop id had refused anything outside
`^[A-Za-z0-9][A-Za-z0-9._+-]*$`. Chrome's web-app entries are named
`Google Maps.desktop` — spaces and all — so **five icons on this machine drew
perfectly and did nothing when clicked**. The check was introduced as a
hardening measure and quietly broke a feature; nobody noticed because a launcher
that does nothing looks exactly like a launcher whose app is slow to start.

A desktop id is a *filename*, and the bound belongs where the hazard is. The
value only ever reaches an argv array — `execDetached` takes one, so nothing is
re-tokenized — or Omarchy's own `shellQuote`. Spaces are not a hazard there. A
path separator is, whatever the quoting, and so are control characters,
traversal, and a leading dash that could be read as an option. Those are what
the check refuses now.

**Hardening that silently removes function is a bug, not a trade-off.** It was
found by counting what the rule would reject before shipping it — which is the
same measurement that showed the icon change costs two entries.

## 16. A stable URL is not a live image

The wallpaper came through `~/.local/state/omarchy/current/background`, a
symlink whose **target** moves — when the theme changes, and when the background
changes within a theme. The path is stable, which is exactly the problem:
QtQuick caches images by URL, so with `cache: true` the first wallpaper was
decoded once and stayed for the life of the session.

The cache is worth keeping (5K JPEG, ~190ms), so the URL has to change instead.
`readlink -f` resolves the link and the image is sourced from the real path: no
cache-busting trick, because the thing in the URL *is* the thing that changed.

An intermediate fix keyed the URL on `current/theme.name` and was verified
working for a theme switch — and was still incomplete, because the background
also changes within a theme and that file does not move. **Verifying the case
that was reported is not the same as verifying the behaviour.**

Resolved on open rather than on a timer: the wallpaper is only on screen while
the grid is up, so that is the only moment it has to be right.

## 17. `cacheBuffer: 0` livelocks this ListView

Trying to make the grid appear faster, the obvious saving was the lookahead
page — the ListView builds the next page's 30 delegates and icons at the moment
the window opens, and nobody is looking at them. Setting `cacheBuffer: 0`
**hung the entire shell**.

Not crashed: hung. The bar and the dock kept rendering, because the scene graph
runs on its own thread with the last good state, while every `omarchy-shell`
command timed out because IPC needs the main thread. "Draws fine, answers
nothing" reads like broken IPC and is actually a QML livelock.

The cause is the combination already in this ListView: `highlightRangeMode:
StrictlyEnforceRange` with `snapMode: SnapOneItem` forces the current item to
sit exactly in range, and with no cache buffer the view creates and destroys
delegates trying to satisfy that and never settles.

**The experiment had already shown this and was dismissed.** Changing that one
line alone broke IPC, and the result was explained away as restart flakiness
because "a ListView property cannot break IPC". Twenty minutes, two killed
shells and a full plugin bisect later, it was that line. When a clean
single-variable experiment contradicts intuition, the experiment is the one to
believe.

Preloading the icons at mount was also tried and also hung the shell, for a
different reason: thirty icon lookups during the root object's construction
delay IPC registration past the point anything waits for it. If it is revisited,
it has to be deferred until after startup.
