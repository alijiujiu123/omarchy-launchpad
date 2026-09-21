// Launchpad -- a macOS-style application grid for Omarchy.
//
// A full-screen page of app icons over the blurred desktop, with a
// search pill at the top and page dots at the bottom. Type to filter, swipe or
// scroll to page, click to launch.
//
// The page is a fixed rows x columns shape and every other dimension -- cell,
// icon, label, paddings -- derives from it and the screen. That is what makes
// it read as Launchpad rather than as a generic app menu, and it is why there
// is one window per screen: a 5K monitor and a laptop panel each size their own
// grid instead of sharing one pixel-fixed icon size. nwg-drawer was the first
// attempt and could not do any of those three things.
//
// 7 x 5, and that is macOS's own shape on a laptop panel: Apple's help
// screenshot of Launchpad measures seven columns, five rows, with the icons
// about 0.70 of the column pitch. Six columns was what this plugin shipped with
// first, and at 6 x 5 on a 1440 x 900 panel the cell is 211 x 144 -- so the
// icon could only be 42% of the 211-wide pitch it sat in, and the page read as
// a sparse grid floating in the middle of the screen with the margins either
// side of it empty. Seven columns at the same height puts the cell much closer
// to square (195 x 154) and the icon at 55% of the pitch, which is the most a
// 16:10 screen allows once five rows, the search band and the dots have taken
// their share. Bigger icons, closer together: that is what fills the page.
//
// This is an `overlay` plugin with keepLoaded: true, so the shell mounts it at
// startup and it stays mounted. That is not a detail. An earlier standalone
// version launched per keypress and took ~340ms before anything appeared, of
// which ~145ms was Qt/QML starting up and ~190ms was decoding Omarchy's
// 5120x2880 wallpaper -- neither avoidable per launch, and giving the Image a
// smaller sourceSize measured *slower*, because Qt still parses the whole JPEG
// and then adds a scale on top. Mounted once, a toggle is ~80ms.
//
// Being resident is also why several things below reset explicitly rather than
// relying on construction: the QML tree outlives any one opening.
//
// Paging runs on the kit's motion engine. `~/.config/omarchy/motion/` (installed
// by the `motion` module) is the algebra the three-finger workspace swipe is
// tuned from: the page follows the fingers 1:1, the release is decided by *where
// the motion would have come to rest* -- v^2/2a on a recency-weighted velocity,
// the half-over rule, a per-event flick threshold, a travel floor -- and
// whatever is not committed settles back on the machine's own curve (100 x
// `speed` ms on `momentumSettle`, the same bezier `looknfeel.lua` gives
// `workspaces`). None of that is re-implemented here: MotionMath.js is imported
// from the engine and the gesture's parameters are written in its vocabulary
// (`dist`, `cancel`, `force`, `decel`, `window`, `floor`, `speed`). A page turn
// and a workspace swipe travel the same distance in the same time, which is the
// point of sharing it.
//
// What it replaced was an accumulator: a two-finger scroll summed deltas until
// they passed one notch and then jumped a whole page, and a drag committed at a
// twelfth of the screen without the page ever moving under the hand. That is
// the same job done with none of the feel.

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
// The motion engine's shell half. Relative on purpose: Quickshell's package
// tree is read-only and blackholes anything outside it, so this is the only way
// a plugin reaches the engine -- the same relative import the engine's own
// MotionFollow uses, and the arrangement `modules/motion` documents.
import "../../motion/MotionMath.js" as MM

Item {
  id: root

  // --- plugin contract ----------------------------------------------------
  // Set by the shell's Loader when this plugin is mounted.
  property var shell: null
  property var manifest: null

  // What the user last asked for, as opposed to what is on screen. The shell
  // reads this to decide what `toggle` means, so it has to be the intent.
  property bool opened: false

  // Called by the shell on summon. The payload is accepted and ignored -- there
  // is only one thing this plugin does -- but the signature is the contract.
  // --- which screen -------------------------------------------------------
  // macOS puts Launchpad on the display you are working on, not on every one at
  // once. Refreshed on open rather than tracked continuously: a keep-loaded
  // plugin can sit idle for hours, and the answer only matters at the moment it
  // is summoned.
  //
  // Empty means Hyprland has not told us yet -- in that case every screen shows
  // it, which is the old behaviour and a better failure than none showing it.
  property string activeScreen: ""

  function refreshActiveScreen() {
    Hyprland.refreshMonitors()
    const monitor = Hyprland.focusedMonitor
    root.activeScreen = monitor ? String(monitor.name || "") : ""
  }

  function open(payloadJson) {
    // Already up: do nothing at all. This used to refresh the backdrop
    // unconditionally, and refreshing clears `backdropSettled` -- which is one
    // of the conditions on the panel being visible, so the layer surface
    // unmapped for a frame and remapped, replaying the entire entrance. What
    // that looked like was the grid jumping every time the opening gesture was
    // repeated over a grid that was already open.
    if (root.shown && !root.closing)
      return
    root.refreshActiveScreen()
    root.refreshBackdrop()
    root.setShown(true)
  }

  // Called by the shell when IT closes us (`omarchy-shell shell hide <id>`).
  // Must NOT call back into shell.hide(), or the two bounce off each other
  // until the stack is exhausted -- and because the exception aborts the close,
  // the overlay is left stuck on screen covering everything.
  function close() {
    root.setShown(false)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // Closing on our own initiative -- Escape, a click on the backdrop, launching
  // something. Tells the shell too, so its open-plugin bookkeeping does not go
  // on thinking we are up; without this the next toggle would try to hide an
  // already-hidden grid and appear to do nothing.
  function dismiss() {
    root.setShown(false)
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.andyweiboan.launchpad")
  }

  // --- page shape ---------------------------------------------------------
  // macOS's own shape for a laptop panel, and every other dimension -- cell,
  // icon, label, the bands -- derives from these two and the screen, which is
  // what keeps it sharp on both monitors. See the header for why seven.
  readonly property int columns: 7
  readonly property int rows: 5
  readonly property int perPage: columns * rows

  // --- paging: one page of travel, and how a release decides --------------
  // The motion engine's parameter names and meanings (compare `M.params` in
  // ~/.config/hypr/motion.lua and `motion`'s own output), with the units chosen
  // so that BOTH inputs this page accepts are the same quantity: the fraction of
  // a page the content has moved. That is what makes `cancel` (the half-over
  // rule) mean "half a page" for a two-finger scroll and for a pointer drag
  // alike, without either of them needing its own thresholds.
  //
  // MEASURED, not derived. `angleDelta` is not the compositor's delta: Qt
  // reports a trackpad's continuous axis events as angleDelta units about an
  // order of magnitude larger, and hypr-scroll-momentum's "client units" (which
  // this machine's own notes quote) are the compositor's. Guessing the scale is
  // what made the first version of this paging turn a page on a touch, so the
  // numbers below come from a recorded stream of real gestures (a temporary log
  // in `scrolled()`, three reference gestures and a simulation of them):
  //
  //   gesture                        travel      per-event peak
  //   a light short touch             61 units     40
  //   a quick short swipe            677          131
  //   a normal swipe, "one page"    1974           58
  //   a deliberate flick        1188 - 4653   244 - 535
  //
  //   unitsPerPage 2000 — one page is what a deliberate swipe to turn one page
  //               actually accumulates (1974 measured). The value this replaced
  //               was 120, inherited from the old accumulator: 6% of a real
  //               swipe, which is exactly why every touch committed.
  //   dist       1.0 — one page, because travel is already in pages
  //   cancel     0.5 — the half-over rule: half a page travelled commits, which
  //               is 1000 units. A light touch (61) and a quick short swipe
  //               (677) are below it; the reference swipe (1974) and every
  //               flick are above it.
  //   force      0.075 — one event moving 150 units may decide on its own (the
  //               flick rule). That sits between the peaks of ordinary gestures
  //               (40-131) and of deliberate flicks (244-535), so a flick
  //               commits on the flick rule even when its travel is short.
  //   floor      0.1 — a tenth of a page, the engine's proportion (60 of its
  //               centre's 600): 200 units, so a light touch is not a decision
  //               at all. It still follows — 3% of a page — and springs back.
  //   decel      300 pages/s² — a flick's own speed (20-30 pages/s measured)
  //               projects well past half a page even from a short travel. On
  //               this path, though, the release is *inferred* from a quiet
  //               stream, so the velocity has already decayed by the time it is
  //               measured and the peak above carries most of the flick intent:
  //               the client's honest stand-in for a release the compositor
  //               would have seen.
  //   window     80 — ms, the recency-weighted velocity window (events arrive
  //               7-8ms apart, so this is about ten of them)
  //   speed      5 — the machine's settle speed: 100 x 5 = 500ms on the
  //               `momentumSettle` bezier, exactly what `looknfeel.lua` gives
  //               `workspaces`, so a page turn and a workspace swipe settle in
  //               the same time over the same distance
  //   unitsPerPageWheel 120 — a MOUSE wheel is a different unit again: one
  //               detent is 120 angleDelta on the nose, so a notch is a page.
  //               Read per event (`event.device`), because the two devices
  //               report quantities that are not comparable:
  //               the choice is "a notch" vs "a movement"
  readonly property var paging: ({
    dist: 1.0,
    cancel: 0.5,
    force: 0.075,
    decel: 300,
    window: 80,
    floor: 0.1,
    speed: 5,
    unitsPerPage: 2000,
    unitsPerPageWheel: 120
  })

  // What one page is, for the device that produced this event. A wheel detent
  // arrives as 120 whatever the trackpad's scale is, so the wheel needs its own
  // normaliser -- and it is not a fudge factor: the two are different
  // quantities, and each is converted to "pages" with the number measured for it.
  function unitsFor(device) {
    return (device && device.type === PointerDevice.Mouse)
      ? root.paging.unitsPerPageWheel
      : root.paging.unitsPerPage
  }

  // --- state --------------------------------------------------------------
  // Starts hidden. A plugin that shows itself on load flashes the whole grid
  // across the screen at every login.
  property bool shown: false

  // --- motion ---------------------------------------------------------------
  // Outside in. macOS brings the grid down into place from larger than the
  // screen, so the icons arrive from beyond the edges and contract onto their
  // cells, rather than swelling up out of the middle. Every exit reverses it
  // and goes back outward; a launch simply travels further than a dismiss, so
  // opening an app reads as passing through the grid rather than putting it
  // away.
  //
  // `shown` cannot be the close signal, because it is what unmaps the layer
  // surface -- flipping it would take the thing being animated off the screen
  // on the first frame. So a close sets this instead, the panels animate, and
  // `shown` goes false once the animation has had its time.
  property bool closing: false

  // Two timings, because the blur and the grid are not the same material. The
  // mist gathers and disperses on its own, slower and without ever scaling --
  // in macOS the background never zooms, only the icons do. The grid rides on
  // top of it, a little quicker, so the icons have arrived by the time the
  // backdrop finishes settling and have gone before it finishes thinning.
  //
  // Both exits taper rather than accelerate. Fading out on an accelerating
  // curve puts most of the alpha in the last few frames, which is not a fade
  // at all -- it is the overlay being switched off, and it reads as a flash.
  // SHARED WITH MISSION CONTROL. These four are the desktop's motion
  // vocabulary, not this plugin's private taste, and the sibling overlay is
  // timed off the same three rules:
  //
  //   Arriving takes longer than leaving -- 320 in, 240 out.
  //   The atmosphere outlives the content -- the mist runs 380/340 against the
  //     grid's 320/240, so the last thing on screen is a dissolve, not a cut.
  //   Translations accelerate away; fades taper.
  //
  // Retiming any of them here means retiming Mission Control to match, and the
  // other way round. Two overlays on one desktop that move at different speeds
  // read as two programs, which is exactly what they are and exactly what they
  // should not look like.
  readonly property int openDuration: 320
  readonly property int closeDuration: 240
  readonly property int mistInDuration: 380
  readonly property int mistOutDuration: 340
  // Small numbers on purpose. The travel only has to be enough to read as
  // movement -- at a page this size, six percent of the screen is already a
  // long way for an icon in a corner, and anything more starts to look like
  // the grid is being thrown rather than placed.
  readonly property real enterScale: 1.06
  readonly property real dismissScale: 1.05
  readonly property real launchScale: 1.12
  // Reset on every open, so the forward exit belongs to launch() alone.
  property real exitScale: root.dismissScale

  Timer {
    id: closeTimer
    // The surface has to outlive the SLOWEST of the two, or the mist is cut
    // off mid-disperse, which is the flash again by another route.
    interval: Math.max(root.closeDuration, root.mistOutDuration)
    // `shown` first. Clearing `closing` while the panel is still on screen
    // would look to the panels exactly like being re-summoned mid-close.
    onTriggered: { root.shown = false; root.closing = false }
  }

  // --- backdrop -----------------------------------------------------------
  //
  // The wallpaper -- SHARP, and blurred later in the panel, because the radius
  // has to be a number this plugin can animate. A pre-blurred copy, or the
  // compositor's blur, is one fixed amount of blur: it can only be faded up,
  // which looks like the blur appearing rather than gathering.
  //
  // This plugin still never opens the wallpaper.
  //
  // A check that ends before a read cannot bind what the read consumes: the
  // state link, and whatever it points at, can be replaced in between. Three
  // rounds of security review on this plugin and its sibling ended there, and
  // the answer is not a stricter check. It is to decode the untrusted bytes
  // somewhere they can only cost a short-lived process, and to hand QML
  // something the plugin made itself.
  //
  // `bin/backdrop` resolves the link, refuses anything that is not a bounded
  // regular file, and re-encodes a bounded 1280x800 JPEG into our own cache
  // directory under ImageMagick resource limits and a timeout. The only
  // pathname an image loader sees here is that output. A hostile wallpaper
  // costs the helper a timeout and leaves the previous backdrop on screen.
  readonly property string pluginDir:
      Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  // $XDG_RUNTIME_DIR, never a path under $HOME -- see the note in bin/backdrop.
  // Empty when there is no runtime directory, which leaves backdropVersion at 0
  // and the bundled backdrop on screen.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string cacheDir:
      root.runtimeDir ? root.runtimeDir + "/omarchy-launchpad" : ""
  // 0 means "no backdrop rendered yet", and the bundled fallback shows instead.
  property int backdropVersion: 0
  // Monotonic, so a URL is never reused after the file behind it changed.
  property int backdropRenders: 0
  readonly property string backdropSource: root.backdropVersion > 0
      ? "file://" + root.cacheDir + "/backdrop.jpg?v=" + root.backdropVersion
      : ""

  // False from the moment an open is requested until the helper has told us
  // which backdrop this open gets. The surface waits for it.
  //
  // The common case costs nothing: an unchanged wallpaper is a stat and a
  // string compare, and the helper answers "cached" in single-digit
  // milliseconds. Only a wallpaper that actually changed pays the render, and
  // paying it BEFORE the overlay appears is better than appearing with the
  // previous wallpaper on screen and correcting it half a second later.
  property bool backdropSettled: false

  function refreshBackdrop() {
    if (!root.runtimeDir) { root.backdropSettled = true; return }
    root.backdropSettled = false
    backdropSettleWatchdog.restart()
    if (backdropProc.running) return
    backdropProc.running = true
    backdropWatchdog.restart()
  }

  // The overlay must open even if the helper never answers.
  Timer {
    id: backdropSettleWatchdog
    interval: 900
    repeat: false
    onTriggered: root.backdropSettled = true
  }

  Process {
    id: backdropProc
    // Absolute interpreter and a minimal environment: a bare command name
    // would be resolved through whatever PATH this process inherited, and this
    // plugin is mounted for the whole session.
    command: ["/bin/sh", root.pluginDir + "/bin/backdrop"]
    clearEnvironment: true
    environment: ({
      "HOME": Quickshell.env("HOME"),
      "XDG_RUNTIME_DIR": root.runtimeDir
    })
    // Line at a time, not all-at-exit: the helper reports "stale" before it
    // starts rendering, and acting on that is the whole point -- see below.
    stdout: SplitParser {
      onRead: function(line) {
        const result = String(line || "").trim();
        if (result === "stale") {
          // Still working. The surface keeps waiting.
          // The cached backdrop belongs to a wallpaper that is no longer the
          // wallpaper. Fall back to the bundled pane rather than show the
          // previous one for the few hundred milliseconds the render takes.
          root.backdropVersion = 0;
        } else if (result === "new") {
          root.backdropVersion = root.backdropRenders + 1;
          root.backdropRenders += 1;
          root.backdropSettled = true;
        } else if (result === "cached") {
          if (root.backdropVersion === 0) {
            root.backdropRenders += 1;
            root.backdropVersion = root.backdropRenders;
          }
          root.backdropSettled = true;
        }
      }
    }
  }

  // Nothing that runs automatically in a long-lived process should be able to
  // hang without a deadline, even one that already carries its own timeout.
  Timer {
    id: backdropWatchdog
    interval: 20000
    repeat: false
    onTriggered: if (backdropProc.running) backdropProc.running = false
  }

  // --- selection -----------------------------------------------------------
  // A flat index into `apps`, not a page-and-cell pair: paging is a view of one
  // list, and keeping the selection in the list's own coordinates means moving
  // right off the end of a page is the same arithmetic as moving right within
  // one. -1 when there is nothing to select.
  //
  // The mouse and the keyboard drive the SAME value. Hovering already drew a
  // highlight before any of this existed, and that highlight was decorative --
  // Enter launched apps[0] whatever it was sitting on, so the one piece of
  // feedback the grid gave about "this one" was the one thing it did not mean.
  // One state fixes that without inventing a second highlight to disagree with
  // the first.
  property int selected: 0

  // WHICH INPUT IS ALLOWED TO MOVE THE SELECTION, not which one is allowed to
  // draw. There is one highlight and it is always on `selected`, so Enter can
  // never disagree with what you are looking at; this only decides whether the
  // next hover or the next arrow key gets to move it.
  //
  // Doing it the other way -- letting each input draw its own highlight and
  // suppressing the other -- means that when the pointer is resting outside the
  // grid there is nothing highlighted at all, and Enter goes back to being a
  // guess.
  property bool pointerDriving: true

  function moveSelection(delta) {
    if (root.apps.length === 0) return;
    root.selected = Math.max(0, Math.min(root.apps.length - 1, root.selected + delta));
  }

  // Up and down are clamped to the page; left and right are not. Moving right
  // off the last cell lands on the next page's first, which is where the list
  // continues and where the eye expects it. Moving down off the bottom row
  // would land on the next page's TOP row -- the right index, the wrong
  // direction -- so it stops instead.
  function moveSelectionVertical(rowDelta) {
    if (root.apps.length === 0) return;
    const page = Math.floor(root.selected / root.perPage);
    const next = root.selected + rowDelta * root.columns;
    if (Math.floor(next / root.perPage) !== page) return;
    if (next < 0 || next >= root.apps.length) return;
    root.selected = next;
  }

  property string query: ""

  // Panels listen for this to clear their own search field and page index;
  // those live per-screen, so root cannot reach them directly.
  signal resetRequested()

  function setShown(next) {
    root.opened = next
    root.uninstallTarget = null
    root.editMode = false

    if (next) {
      // Summoned again while the close is still running: turn it round from
      // wherever it had got to instead of letting it finish and reopening.
      // The surface never unmaps, so hammering the key does not blink.
      const reversing = root.closing
      closeTimer.stop()
      root.closing = false
      if (root.shown && !reversing)
        return
      // A mounted plugin keeps whatever the user left behind. Reopening onto
      // the previous search text and page would be wrong -- Launchpad always
      // opens on page one with an empty box -- so reset here rather than on
      // hide, where a stale frame of the reset could be visible.
      root.query = ""
      root.selected = 0
      root.pointerDriving = true
      root.exitScale = root.dismissScale
      root.resetRequested()
      root.shown = true
      return
    }

    if (!root.shown || root.closing)
      return
    root.closing = true
    closeTimer.restart()
  }

  // --- application model --------------------------------------------------
  // DesktopEntries is Quickshell's own .desktop index, so installs and removals
  // are picked up live with no watcher of our own.
  //
  // EVERYTHING IS BOUNDED HERE, at construction, not at display. Capping a
  // label as it is drawn does nothing for the work already done to get it
  // there: an unbounded set would still be counted, sorted, lowercased and
  // re-filtered on every keystroke, inside a process that is mounted for the
  // whole session. A `.desktop` file is author-controlled -- anything that can
  // write to ~/.local/share/applications chooses these strings and how many of
  // them there are -- so the model takes a bounded copy and stops.
  //
  // Honest limit of this: Quickshell has already parsed the index by the time
  // we see it. These bounds govern what this plugin retains and what it does
  // per keystroke, which is the part it owns.
  readonly property int maxEntries: 512
  readonly property int maxFieldLength: 128
  readonly property int maxCatalogBytes: 131072

  // One pass produces the records AND the overflow flag. A separate binding
  // that recomputed the same loop to answer "did it overflow" would double the
  // work it is trying to bound.
  readonly property var catalog: {
    const items = [];
    const values = DesktopEntries.applications.values || [];
    let bytes = 0;
    let truncated = false;

    for (let i = 0; i < values.length; i++) {
      if (items.length >= root.maxEntries) { truncated = true; break; }

      const entry = values[i];
      if (!entry || entry.noDisplay)
        continue;

      // Bounded before it is looked at, the id check included.
      const id = String(entry.id || "").slice(0, root.maxFieldLength);
      if (!root.looksLikeDesktopId(id))
        continue;

      const name = root.displayLabel(entry.name);
      if (name.length === 0)
        continue;
      const generic = root.displayLabel(entry.genericName);
      const icon = String(entry.icon || "").slice(0, root.maxFieldLength);

      bytes += id.length + name.length + generic.length + icon.length;
      if (bytes > root.maxCatalogBytes) { truncated = true; break; }

      items.push({
        id: id,
        name: name,
        icon: icon,
        // Precomputed once. Lowercasing every name on every keystroke was the
        // per-character cost the bound is meant to remove.
        sortKey: name.toLowerCase(),
        search: (name + " " + generic).toLowerCase()
      });
    }

    items.sort((a, b) => a.sortKey.localeCompare(b.sortKey));
    return { items: items, truncated: truncated };
  }

  readonly property var allApps: root.catalog.items
  readonly property bool catalogTruncated: root.catalog.truncated

  // Typing filters in place, the way Launchpad's search does. Every field this
  // touches was bounded and lowercased when the record was built.
  readonly property var apps: {
    const q = root.query.trim().toLowerCase();
    if (q.length === 0)
      return root.allApps;
    return root.allApps.filter(entry => entry.search.indexOf(q) !== -1);
  }

  // Typing is a new question, so it gets a new answer: the best match is the
  // first one, and that is what Enter should take.
  onAppsChanged: root.selected = 0

  readonly property int pageCount: Math.max(1, Math.ceil(root.apps.length / root.perPage))

  // --- untrusted values ---------------------------------------------------
  // A .desktop file is not a trusted document. Anything that can write to
  // ~/.local/share/applications -- an installer, an extracted archive, a
  // Flatpak, a script the user ran once -- chooses these strings, and they
  // arrive in a long-lived process that owns the whole shell surface. Three
  // rules, all applied at the point of use:
  //
  // 1. `textFormat: Text.PlainText` on every sink that shows a name. A QML Text
  //    defaults to Text.AutoText, which sniffs the string for HTML and switches
  //    to rich text when it finds any -- and rich text follows markup into
  //    resource handling. A name is data, never markup.
  // 2. A documented length cap, applied here rather than relying on elide.
  //    Eliding only stops it being *drawn*; the whole string is still laid out.
  // 3. An icon value is honoured as a path only when it is an absolute path
  //    from the entry itself, and as a theme name only when it looks like one.
  //    Anything else is refused rather than sanitised -- a generic icon is a
  //    perfectly good answer, so there is nothing to salvage.
  readonly property int maxLabelLength: 128
  readonly property int maxIconNameLength: 128
  readonly property int maxIconPathLength: 512

  // Control characters are stripped, not just capped. The name is displayed in
  // QML, where a newline breaks the layout -- but it is also handed to
  // AppLibrary.remove(), and Omarchy's uninstall helper echoes it into a
  // floating terminal. `printf %q` protects the SHELL from it, and it does so
  // correctly, but escape sequences survive that and reach the terminal
  // emulator, which is a different reader with different rules. A name is a
  // label; nothing is lost by refusing the bytes that are not.
  function displayLabel(value) {
    const text = String(value || "").replace(/[\u0000-\u001F\u007F-\u009F]/g, "");
    return text.length > root.maxLabelLength
      ? text.slice(0, root.maxLabelLength) + "…"
      : text;
  }

  function looksLikeIconName(value) {
    return value.length > 0
        && value.length <= root.maxIconNameLength
        && /^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(value)
        && value.indexOf("..") === -1;
  }

  // THEME NAMES ONLY. An earlier version honoured an absolute path when the
  // desktop entry supplied one, on the reasoning that the entry was a local
  // file the session had installed. That reasoning is wrong: anything that can
  // write to ~/.local/share/applications writes the entry too, so the path is
  // as untrusted as the id. Handed to QML as a file:// URL it becomes an
  // arbitrary pathname opened as an image by a process that is mounted for the
  // whole session -- a FIFO or device node that never returns, or a file
  // crafted to exhaust the decoder.
  //
  // Quickshell.iconPath resolves through the icon theme, which is a lookup in
  // trusted directories rather than a path we were handed, so the only value
  // that can reach the loader is one the theme itself produced. There is no
  // safe way to validate an arbitrary path from QML -- it cannot stat the file,
  // so it cannot tell a regular file from a FIFO -- and a generic icon is a
  // perfectly good answer.
  //
  // Cost, measured on a 64-entry system: 2 entries lose their artwork.
  function iconFor(entry) {
    const fallback = Quickshell.iconPath("application-x-executable", true);
    const name = String((entry && entry.icon) || "");
    if (!root.looksLikeIconName(name))
      return fallback;
    const themed = Quickshell.iconPath(name, true);
    return themed.length > 0 ? themed : fallback;
  }

  // A desktop file id is a FILENAME, so it is bounded by what a filename may
  // be -- not by a conservative identifier grammar. Chrome's web-app entries
  // are named "Google Maps.desktop", spaces and all, and an id grammar that
  // refused them left five icons on this machine that drew fine and did
  // nothing when clicked.
  //
  // What actually has to be refused: a path separator, traversal, control
  // characters, and a leading dash that could be read as an option. The value
  // only ever reaches an argv array (execDetached takes one, so nothing is
  // re-tokenized) or Omarchy's own shellQuote, so spaces are not a hazard
  // there; a slash is, whatever the quoting.
  function looksLikeDesktopId(value) {
    return value.length > 0
        && value.length <= 255
        && !/[\u0000-\u001F\u007F\/\\]/.test(value)
        && value.indexOf("..") === -1
        && /^[A-Za-z0-9_]/.test(value);
  }

  // The shell injects its own AppLibrary, which owns launching and removal for
  // the whole session -- the bar menu and the launcher go through the same
  // object. Using it rather than rolling our own means launch feedback appears
  // where the user expects it and, for removal, that no privileged code lives
  // in this plugin at all.
  //
  // NOTE: `shell` is null during Component.onCompleted -- the host injects it
  // after construction -- so anything that needs it must react to
  // onShellChanged or be evaluated lazily, as these are.
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  readonly property bool canUninstall: !!(root.appLibrary
      && typeof root.appLibrary.remove === "function")

  // Launch through uwsm-app + gtk-launch, the same path Omarchy's own menu
  // uses: it keeps apps out of the compositor's systemd scope and copes with
  // desktop ids containing dots. Keep the .desktop suffix, or ids like
  // org.telegram.desktop fail to resolve. AppLibrary does exactly this and adds
  // the session's launch feedback; the direct call is the fallback for a host
  // that does not provide it.
  function launch(entry) {
    const id = String((entry && entry.id) || "");
    if (!root.looksLikeDesktopId(id))
      return;
    const name = String((entry && entry.name) || "");
    if (root.appLibrary && typeof root.appLibrary.launch === "function")
      root.appLibrary.launch(id, name);
    else
      Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", id + ".desktop"]);
    // Further out than a dismiss, so the grid opens onto the app instead of
    // merely getting out of the way. The app itself is already on its way.
    root.exitScale = root.launchScale;
    root.dismiss();
  }

  // --- uninstall ----------------------------------------------------------
  // Right-click an icon to remove the application. macOS does this with a
  // long-press into jiggle mode and an X badge; right-click is the same idea
  // in a form that does not fight with drag-to-page.
  //
  // The work is entirely Omarchy's: AppLibrary.remove() runs
  // `omarchy-remove-launcher-entry`, which decides for itself whether the entry
  // is a webapp, a terminal wrapper, a user-written .desktop file, a system
  // package or a Flatpak, and where elevated rights are needed it opens a
  // floating terminal so the authentication prompt is visible to the user. This
  // plugin therefore contains no privilege escalation, no package-manager
  // command and no shell string -- which is the difference between delegating a
  // privileged action and performing one.
  //
  // Snapshot the id, name and icon at request time: the grid re-filters live,
  // so the entry under the cursor is not guaranteed to still be there when the
  // dialog is answered.
  property var uninstallTarget: null

  // macOS's jiggle mode: hold an icon and the whole grid starts wobbling with a
  // remove badge on every app, until you click away. It is a mode, not a menu,
  // which is why a long press enters it and anything else leaves it.
  property bool editMode: false

  // One animation drives the whole grid; each tile reads this and offsets by
  // its own index. Thirty separate animations would be thirty things to stop,
  // and stopping them would leave each tile at whatever angle it had reached --
  // binding to a shared phase means turning editMode off snaps everything back
  // to zero for free.
  property real wigglePhase: 0

  NumberAnimation on wigglePhase {
    running: root.editMode
    loops: Animation.Infinite
    from: 0
    to: 2 * Math.PI
    duration: 360
  }

  // Typing is a request to find something, not to keep editing.
  onQueryChanged: root.editMode = false

  function requestUninstall(entry) {
    if (!root.canUninstall)
      return;
    const id = String((entry && entry.id) || "");
    if (!root.looksLikeDesktopId(id))
      return;
    root.uninstallTarget = {
      id: id,
      name: String((entry && entry.name) || ""),
      icon: root.iconFor(entry)
    };
  }

  function cancelUninstall() {
    root.uninstallTarget = null;
  }

  // Escape backs out one layer at a time -- dialog, then jiggle mode, then
  // Launchpad itself. Collapsing these would mean a stray Escape closed the
  // whole thing while the user was only trying to dismiss an alert.
  function back() {
    if (root.uninstallTarget) root.cancelUninstall();
    else if (root.editMode) root.editMode = false;
    else root.dismiss();
  }

  function confirmUninstall() {
    const target = root.uninstallTarget;
    root.uninstallTarget = null;
    if (!target || !root.canUninstall)
      return;
    root.editMode = false;
    root.appLibrary.remove(target.id, target.name);
    // Close: removal may open a terminal for the password, and that must not
    // come up behind a full-screen overlay holding exclusive keyboard focus.
    root.dismiss();
  }

  // --- surfaces -----------------------------------------------------------
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"

      // Hiding tears down the layer surface but keeps the QML tree, which is
      // what makes reopening cheap.
      // Waits for the backdrop DECISION, not for the backdrop itself: the
      // helper is a subprocess, so unlike an Image inside this window it does
      // not need the window mapped first. Once it has answered, a 160 KB JPEG
      // decodes inside a frame -- and opening before it answered would mean
      // starting the haze on last week's wallpaper.
      visible: root.shown && root.backdropSettled
               && (root.activeScreen === ""
                   || String(panel.modelData.name || "") === root.activeScreen)

      // Overlay layer so it covers the bar too, exclusive keyboard focus so
      // typing goes to the search box without a click first. The namespace is
      // stable so a user layer rule has something to match on.
      WlrLayershell.namespace: "launchpad"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore

      // The entrance hangs off `visible` rather than off root.shown, because
      // `visible` is the one that means the surface is actually on screen --
      // root.shown is also true through the whole of a close.
      //
      // The pose is set here rather than left to the stage's initial values,
      // because the stage is reused: the last close left it at an exit scale,
      // and after a launch that scale is larger than full size.
      onVisibleChanged: {
        if (!panel.visible) {
          firstFrame.running = false
          return
        }
        exitAnim.stop()
        mistOut.stop()
        mist.opacity = 0
        mist.haze = 0
        stage.opacity = 0
        stage.scale = root.enterScale
        // NOT started here. Mapping a layer surface, allocating the blur's
        // buffers and uploading the icon textures costs ~100ms on this machine,
        // every time, because the surface is torn down on every hide. Started
        // at this point the animation clock ran through all of it with nothing
        // on screen, so the first frame anyone actually saw was already a
        // quarter of the way in -- the entrance did not begin, it arrived
        // partly done. Measured: first rendered frame at t+74ms to t+101ms
        // across every open, then a further 28-40ms gap, then full refresh rate
        // the rest of the way.
        firstFrame.running = true
      }

      // Ticks on rendered frames, so the first tick is proof that the surface
      // is actually producing them. One tick is all it takes.
      FrameAnimation {
        id: firstFrame
        running: false
        onTriggered: {
          firstFrame.running = false
          mistIn.start()
          enterAnim.start()
        }
      }

      Connections {
        target: root
        function onClosingChanged() {
          if (!panel.visible)
            return
          if (root.closing) {
            enterAnim.stop()
            mistIn.stop()
            exitAnim.start()
            mistOut.start()
          } else if (root.opened) {
            // Re-summoned mid-close. The `opened` test is what separates that
            // from the ordinary end of a close, where this clears a frame
            // after the surface went away.
            exitAnim.stop()
            mistOut.stop()
            enterAnim.start()
            mistIn.start()
          }
        }
      }

      // --- derived geometry -------------------------------------------------
      // From the SCREEN, not from the window. An unmapped PanelWindow is not
      // the size of the screen it belongs to: it reports 0x0 at the instant it
      // maps and collapses to Qt's 100x100 default while it is hidden. Every
      // dimension in here used to be derived from panel.width, so every
      // dimension changed twice per open -- and the one that mattered was
      // iconSize, which swung between its 32px floor and 79px. That is each
      // icon's sourceSize, so all thirty Images were reloaded from scratch on
      // every single open: measured here, the first icon settled 65ms after
      // the surface appeared and the last one 300ms after. The grid arriving a
      // tile at a time was not slow loading, it was this. The ListView, sized
      // to nothing in between, was destroying and rebuilding all 162 delegates
      // on top of it.
      //
      // The screen does not resize when our window is hidden, so nothing below
      // moves and nothing is reloaded.
      readonly property real screenW: panel.modelData ? panel.modelData.width : panel.width
      readonly property real screenH: panel.modelData ? panel.modelData.height : panel.height

      // Bands and margins, all as fractions of the screen so both monitors size
      // their own page. What changed from the 6 x 5 layout, and why:
      //
      //   sidePad   6%  -> 2.5%. The macOS screenshot's outer margin and ours
      //             were already the same order of magnitude; the emptiness was
      //             never the margin, it was the icon-to-pitch ratio. Tightening
      //             it further is what buys the extra pitch that makes the cells
      //             near square.
      //   searchBand 13% -> 9.5% and dotsBand 7% -> 5%. Twenty percent of the
      //             height was reserved for a 32px pill and an 8px row of dots.
      //             Every point taken back here goes into cellH, and cellH is
      //             what caps the icon on a 16:10 panel.
      readonly property real sidePad: Math.round(panel.screenW * 0.025)
      readonly property real searchBand: Math.round(panel.screenH * 0.095)
      readonly property real dotsBand: Math.round(panel.screenH * 0.05)
      readonly property real gridW: panel.screenW - sidePad * 2
      readonly property real gridH: panel.screenH - searchBand - dotsBand
      readonly property real cellW: gridW / root.columns
      readonly property real cellH: gridH / root.rows
      // Both terms are live on this machine, which is what makes it stable
      // across screens rather than tuned to one: on a 1440 x 900 panel
      // (cellW 195, cellH 154) the width term wants 107 and the height term
      // wants 108, so the icon is 107 either way. The width term is what stops
      // a very wide, short screen from making cells wider than they are tall.
      //
      // 0.55 of the pitch, against macOS's 0.70: the rest of that ratio is the
      // label and the gap under it. Five rows on a 16:10 panel do not leave
      // room for both a macOS-sized icon and its name -- and the name is worth
      // more here, because Linux entries are longer than macOS's.
      readonly property int iconSize: Math.max(32, Math.round(Math.min(cellW * 0.55, cellH * 0.70)))
      readonly property int labelSize: Math.max(10, Math.round(iconSize * 0.15))
      // NO wallpaper image, and no blur of our own. The compositor blurs
      // whatever is actually behind this surface -- windows included -- which is
      // both closer to what macOS does and the only version of this that opens
      // no files at all.
      //
      // The previous design loaded Omarchy's wallpaper and blurred it in QML. It
      // worked, and it cost three rounds of security review: reading a file
      // whose path something else controls means checking it, and a check that
      // ends before the read cannot bind what the read consumes. The way to win
      // that argument is not to have the file.
      //
      // Needs a layer rule for the `launchpad` namespace (install/looknfeel.lua)
      // and blur enabled globally. `ignore_alpha` there must stay BELOW this
      // rectangle's alpha or the compositor decides the surface is too
      // transparent to blur behind and the effect disappears.

      // --- the mist -----------------------------------------------------------
      // The wallpaper, blurred HERE, because the radius has to be something the
      // plugin can animate. Neither of the other two ways of getting a blurred
      // backdrop can do that: a pre-blurred copy from the helper is one fixed
      // amount of blur, and the compositor's own blur is a property of the
      // layer -- it is on or it is off, there is no half of it. Both of them
      // can only be faded up, and a blur that fades up at full strength reads
      // as the blur appearing rather than the room filling with it.
      //
      // Deliberately OUTSIDE the stage: the blur is the room the icons are
      // standing in. It does not zoom with them and it does not share their
      // opacity.
      Item {
        id: mist
        x: 0
        y: 0
        width: panel.screenW
        height: panel.screenH
        opacity: 0

        // 0 is the wallpaper as it is, 1 is full haze. Driven by animation
        // rather than bound to anything, so an opening that is interrupted can
        // be turned round from wherever it had reached.
        property real haze: 0

        // Same per-frame follow as the stage, and the blur needs it more: its
        // radius is blended out of a few downsampled buffers, so stepping the
        // value straight from the touchpad shows up as the blur changing in
        // stages rather than continuously.
        Behavior on opacity {
          enabled: spread.tracking
          NumberAnimation { duration: 70; easing.type: Easing.OutQuad }
        }
        Behavior on haze {
          enabled: spread.tracking
          NumberAnimation { duration: 70; easing.type: Easing.OutQuad }
        }

        // Latched, not read live: the Image reloads whenever these delegates
        // move between windows, and without the latch the fallback would flash
        // back under the blur on every open. Same reason as the tiles.
        property bool haveWallpaper: false

        // Bundled fallback, underneath: a frosted pane that owes nothing to the
        // machine it is running on. It is what shows before the first render
        // finishes, and what stays if the helper ever declines. Already frosted,
        // so it is not put through the blur.
        Image {
          anchors.fill: parent
          source: Qt.resolvedUrl("assets/frost.jpg")
          fillMode: Image.PreserveAspectCrop
          cache: true
          visible: !mist.haveWallpaper
        }

        Image {
          id: wallpaper
          anchors.fill: parent
          source: root.backdropSource
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          retainWhileLoading: true
          onStatusChanged: if (status === Image.Ready) mist.haveWallpaper = true
          // MultiEffect draws it. Drawn itself as well, the sharp copy would
          // show through the blurred one.
          visible: false
        }

        MultiEffect {
          anchors.fill: parent
          source: wallpaper
          visible: mist.haveWallpaper
          blurEnabled: true
          // The ceiling, in the effect's own units. Raising it costs mip
          // levels, so it is set at what full haze should look like rather
          // than left somewhere generous.
          blurMax: 40
          blur: mist.haze
          // The source already covers the screen edge to edge. Padding it would
          // only add transparent margin for the blur to drag inwards, which
          // shows up as darkening at the edges.
          autoPaddingEnabled: false
        }

        // Enough dim for white labels to survive a bright wallpaper. On top of
        // the blur rather than baked into the helper's output: one number, in
        // one place, and not itself smeared.
        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(0.02, 0.03, 0.06, 0.34)
        }

        // Opacity and haze together. Fading a sharp wallpaper up over the real
        // one would be a double exposure; blurring one that is already at full
        // strength would be a pane sliding in. Doing both at once is the only
        // one of the three that looks like the screen misting over.
        ParallelAnimation {
          id: mistIn
          NumberAnimation {
            target: mist; property: "opacity"; to: 1
            duration: root.mistInDuration; easing.type: Easing.OutQuad
          }
          NumberAnimation {
            target: mist; property: "haze"; to: 1
            duration: root.mistInDuration; easing.type: Easing.OutQuad
          }
        }

        // OutCubic: thins quickly at first and then trails away, which is what
        // mist dispersing looks like. The last of it is spread over enough
        // frames that there is no moment where it stops being there. The haze
        // lifts with it, so the wallpaper is sharpening as it goes rather than
        // holding full blur until the surface is torn down.
        ParallelAnimation {
          id: mistOut
          NumberAnimation {
            target: mist; property: "opacity"; to: 0
            duration: root.mistOutDuration; easing.type: Easing.OutCubic
          }
          NumberAnimation {
            target: mist; property: "haze"; to: 0
            duration: root.mistOutDuration; easing.type: Easing.OutCubic
          }
        }
      }

      // --- open and close motion ---------------------------------------------
      // Everything the user sees hangs off one item, so the page can be grown
      // in and sent out as a single object the way macOS does it -- one scale
      // about the centre of the screen with a fade riding along. Per tile it
      // would be thirty transforms and would still not read as one page
      // arriving; as a group it is a single node in the scene graph, which is
      // what makes it free on a surface this size.
      //
      // The compositor is told not to animate this layer
      // (install/looknfeel.lua), so these are the only timings in play.
      // Hyprland's own layer fade would otherwise multiply into this one and
      // the entrance would arrive through treacle.
      Item {
        id: stage
        x: 0
        y: 0
        // Sized to the screen rather than filled to the window, for the reason
        // in the geometry block above: anchored to a window that collapses to
        // 100x100 while hidden, this would take the whole grid down with it.
        width: panel.screenW
        height: panel.screenH
        transformOrigin: Item.Center
        opacity: 0
        scale: root.enterScale

        // While the fingers are driving, every change follows over a frame or
        // two instead of landing in one. The input is not the problem -- the
        // touchpad reports at 125Hz against a 120Hz panel, measured, so there
        // is already about one sample per frame. What is coarse is what the
        // samples are put through: the fade curve is steepest at the very start
        // of the gesture, where a one-percent change in finger distance is
        // worth several percent of opacity, and MultiEffect's blur is blended
        // out of a handful of downsampled buffers, so a continuously changing
        // radius steps as it crosses between them.
        //
        // A short follow absorbs both, because it interpolates per FRAME rather
        // than per event. Enabled only while tracking: the entrance and exit
        // animations drive these same properties, and a behaviour underneath
        // them would be a second animation on the same value.
        Behavior on opacity {
          enabled: spread.tracking
          NumberAnimation { duration: 70; easing.type: Easing.OutQuad }
        }
        Behavior on scale {
          enabled: spread.tracking
          NumberAnimation { duration: 70; easing.type: Easing.OutQuad }
        }

        // Neither animation declares `from`: an exit can begin from a
        // half-finished entrance and a re-summon from a half-finished exit,
        // and in both cases the honest starting point is wherever the stage
        // actually is. The entrance pose is set instead by whoever starts it.
        ParallelAnimation {
          id: enterAnim
          NumberAnimation {
            target: stage; property: "opacity"; to: 1
            duration: root.openDuration; easing.type: Easing.OutQuad
          }
          // A trace of overshoot -- the contraction goes a little past its mark
          // and comes back, so the page settles rather than stops. Scaled down
          // with the travel: on a 6% entrance the old overshoot was most of the
          // movement again, which is where a bounce comes from.
          NumberAnimation {
            target: stage; property: "scale"; to: 1
            duration: root.openDuration
            easing.type: Easing.OutBack; easing.overshoot: 0.6
          }
        }

        ParallelAnimation {
          id: exitAnim
          NumberAnimation {
            target: stage; property: "opacity"; to: 0
            duration: root.closeDuration; easing.type: Easing.OutQuad
          }
          NumberAnimation {
            target: stage; property: "scale"; to: root.exitScale
            duration: root.closeDuration; easing.type: Easing.OutCubic
          }
        }


        // NO PINCH HANDLER HERE, and it is not for want of trying. The idea was
        // that the closing half of the gesture could follow the fingers: the
        // overlay is a mapped Wayland client holding pointer focus by then,
        // Hyprland advertises zwp_pointer_gestures_v1, and QtWayland turns that
        // into native gesture events, so a PinchHandler should have seen the
        // spread and been able to run the exit off it frame by frame.
        //
        // It never fired once. With a four-finger pinch registered in
        // Hyprland's own gesture config, the compositor's gesture manager takes
        // the whole pinch -- both directions -- and nothing reaches the client.
        // Measured, not assumed: logging on the handler's activeChanged stayed
        // silent across every open and close while the overlay was plainly
        // reacting to the gesture through the compositor's dispatch.
        //
        // So both halves are threshold triggers in install/gestures.lua, and
        // the animation is the plugin's own from beginning to end. Getting a
        // finger-tracked close back would mean giving up the compositor gesture
        // entirely and picking a finger count Hyprland is not watching.

        // Click anywhere that isn't an app to dismiss. A TapHandler rather than a
        // MouseArea: a MouseArea grabs the press and the DragHandler below would
        // never see a swipe. Handlers cooperate -- a drag simply isn't a tap.
        TapHandler {
          onTapped: root.back()
        }

        // --- paging: the engine's algebra ---------------------------------
        // Two inputs page this grid -- a two-finger scroll (or a wheel) and a
        // pointer/finger drag -- and both of them run the same state machine:
        // follow while the input moves, decide on release, settle on the
        // machine's curve. The quantities are in PAGES, so neither input needs
        // thresholds of its own; `root.paging` carries the parameters and why
        // they are what they are.
        //
        // True from the moment a page turn is asked for until the slide has
        // landed. Nothing that happens *because* the content is moving may
        // change the selection while this is set -- see the tile's HoverHandler.
        property bool turning: false

        // Set while the fingers are driving and until the settle has landed, so
        // a turn that is still in flight keeps the hover guard up.
        Timer {
          id: turnSettle
          interval: MM.settleMs(root.paging.speed) + 40
          onTriggered: stage.turning = false
        }

        // The gesture's state. Signed the way the input reports it -- positive is
        // content pulled to the right, i.e. toward the PREVIOUS page -- which is
        // the engine's own convention (the sign says which way the motion went,
        // the consumer reads the direction it cares about).
        property real travel: 0
        property real velocity: 0
        property real peak: 0
        property double lastEventMs: 0
        property bool gestureActive: false
        // Set when a decision has been taken and cleared only after the stream
        // has been quiet for a beat. A touchpad keeps sending kinetic events for
        // up to a second after the fingers lift: without this, the tail of the
        // swipe that just committed a page would start a fresh gesture and
        // commit another one. Only events big enough to be a finger still
        // driving extend it -- the same `force` number, from the same argument
        // the old `momentumFloor` was tuned by.
        property bool locked: false

        function pageWidth() { return Math.max(1, pages.width) }
        function maxContentX() { return Math.max(0, (root.pageCount - 1) * stage.pageWidth()) }

        function gestureStart(nowMs) {
          settleAnim.stop();
          stage.locked = false;
          lockTimer.stop();
          stage.gestureActive = true;
          stage.travel = 0;
          stage.velocity = 0;
          stage.peak = 0;
          stage.lastEventMs = nowMs;
        }

        // One event of the gesture. `deltaPages` is this event's travel as a
        // fraction of a page, whatever produced it.
        function gestureFeed(deltaPages, nowMs) {
          if (!stage.gestureActive)
            stage.gestureStart(nowMs);
          const dt = (stage.lastEventMs > 0 && nowMs > stage.lastEventMs) ? (nowMs - stage.lastEventMs) : 0;
          stage.travel += deltaPages;
          if (Math.abs(deltaPages) > stage.peak)
            stage.peak = Math.abs(deltaPages);
          // Recency-weighted velocity in pages per second, through the engine's
          // own exponential approach: the compositor half calls this
          // `advanceVelocity` with the same time constant, and MotionMath.js is
          // that same code written for the shell.
          if (dt > 0)
            stage.velocity = MM.approach(stage.velocity, deltaPages / (dt / 1000), dt, root.paging.window);
          stage.lastEventMs = nowMs;
          stage.turning = true;
          turnSettle.restart();
          stage.applyFollow();
        }

        // 1:1. The content moves with the input, which is the whole difference
        // between this and an accumulator.
        //
        // The travel is clamped to one page BEFORE it is applied, which is what
        // the engine's own `M.follow` does (`clamp(travel / dist, -1, 1)`): the
        // gesture's raw travel is kept for the decision, but the pixel it is
        // allowed to reach is one page either side of where the fingers started.
        // Clamping the VIEW instead -- to the first and last page -- let a long
        // flick, which really does travel several pages' worth of units, run the
        // content to the last page while the fingers were still moving.
        function applyFollow() {
          const w = stage.pageWidth();
          const progress = Math.max(-1, Math.min(1, stage.travel / root.paging.dist));
          pages.contentX = Math.max(0, Math.min(stage.maxContentX(),
                                               pages.currentIndex * w - progress * w));
        }

        // The release. Decided by where the motion WOULD have come to rest
        // rather than by where it stopped: the engine's projection, then its
        // half-over rule, its flick rule and its travel floor.
        function gestureRelease(nowMs) {
          if (!stage.gestureActive)
            return;
          stage.gestureActive = false;

          // The stretch between the last motion and the release counts as no
          // motion: a hand that came to rest before letting go must not commit
          // on stale velocity. (The compositor half does exactly this in
          // `onFinish`; here the release is inferred from a quiet stream, so the
          // same decay is what makes the inference honest.)
          let v = stage.velocity;
          if (stage.lastEventMs > 0 && nowMs > stage.lastEventMs)
            v = MM.approach(v, 0, nowMs - stage.lastEventMs, root.paging.window);

          const w = stage.pageWidth();
          const stay = () => stage.settleTo(pages.currentIndex * w, false);

          const projected = MM.projectDelta(stage.travel, v, root.paging.decel);
          if (MM.decide(stage.travel, projected, stage.peak, root.paging) === "stay") {
            stay();
            return;
          }

          // The direction is the SIGN OF THE PROJECTION, not of where the
          // fingers stopped -- the engine's `decide` returns its verdict by the
          // same rule. Positive travel is the previous page.
          const want = pages.currentIndex + (projected > 0 ? -1 : 1);
          if (want < 0 || want > root.pageCount - 1) {
            stay();
            return;
          }
          // The decision is latched for the length of the tail, and the settle
          // is the machine's own: 100 x speed ms on `momentumSettle`.
          stage.locked = true;
          lockTimer.restart();
          stage.settleTo(want * w, true);
        }

        // `turning` is on for a committed turn and off for a spring-back: the
        // hover guard exists to stop a moving page feeding the selection, and a
        // page that is only going back where it came from is not arriving
        // anywhere.
        function settleTo(targetX, committed) {
          if (committed) {
            stage.turning = true;
            turnSettle.restart();
          }
          settleAnim.stop();
          settleAnim.from = pages.contentX;
          settleAnim.to = targetX;
          settleAnim.duration = MM.settleMs(root.paging.speed);
          settleAnim.start();
        }

        function finishSettle() {
          const w = stage.pageWidth();
          const idx = Math.max(0, Math.min(root.pageCount - 1, Math.round(pages.contentX / w)));
          // The animation has already put the content where it belongs; these
          // only publish where that is. NoSnap, so neither assignment moves
          // anything -- the page index is what the dots and the selection read.
          pages.contentX = idx * w;
          pages.currentIndex = idx;
          stage.travel = 0;
          stage.velocity = 0;
          stage.peak = 0;
          stage.lastEventMs = 0;
          stage.gestureActive = false;
        }

        // A discrete turn: the keyboard, the dots, or the selection walking off
        // the edge of a page. No gesture behind it, so no decision -- straight to
        // the engine's settle, which is the same motion a committed swipe ends
        // with.
        function goTo(index) {
          const want = Math.max(0, Math.min(index, root.pageCount - 1));
          if (want === pages.currentIndex)
            return;
          stage.settleTo(want * stage.pageWidth(), true);
        }

        // A wheel event is already in units of travel, but *which* units depends
        // on the device that produced it: a mouse wheel counts in detents (120
        // to a notch) and a trackpad in movements about an order of magnitude
        // larger. `unitsFor` normalises each to one page, so everything
        // downstream stays in pages.
        function scrolled(delta, device) {
          // Paging stays live in edit mode -- macOS pages while jiggling, and
          // blocking it would mean you can only remove apps from whichever page
          // you happened to be on. Only the modal dialog stops it.
          if (root.pageCount <= 1 || root.uninstallTarget)
            return;

          const pages_ = delta / root.unitsFor(device);
          if (stage.locked) {
            // Inside the tail of a gesture that has already decided. Swallow it,
            // and only let something still driving hold the lock open.
            if (Math.abs(pages_) >= root.paging.force)
              lockTimer.restart();
            return;
          }
          releaseTimer.restart();
          stage.gestureFeed(pages_, Date.now());
        }

        // The release of an input that has no end event of its own: a wheel
        // stream simply stops. Short enough to feel immediate, long enough to sit
        // between the events of one burst (the touchpad's tail arrives at about
        // 8ms spacing).
        Timer {
          id: releaseTimer
          interval: 90
          onTriggered: stage.gestureRelease(Date.now())
        }

        // Outlasts the kinetic tail of the gesture that just committed -- the
        // value the old paging cooldown had tuned, for the same reason.
        Timer {
          id: lockTimer
          interval: 250
          onTriggered: stage.locked = false
        }

        NumberAnimation {
          id: settleAnim
          target: pages
          property: "contentX"
          // The machine's settle: the same four control points `looknfeel.lua`
          // hands Hyprland for `workspaces`, taken from the engine so the two
          // cannot drift.
          easing.type: Easing.Bezier
          easing.bezierCurve: MM.BEZIER
          onFinished: stage.finishSettle()
        }

        // Two handlers, because WheelHandler.orientation defaults to Qt.Vertical
        // and silently drops horizontal wheel events -- which is why a sideways
        // two-finger swipe did nothing while an up/down one paged fine. The
        // device goes through with the delta, because the units do (`unitsFor`).
        WheelHandler {
          orientation: Qt.Horizontal
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onWheel: event => stage.scrolled(event.angleDelta.x, event.device)
        }

        WheelHandler {
          orientation: Qt.Vertical
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onWheel: event => stage.scrolled(event.angleDelta.y, event.device)
        }

        // Click-and-drag / finger drag. The page follows the pointer 1:1 -- a
        // page of pointer travel moves the page a page -- and the release is the
        // same release: half a page travelled, or a projection that would have
        // carried it there.
        //
        // No flick path here, and that is deliberate rather than an omission:
        // `force` is a per-EVENT delta, and the number in `root.paging` was
        // measured on the touchpad's event stream (which reports at libinput's
        // rate). A pointer's events have no such calibration, so the drag commits
        // on travel and projection only.
        DragHandler {
          id: swipe
          target: null
          yAxis.enabled: false
          enabled: root.uninstallTarget === null
          property real lastX: 0
          onActiveChanged: {
            if (active) {
              lastX = centroid.position.x;
              stage.gestureStart(Date.now());
              return;
            }
            stage.gestureRelease(Date.now());
          }
          onCentroidChanged: {
            if (!active || !stage.gestureActive)
              return;
            const now = Date.now();
            const dx = centroid.position.x - lastX;
            lastX = centroid.position.x;
            stage.gestureFeed(dx / stage.pageWidth(), now);
          }
        }

        // --- search pill ------------------------------------------------------
        Rectangle {
          id: searchPill
          // One column wide, which is what macOS's own Launchpad search field
          // measures (Apple's help screenshot: about 1.1 column pitches), and
          // against the icon pitch rather than the screen -- so it stays the
          // same width as an icon column on any display.
          width: Math.round(panel.cellW)
          // From the screen, NOT from the band: the band is now only 9.5% tall
          // and a pill derived from it would have shrunk with it. 3.5% of the
          // height is a 32px pill on a 900px screen, which is what macOS has.
          height: Math.round(panel.screenH * 0.035)
          radius: height / 2
          anchors.horizontalCenter: parent.horizontalCenter
          y: Math.round(panel.searchBand * 0.34)
          color: Qt.rgba(1, 1, 1, 0.14)
          border.width: 1
          border.color: Qt.rgba(1, 1, 1, 0.18)

          Text {
            id: glass
            anchors.verticalCenter: parent.verticalCenter
            x: parent.height * 0.42
            text: "⌕"
            textFormat: Text.PlainText
            color: Qt.rgba(1, 1, 1, 0.65)
            font.pixelSize: Math.round(parent.height * 0.5)
          }

          TextInput {
            id: search
            anchors {
              left: glass.right; leftMargin: parent.height * 0.3
              right: parent.right; rightMargin: parent.height * 0.5
              verticalCenter: parent.verticalCenter
            }
            color: "#ffffff"
            font.pixelSize: Math.round(parent.height * 0.42)
            selectByMouse: true
            selectionColor: Qt.rgba(1, 1, 1, 0.25)
            focus: true
            onTextChanged: {
              root.query = text;
              pages.currentIndex = 0;
            }

            // Being mounted keeps this TextInput alive between openings, so it
            // has to be cleared and re-focused explicitly. Focus especially: the
            // layer surface is torn down on hide and the item loses focus with
            // it, and without taking it back typing would go nowhere on the
            // second opening.
            Connections {
              target: root
              function onResetRequested() {
                search.text = "";
                // JUMP TO PAGE ONE, do not slide to it. The engine owns the
                // view's position now, so this is two assignments -- and there
                // is no view animation left to zero around them. There used to
                // be: a grid closed on page three mapped showing page three and
                // then slid across to page one in front of you.
                //
                // The gesture's state is cleared with it, because a plugin that
                // stays mounted keeps whatever the last swipe left behind, and a
                // stale velocity is a decision waiting to be made about a page
                // the user has not touched.
                settleAnim.stop();
                stage.gestureActive = false;
                stage.locked = false;
                stage.travel = 0;
                stage.velocity = 0;
                stage.peak = 0;
                stage.lastEventMs = 0;
                stage.turning = false;
                pages.currentIndex = 0;
                pages.contentX = 0;
                search.forceActiveFocus();
              }
            }

            Keys.onEscapePressed: root.back()
            // Enter deliberately does nothing while the dialog is up. An alert
            // that uninstalls on the key the user was already pressing to launch
            // something is a trap; the answer has to be a deliberate click.
            function launchSelected() {
              if (root.uninstallTarget || root.editMode) return;
              const a = root.apps[root.selected];
              if (a) root.launch(a);
            }
            Keys.onReturnPressed: search.launchSelected()
            Keys.onEnterPressed: search.launchSelected()

            // Arrows move the selection. They used to turn pages, which left
            // the grid with a highlight it did not act on and no way to reach
            // anything but the first match from the keyboard.
            //
            // PAGING IS ON SHIFT + LEFT/RIGHT, and getting there took ruling out
            // everything that looks more obvious:
            //
            //   SUPER + arrows and CTRL + arrows never arrive. Hyprland handles
            //   its own keybinds before the focused client sees the key, and
            //   holding exclusive keyboard focus does not change that -- in this
            //   config SUPER + arrows is directional window focus and CTRL +
            //   arrows is desktop switching and Mission Control. Any modifier
            //   the compositor has claimed is simply unavailable in here.
            //
            //   PageUp/PageDown are still bound below, but they are not a real
            //   answer on this machine: an Apple laptop keyboard has no such
            //   keys, only Fn + up/down. Logging the key codes during a test
            //   showed Home and End arriving -- Fn + left/right -- which is what
            //   the hand actually reaches for.
            //
            // Plain SHIFT + arrows is the one arrow combination nothing upstream
            // claims; every arrow bind in `hyprctl binds` carries SUPER, CTRL or
            // ALT. It defers to the text box while there is text in it, the same
            // rule the unmodified arrows follow, because selecting text in the
            // filter is what Shift + arrow means everywhere else. Tab pages in
            // either state, so a filtered list is still reachable.
            function pageBy(delta) { stage.goTo(pages.currentIndex + delta) }

            // Tab and Backtab have DEDICATED Keys signals, and a key with a
            // dedicated signal never reaches Keys.onPressed. Handling them in
            // the switch below looked right and did nothing at all.
            Keys.onTabPressed: search.pageBy(1)
            Keys.onBacktabPressed: search.pageBy(-1)

            Keys.onLeftPressed: event => {
              if (search.text.length === 0 && (event.modifiers & Qt.ShiftModifier)) {
                search.pageBy(-1); return;
              }
              if (search.text.length > 0) { event.accepted = false; return; }
              root.pointerDriving = false; root.moveSelection(-1);
            }
            Keys.onRightPressed: event => {
              if (search.text.length === 0 && (event.modifiers & Qt.ShiftModifier)) {
                search.pageBy(1); return;
              }
              if (search.text.length > 0) { event.accepted = false; return; }
              root.pointerDriving = false; root.moveSelection(1);
            }
            Keys.onUpPressed: { root.pointerDriving = false; root.moveSelectionVertical(-1) }
            Keys.onDownPressed: { root.pointerDriving = false; root.moveSelectionVertical(1) }

            // No dedicated signal for these two, so this is where they land.
            Keys.onPressed: event => {
              switch (event.key) {
              case Qt.Key_PageUp:   search.pageBy(-1); event.accepted = true; break;
              case Qt.Key_PageDown: search.pageBy(1);  event.accepted = true; break;
              default: event.accepted = false;
              }
            }

            Text {
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              visible: search.text.length === 0
              text: "Search"
              textFormat: Text.PlainText
              color: Qt.rgba(1, 1, 1, 0.5)
              font.pixelSize: search.font.pixelSize
            }
          }
        }

        // --- paged grid -------------------------------------------------------
        ListView {
          id: pages
          anchors {
            left: parent.left; leftMargin: panel.sidePad
            right: parent.right; rightMargin: panel.sidePad
            top: parent.top; topMargin: panel.searchBand
          }
          height: panel.gridH

          orientation: ListView.Horizontal
          // NoSnap / NoHighlightRange, deliberately: this view is a viewport
          // now, and the engine owns where it is. Both of the snapping modes it
          // used to carry work against that -- SnapOneItem plus
          // StrictlyEnforceRange makes the view pull itself back to the current
          // item whenever that item is not comfortably in range, which is
          // exactly what a page being held half way between two of them is.
          // Paging was already driven explicitly (`interactive: false`); what is
          // new is that the position is driven explicitly too.
          snapMode: ListView.NoSnap
          highlightRangeMode: ListView.NoHighlightRange

          // The page and the selection stay on the same screen, in both
          // directions: moving the selection off the edge of a page turns it,
          // and turning a page by wheel, drag or dot moves the selection onto
          // it. Without the second half, paging away leaves Enter pointing at
          // something that is not on screen.
          //
          // Both handlers are idempotent -- each checks whether it has anything
          // to do before doing it -- so they settle instead of chasing each
          // other round.
          Connections {
            target: root
            function onSelectedChanged() {
              const want = Math.floor(root.selected / root.perPage)
              if (want !== pages.currentIndex) stage.goTo(want)
            }
          }

          onCurrentIndexChanged: {
            const first = pages.currentIndex * root.perPage
            if (root.selected < first || root.selected >= first + root.perPage)
              root.selected = Math.min(first, Math.max(0, root.apps.length - 1))
          }
          boundsBehavior: Flickable.StopAtBounds

          // Every page stays built. The default cacheBuffer is 320px against a
          // page 1330px wide, so only the page being looked at existed, and
          // turning to another one meant creating thirty tiles and thirty
          // Images inside the 220ms the turn was already animating. The turn
          // stuttered because of the work, and the icons arrived after it
          // because their loading is asynchronous -- which is the one thing
          // that cannot be negotiable here, since the whole point of a page of
          // icons is that it is there when you get to it.
          //
          // Paying for all of them once, at login, in a plugin that stays
          // mounted for the session is the right trade. It is not even new
          // memory: before the geometry was fixed this plugin was rebuilding
          // all 162 delegates on every single open. Now they are built once.
          cacheBuffer: Math.ceil(pages.width * root.pageCount)
          clip: true
          model: root.pageCount
          // Panel-level WheelHandler/DragHandler own paging; a self-flicking
          // ListView would fight them and swallow their events.
          interactive: false

          delegate: Item {
            id: page
            required property int index
            // Aliased because the tile delegate below declares its own `index`
            // for the wiggle offset, and the Repeater's model expression is
            // evaluated out here where the two names would collide.
            readonly property int pageIndex: index
            width: pages.width
            height: pages.height

            // Anchored to the TOP, not centred. A full page fills the grid area
            // exactly -- 5 rows of cellH is gridH -- so for those two the layouts
            // are identical. It only shows on the last page: centring left a
            // short final row floating in the middle of the screen, unrelated to
            // where every other page's first row starts.
            Grid {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.top: parent.top
              columns: root.columns
              rowSpacing: 0
              columnSpacing: 0

              Repeater {
                model: {
                  const start = page.pageIndex * root.perPage;
                  return root.apps.slice(start, start + root.perPage);
                }

                delegate: Item {
                  id: tile
                  required property var modelData
                  required property int index
                  width: panel.cellW
                  height: panel.cellH

                  // Neighbours must not wobble in lockstep -- that reads as the
                  // whole grid sliding rather than each icon being loose. The
                  // offset is derived from the index rather than randomised so a
                  // given icon wobbles the same way every time.
                  readonly property real wiggleOffset: (tile.index % 5) * 1.25

                  // Where this tile sits in `apps`, which is the coordinate the
                  // selection is kept in. The Repeater's index is per page.
                  readonly property int flatIndex: page.pageIndex * root.perPage + tile.index
                  readonly property bool isSelected: root.selected === tile.flatIndex

                  Rectangle {
                    anchors.fill: parent
                    anchors.margins: Math.round(panel.cellW * 0.06)
                    radius: Math.round(panel.iconSize * 0.22)
                    // The selection, not the hover. In pointer mode the two are
                    // the same tile because hovering moves the selection; in
                    // keyboard mode the pointer may be resting on something else
                    // entirely and that tile stays dark, which is the whole
                    // point of tracking who is driving.
                    color: tile.isSelected && !root.editMode ? Qt.rgba(1, 1, 1, 0.14)
                                                             : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                  }

                  Column {
                    id: face
                    anchors.centerIn: parent
                    spacing: Math.round(panel.iconSize * 0.14)

                    // The icon and its name appear together or not at all. Icons
                    // load asynchronously -- they have to, a synchronous grid of
                    // thirty would block the open -- but the label is painted
                    // immediately, so without this the names arrive first and the
                    // artwork flickers in underneath them. Fast, and wrong
                    // looking: the complaint was never the speed.
                    //
                    // A short fade rather than a hard switch, so a tile that does
                    // arrive late reads as settling rather than popping.
                    //
                    // The latch is what keeps this from firing again for the rest
                    // of the session. Hiding the overlay takes the delegates out
                    // of a window and putting them back moves them into a new
                    // one, and QQuickImageBase reloads on that move -- the device
                    // pixel ratio is allowed to differ between windows, so it
                    // cannot assume otherwise. Gated on status alone, every tile
                    // therefore dropped to nothing and faded back on every open,
                    // which is the grid looking like it was being read off disk.
                    // A tile that has once had its artwork keeps it.
                    property bool everLoaded: false
                    opacity: (tileIcon.status === Image.Ready || face.everLoaded) ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 110 } }

                    // Bound to the shared phase rather than animated per tile, so
                    // leaving edit mode returns every icon to level with no
                    // per-tile animation to stop. 1.6 degrees is small enough to
                    // stay legible and still obviously alive.
                    rotation: root.editMode
                      ? 1.6 * Math.sin(root.wigglePhase + tile.wiggleOffset)
                      : 0
                    Behavior on rotation {
                      enabled: !root.editMode
                      NumberAnimation { duration: 120 }
                    }

                    Item {
                      anchors.horizontalCenter: parent.horizontalCenter
                      width: panel.iconSize
                      height: panel.iconSize

                      Image {
                        id: tileIcon
                        anchors.fill: parent
                        source: root.iconFor(tile.modelData)
                        sourceSize.width: panel.iconSize
                        sourceSize.height: panel.iconSize
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                        // Keep the frame that is already on screen until the
                        // replacement is decoded, so the reload a hide/show
                        // cycle forces never shows through as a hole.
                        retainWhileLoading: true
                        onStatusChanged: if (status === Image.Ready) face.everLoaded = true
                        scale: tile.isSelected && !root.editMode ? 1.06 : 1.0
                        Behavior on scale { NumberAnimation { duration: 120 } }
                      }

                      // The remove badge, macOS's circled cross at the icon's top
                      // left. It only exists in edit mode, and it sits slightly
                      // outside the icon so it never covers artwork that matters.
                      Rectangle {
                        id: badge
                        width: Math.round(panel.iconSize * 0.34)
                        height: width
                        radius: width / 2
                        x: Math.round(-width * 0.30)
                        y: Math.round(-width * 0.30)
                        color: badgeHover.containsMouse ? "#e74c3c" : "#33363f"
                        border.width: Math.max(1, Math.round(width * 0.07))
                        border.color: Qt.rgba(1, 1, 1, 0.75)
                        visible: root.editMode && root.canUninstall
                        opacity: root.editMode ? 1 : 0
                        scale: root.editMode ? 1 : 0.4
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutBack } }
                        Behavior on color { ColorAnimation { duration: 100 } }

                        Text {
                          anchors.centerIn: parent
                          text: "\u2715"
                          textFormat: Text.PlainText
                          color: "#ffffff"
                          font.pixelSize: Math.round(badge.width * 0.52)
                          font.bold: true
                        }

                        // MouseArea, not a TapHandler. The badge sits inside the
                        // tile, which has a TapHandler of its own, and pointer
                        // handlers cooperate rather than block -- both would fire,
                        // so clicking the badge would also count as tapping the
                        // icon and drop out of edit mode. A MouseArea takes the
                        // press exclusively, which is exactly what is wanted here
                        // and exactly what made it the wrong choice for the
                        // backdrop, where a drag still has to get through.
                        MouseArea {
                          id: badgeHover
                          anchors.fill: parent
                          hoverEnabled: true
                          onClicked: root.requestUninstall(tile.modelData)
                        }
                      }
                    }

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      width: panel.cellW * 0.9
                      horizontalAlignment: Text.AlignHCenter
                      // Already bounded and control-stripped when the record was built.
                      text: tile.modelData.name
                      textFormat: Text.PlainText
                      color: "#ffffff"
                      font.pixelSize: panel.labelSize
                      elide: Text.ElideRight
                      maximumLineCount: 1
                      style: Text.Raised
                      styleColor: Qt.rgba(0, 0, 0, 0.6)
                    }
                  }

                  // Hovering hands the selection to the pointer. Guarded on
                  // `hovered` going true so that leaving a tile does not clear
                  // the highlight -- a pointer parked in a gap between icons is
                  // not a request to deselect.
                  //
                  // AND IGNORED WHILE A PAGE IS TURNING. Qt re-delivers hover
                  // when items move under a stationary cursor, so a turn walks
                  // thirty tiles past the pointer in 220ms and every one of them
                  // announces itself -- including tiles on the page being left.
                  // Taking the selection from one of those fed straight into the
                  // rule that keeps page and selection together, which turned the
                  // view round and slid it back. The page moved, sprang back, and
                  // paging felt like pushing against something. A pointer that
                  // has not moved is not hovering; the content is.
                  HoverHandler {
                    id: hover
                    onHoveredChanged: {
                      if (!hover.hovered || root.editMode || stage.turning) return;
                      root.pointerDriving = true;
                      root.selected = tile.flatIndex;
                    }
                  }

                  // In edit mode a plain click leaves the mode instead of
                  // launching. Launching out of jiggle mode would mean the click
                  // that was meant to stop editing also started something.
                  TapHandler {
                    // Hold to start editing, the way macOS does. Right-click gets
                    // there too, since holding a mouse button to edit is not a
                    // gesture anyone tries on a desktop.
                    longPressThreshold: 0.45
                    onLongPressed: if (root.canUninstall) root.editMode = true
                    onTapped: {
                      if (root.uninstallTarget) return;
                      if (root.editMode) root.editMode = false;
                      else root.launch(tile.modelData);
                    }
                  }

                  TapHandler {
                    acceptedButtons: Qt.RightButton
                    enabled: root.canUninstall
                    onTapped: root.editMode = true
                  }
                }
              }
            }
          }
        }

        // --- page dots --------------------------------------------------------
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          y: panel.searchBand + panel.gridH + Math.round(panel.dotsBand * 0.3)
          spacing: Math.round(panel.dotsBand * 0.22)
          visible: root.pageCount > 1

          Repeater {
            model: root.pageCount
            delegate: Rectangle {
              required property int index
              // From the screen, not the band: the band shrank with the layout
              // and 0.11 of it is now under the 6px floor. 0.9% of the height
              // is a 9px dot on a 900px screen, which is macOS's size.
              width: Math.max(6, Math.round(panel.screenH * 0.009))
              height: width
              radius: width / 2
              color: index === pages.currentIndex ? Qt.rgba(1, 1, 1, 0.95) : Qt.rgba(1, 1, 1, 0.35)
              Behavior on color { ColorAnimation { duration: 150 } }

              TapHandler { onTapped: pages.currentIndex = index }
            }
          }
        }

        // Fail loudly rather than quietly showing a partial list. The resource
        // bound is the same either way -- the model stopped consuming -- but a
        // user whose grid is silently short has no way to know why.
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Math.round(panel.dotsBand * 0.18)
          visible: root.catalogTruncated
          text: "Showing the first " + root.allApps.length
              + " applications — the rest were not loaded"
          textFormat: Text.PlainText
          color: Qt.rgba(1, 1, 1, 0.55)
          font.pixelSize: Math.max(10, Math.round(panel.labelSize * 0.9))
        }

        // --- uninstall confirmation ------------------------------------------
        // Plain MouseArea rather than pointer handlers here: this is a modal
        // surface whose whole job is to swallow input, which is exactly what a
        // MouseArea's grab does and what made it the wrong choice for the
        // backdrop above.
        Rectangle {
          id: scrim
          anchors.fill: parent
          z: 10
          visible: root.uninstallTarget !== null
          color: Qt.rgba(0, 0, 0, 0.5)

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: root.cancelUninstall()
          }

          // Compact on purpose. An alert is a question, not a page: a big card
          // with a big icon reads as the app being celebrated rather than
          // deleted, and it covers the grid the user is still orienting by.
          Rectangle {
            id: card
            anchors.centerIn: parent
            width: Math.min(Math.round(panel.screenW * 0.24), 400)
            height: body.implicitHeight + card.pad * 2
            readonly property int pad: Math.round(card.width * 0.065)
            radius: Math.round(card.width * 0.035)
            color: "#1b1e2b"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.14)

            // Swallows clicks so answering the dialog does not also hit the
            // scrim behind it and cancel.
            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

            Column {
              id: body
              anchors.centerIn: parent
              width: card.width - card.pad * 2
              spacing: Math.round(card.pad * 0.55)

              Image {
                anchors.horizontalCenter: parent.horizontalCenter
                source: (root.uninstallTarget && root.uninstallTarget.icon) || ""
                width: Math.round(card.width * 0.13)
                height: width
                sourceSize.width: width
                sourceSize.height: width
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Uninstall " + ((root.uninstallTarget && root.uninstallTarget.name) || "") + "?"
                textFormat: Text.PlainText
                color: "#ffffff"
                font.pixelSize: Math.round(card.width * 0.048)
                font.bold: true
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "If it needs root, a terminal will open for your password."
                textFormat: Text.PlainText
                color: Qt.rgba(1, 1, 1, 0.55)
                font.pixelSize: Math.round(card.width * 0.033)
                wrapMode: Text.Wrap
              }

              Item { width: 1; height: Math.round(card.pad * 0.35) }

              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Math.round(card.pad * 0.5)

                // Cancel first: the destructive answer should never be the one
                // the hand lands on by default.
                Rectangle {
                  width: Math.round((body.width - Math.round(card.pad * 0.5)) / 2)
                  height: Math.round(card.width * 0.085)
                  radius: Math.round(height * 0.32)
                  color: cancelHover.containsMouse ? Qt.rgba(1, 1, 1, 0.20)
                                                   : Qt.rgba(1, 1, 1, 0.11)
                  Behavior on color { ColorAnimation { duration: 100 } }

                  Text {
                    anchors.centerIn: parent
                    text: "Cancel"
                    textFormat: Text.PlainText
                    color: "#ffffff"
                    font.pixelSize: Math.round(card.width * 0.037)
                  }

                  MouseArea {
                    id: cancelHover
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.cancelUninstall()
                  }
                }

                Rectangle {
                  width: Math.round((body.width - Math.round(card.pad * 0.5)) / 2)
                  height: Math.round(card.width * 0.085)
                  radius: Math.round(height * 0.32)
                  color: removeHover.containsMouse ? "#e74c3c" : "#c0392b"
                  Behavior on color { ColorAnimation { duration: 100 } }

                  Text {
                    anchors.centerIn: parent
                    text: "Uninstall"
                    textFormat: Text.PlainText
                    color: "#ffffff"
                    font.pixelSize: Math.round(card.width * 0.037)
                    font.bold: true
                  }

                  MouseArea {
                    id: removeHover
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.confirmUninstall()
                  }
                }
              }
            }
          }
        }
      }

      // --- spread to close -----------------------------------------------------
      // Four fingers apart, tracked rather than triggered: the grid thins and
      // spreads with them, and letting go past the commit point carries that
      // straight on into the close instead of restarting it.
      //
      // PinchArea, NOT PinchHandler, and that distinction cost three wrong
      // diagnoses. A touchpad pinch arrives here as a Wayland native gesture --
      // zwp_pointer_gesture_pinch_v1, which Hyprland does forward to clients,
      // four fingers and all, even while its own gesture config is watching the
      // same pinch. PinchHandler never reacts to it: the newer pointer handlers
      // want touch points, and a native gesture has none. The older PinchArea
      // reads it directly. Measured side by side, same window, same gestures:
      // 370 events on PinchArea, 0 on PinchHandler.
      //
      // Outside the stage, so what it drives is not also what it is anchored to,
      // and sized like its siblings rather than filled to a window that
      // collapses to 100x100 while hidden.
      Item {
        id: spread
        x: 0
        y: 0
        width: panel.screenW
        height: panel.screenH

        // Progress NEVER saturates. The obvious mapping -- divide by a commit
        // scale and clamp -- looked right until the fingers went past it: a
        // spread reaches scale 4.6 on this touchpad, measured, while the clamp
        // was at 1.3, so for three quarters of the gesture the grid sat
        // perfectly still with the fingers still moving. That reads as the
        // animation stuttering at the end, which is what it was reported as,
        // and it is not dropped frames at all.
        //
        // p = d / (d + halfway) instead: a curve that approaches 1 without ever
        // arriving, so there is always somewhere further to go. `halfway` is
        // the spread at which it passes 0.5, and it is what sets the feel --
        // smaller means the grid answers sooner and then eases off.
        readonly property real halfway: 0.3
        // Deliberately LOW. The decision is not the interesting part of this
        // gesture -- a spread means close, and a hand that has started spreading
        // has already said so. Six percent of finger travel is enough to commit,
        // which is about where it stops being something you could have done by
        // accident. What is left after that is not a question still being asked:
        // it is the grid following the hand for as long as the hand is down, and
        // the animation finishing the journey the moment it lifts. Setting this
        // where a drag-to-dismiss would put it, near halfway, made every short
        // spread spring back -- correct by its own logic, and nothing like the
        // thing it was copied from.
        readonly property real commitAt: 0.1
        property real progress: 0
        property bool tracking: false
        // Latched the instant the threshold is crossed, and never cleared until
        // the next gesture. Reading progress at release instead looked right and
        // was wrong: lifting the fingers takes them off the pad one at a time,
        // so libinput reports the distance between them COLLAPSING back towards
        // 1.0 for the last few events before `end`. A quick release therefore
        // ended on a progress of nearly nothing, and a spread that had plainly
        // passed the threshold sprang back instead of closing. Rare, because it
        // needs the release to be fast enough to outrun the events -- and
        // baffling when it happened, because the gesture had visibly committed.
        //
        // Once the hand has said close, it has said it.
        property bool committed: false

        function progressFor(scale) {
          const d = Math.max(0, scale - 1);
          return d / (d + spread.halfway);
        }

        // THE ENTRANCE CANNOT BE TRACKED, and the reason is worth keeping
        // because it looked for a while as though it could. There is no surface
        // to send a gesture to until Hyprland's threshold has summoned one, so
        // the opening pinch necessarily starts somewhere else. The hope was
        // that it could be picked up in flight: the overlay takes pointer focus
        // when it maps, and a log did once show a pinch arriving right after
        // the panel appeared, scale re-based to 1.0 and heading downward.
        //
        // It was a different gesture. Timestamps settled it -- every such pinch
        // began between 682ms and 13s after the surface went up, while the
        // whole summon path, shell IPC included, measures 30ms. A continuation
        // would arrive within a frame. What the log had caught was a second
        // pinch, made after the first one ended.
        //
        // Hyprland does not re-issue `begin` to a surface that gains pointer
        // focus mid-gesture, and the protocol gives it no way to hand over one
        // already in progress. So the entrance is the compositor's threshold
        // and the plugin's own animation, and only the exit follows the hand.
        //
        // An inward pinch over an already-open grid therefore does nothing.
        // That is not a gap, it is the only honest answer: the gesture's whole
        // meaning is "open this", and it is already open.

        // 0 undecided, 1 spreading to close.
        property int dir: 0

        PinchArea {
          anchors.fill: parent
          // Nothing to transform automatically; the pose is driven by hand
          // below, and a target here would fight those assignments.
          pinch.target: null
          enabled: root.shown && !root.closing && root.uninstallTarget === null

          onPinchStarted: {
            spread.tracking = true
            spread.progress = 0
            spread.committed = false
            spread.dir = 0
            // The fingers own the pose from here.
            enterAnim.stop()
            exitAnim.stop()
            mistIn.stop()
            mistOut.stop()
          }

          onPinchUpdated: function(pinch) {
            if (!spread.tracking)
              return

            // Only spreading counts, and the direction is decided once, on the
            // first real movement, then held -- deciding it per update would
            // let a wobble at the turnaround flip the grid mid-gesture.
            if (spread.dir === 0) {
              if (pinch.scale > 1.01)
                spread.dir = 1
              else
                return
            }

            const p = spread.progressFor(pinch.scale)
            spread.progress = p
            if (p >= spread.commitAt)
              spread.committed = true
            // The travel is wide -- five times an ordinary dismiss, because
            // this one is watched the whole way rather than glimpsed -- and the
            // fade is CONCAVE in p, so it is already under way while the icons
            // are barely moving and then eases off. Thinning should be the
            // first thing the gesture does, not the last: it is what tells you
            // the grid is on its way out rather than just being nudged.
            //
            // The exponent is the whole feel of the gesture, and it took four
            // tries. Linear read as the fade outrunning the movement. Squared
            // put it so far behind that the page looked solid right up to the
            // commit point. 0.6 was closer but still back-loaded: most of the
            // dissolving happened in the second half of the travel, and what
            // that reads as is the grid deciding to leave rather than leaving.
            //
            // 0.2, which is about as far as this goes before it stops reading
            // as a response and starts reading as a twitch. One percent of
            // spread -- a movement that is invisible in the grid itself -- has
            // already taken a third of the opacity. Past the commit point the
            // curve is nearly flat, which is deliberate: the fade is what tells
            // you the gesture has been understood, so it belongs at the moment
            // the hand starts moving rather than spread evenly over the travel.
            // From there on it is the scale doing the work.
            const fade = Math.pow(p, 0.2)
            stage.scale = 1 + (root.dismissScale - 1) * 5 * p
            stage.opacity = 1 - 0.75 * fade
            // The mist thins less than the grid does, and lifts as it thins, so
            // the wallpaper comes back into focus underneath. Pulling it all the
            // way down would mean a cancelled gesture has to bring the whole
            // backdrop back, which reads as the desktop flashing through.
            mist.opacity = 1 - 0.5 * fade
            mist.haze = 1 - 0.5 * fade
          }

          onPinchFinished: {
            if (!spread.tracking)
              return
            spread.tracking = false

            if (spread.dir === 0) {
              // Held still and let go. Put back what stopping the animations
              // took away.
              enterAnim.start()
              mistIn.start()
              return
            }

            if (spread.committed) {
              // Carry on outward from wherever the fingers left it, rather than
              // snapping back to the standard exit and starting again.
              root.exitScale = Math.max(root.dismissScale, stage.scale * 1.02)
              root.dismiss()
            } else {
              enterAnim.start()
              mistIn.start()
            }
          }
        }
      }

    }
  }
}
