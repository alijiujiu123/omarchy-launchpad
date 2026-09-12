// Launchpad -- a macOS-style application grid for Omarchy.
//
// A full-screen page of app icons over the blurred desktop wallpaper, with a
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

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland

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
  function open(payloadJson) {
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
  // Everything else -- cell size, icon size, fonts -- derives from these and
  // the screen, which is what keeps it sharp on both monitors.
  readonly property int columns: 6
  readonly property int rows: 5
  readonly property int perPage: columns * rows

  // Omarchy's current wallpaper, read through the same state symlink its own
  // background plugin uses. Following the link rather than the theme directory
  // means a theme switch is picked up with no reload.
  readonly property string wallpaperSource:
      "file://" + Quickshell.env("HOME") + "/.local/state/omarchy/current/background"

  // --- state --------------------------------------------------------------
  // Starts hidden. A plugin that shows itself on load flashes the whole grid
  // across the screen at every login.
  property bool shown: false

  property string query: ""

  // Panels listen for this to clear their own search field and page index;
  // those live per-screen, so root cannot reach them directly.
  signal resetRequested()

  function setShown(next) {
    root.opened = next
    root.uninstallTarget = null
    root.editMode = false
    if (next === root.shown)
      return
    if (next) {
      // A mounted plugin keeps whatever the user left behind. Reopening onto
      // the previous search text and page would be wrong -- Launchpad always
      // opens on page one with an empty box -- so reset here rather than on
      // hide, where a stale frame of the reset could be visible.
      root.query = ""
      root.resetRequested()
    }
    root.shown = next
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

      // Hiding tears down the layer surface but keeps the QML tree and, more to
      // the point, the decoded wallpaper -- which is the 190ms.
      visible: root.shown

      // Overlay layer so it covers the bar too, exclusive keyboard focus so
      // typing goes to the search box without a click first. The namespace is
      // stable so a user layer rule has something to match on.
      WlrLayershell.namespace: "launchpad"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore

      // --- derived geometry -------------------------------------------------
      readonly property real sidePad: Math.round(panel.width * 0.06)
      readonly property real searchBand: Math.round(panel.height * 0.13)
      readonly property real dotsBand: Math.round(panel.height * 0.07)
      readonly property real gridW: panel.width - sidePad * 2
      readonly property real gridH: panel.height - searchBand - dotsBand
      readonly property real cellW: gridW / root.columns
      readonly property real cellH: gridH / root.rows
      // Icon takes a little under half the cell so the label and the gaps have
      // room; the cap keeps it sane if a screen is very wide but short.
      readonly property int iconSize: Math.max(32, Math.round(Math.min(cellW * 0.44, cellH * 0.52)))
      readonly property int labelSize: Math.max(10, Math.round(iconSize * 0.15))

      // Background: the desktop wallpaper, blurred here in QML, with a dark
      // tint over it -- exactly what macOS Launchpad does.
      //
      // This is deliberately NOT a compositor blur. A `blur = true` layer rule
      // on a full-screen layer makes hyprbars' title bars flicker between
      // transparent and coloured whenever they redraw, and turning off
      // decoration:blur:new_optimizations was not enough to stop it. Blurring
      // the wallpaper image ourselves keeps Hyprland's blur machinery out of it
      // entirely, so there is nothing left to flicker.
      Image {
        id: wallpaper
        anchors.fill: parent
        source: root.wallpaperSource
        fillMode: Image.PreserveAspectCrop
        // Loaded synchronously on purpose: asynchronous loading painted the
        // icon grid first and blurred the background a beat later, which read
        // as the window opening in two steps. A local JPEG costs a few ms, and
        // being mounted it is paid once rather than per opening.
        asynchronous: false
        cache: true
        visible: false
      }

      MultiEffect {
        anchors.fill: parent
        source: wallpaper
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 1.0
        blurMax: 64
        brightness: -0.1
      }

      Rectangle {
        anchors.fill: parent
        color: "#0e101a"
        opacity: 0.42
      }

      // Click anywhere that isn't an app to dismiss. A TapHandler rather than a
      // MouseArea: a MouseArea grabs the press and the DragHandler below would
      // never see a swipe. Handlers cooperate -- a drag simply isn't a tap.
      TapHandler {
        onTapped: root.back()
      }

      function goTo(index) {
        pages.currentIndex = Math.max(0, Math.min(index, root.pageCount - 1));
      }

      // Paging is driven explicitly rather than by letting the ListView free-
      // drag: with SnapOneItem + StrictlyEnforceRange a drag has to cross half
      // a page to commit, which on a 5K screen means a huge sweep -- anything
      // less slid a little and sprang back.
      //
      // A touchpad two-finger scroll arrives as a burst of small wheel events,
      // so they are accumulated and a page turns once the total passes one
      // notch; the accumulator resets on each turn so one long swipe does not
      // skip several pages.
      property real wheelAccumulated: 0
      // Set the moment a page turns, cleared only once the scrolling has been
      // quiet for a beat. One physical swipe = one page: a touchpad keeps
      // firing events through the whole gesture, and without this the tail of
      // a single flick kept re-crossing the threshold and ran to the last page.
      property bool paging: false

      Timer {
        id: pagingCooldown
        interval: 300
        onTriggered: panel.paging = false
      }

      function scrolled(delta) {
        // Paging stays live in edit mode -- macOS pages while jiggling, and
        // blocking it would mean you can only remove apps from whichever page
        // you happened to be on. Only the modal dialog stops it.
        if (root.pageCount <= 1 || root.uninstallTarget)
          return;

        // Still inside the gesture that already turned a page: swallow the
        // rest of it, and keep pushing the cooldown out until the finger stops.
        if (panel.paging) {
          panel.wheelAccumulated = 0;
          pagingCooldown.restart();
          return;
        }

        panel.wheelAccumulated += delta;
        if (panel.wheelAccumulated <= -120)
          panel.goTo(pages.currentIndex + 1);
        else if (panel.wheelAccumulated >= 120)
          panel.goTo(pages.currentIndex - 1);
        else
          return;

        panel.wheelAccumulated = 0;
        panel.paging = true;
        pagingCooldown.restart();
      }

      // Two handlers, because WheelHandler.orientation defaults to Qt.Vertical
      // and silently drops horizontal wheel events -- which is why a sideways
      // two-finger swipe did nothing while an up/down one paged fine.
      WheelHandler {
        orientation: Qt.Horizontal
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => panel.scrolled(event.angleDelta.x)
      }

      WheelHandler {
        orientation: Qt.Vertical
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => panel.scrolled(event.angleDelta.y)
      }

      // Click-and-drag / touch swipe: commit on release once the drag has gone
      // a twelfth of the screen, instead of half a page.
      DragHandler {
        id: swipe
        target: null
        yAxis.enabled: false
        property real startX: 0
        onActiveChanged: {
          if (active) {
            startX = centroid.position.x;
            return;
          }
          if (root.uninstallTarget)
            return;
          const dx = centroid.position.x - startX;
          const threshold = panel.width / 12;
          if (dx <= -threshold)
            panel.goTo(pages.currentIndex + 1);
          else if (dx >= threshold)
            panel.goTo(pages.currentIndex - 1);
        }
      }

      // --- search pill ------------------------------------------------------
      Rectangle {
        id: searchPill
        width: Math.round(panel.width * 0.24)
        height: Math.round(panel.searchBand * 0.42)
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
              pages.currentIndex = 0;
              search.forceActiveFocus();
            }
          }

          Keys.onEscapePressed: root.back()
          // Enter deliberately does nothing while the dialog is up. An alert
          // that uninstalls on the key the user was already pressing to launch
          // something is a trap; the answer has to be a deliberate click.
          Keys.onReturnPressed: if (!root.uninstallTarget && !root.editMode && root.apps.length > 0) root.launch(root.apps[0])
          Keys.onEnterPressed: if (!root.uninstallTarget && !root.editMode && root.apps.length > 0) root.launch(root.apps[0])
          Keys.onLeftPressed: event => {
            if (search.text.length > 0) { event.accepted = false; return; }
            panel.goTo(pages.currentIndex - 1);
          }
          Keys.onRightPressed: event => {
            if (search.text.length > 0) { event.accepted = false; return; }
            panel.goTo(pages.currentIndex + 1);
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
        snapMode: ListView.SnapOneItem
        highlightRangeMode: ListView.StrictlyEnforceRange
        highlightMoveDuration: 220
        boundsBehavior: Flickable.StopAtBounds
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

                Rectangle {
                  anchors.fill: parent
                  anchors.margins: Math.round(panel.cellW * 0.06)
                  radius: Math.round(panel.iconSize * 0.22)
                  color: hover.hovered && !root.editMode ? Qt.rgba(1, 1, 1, 0.14)
                                                         : "transparent"
                  Behavior on color { ColorAnimation { duration: 120 } }
                }

                Column {
                  id: face
                  anchors.centerIn: parent
                  spacing: Math.round(panel.iconSize * 0.14)

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
                      anchors.fill: parent
                      source: root.iconFor(tile.modelData)
                      sourceSize.width: panel.iconSize
                      sourceSize.height: panel.iconSize
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      smooth: true
                      scale: hover.hovered && !root.editMode ? 1.06 : 1.0
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

                HoverHandler { id: hover }

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
            width: Math.max(6, Math.round(panel.dotsBand * 0.11))
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
          width: Math.min(Math.round(panel.width * 0.24), 400)
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
  }
}
