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
  // DesktopEntries is Quickshell's own .desktop index, so this tracks installs
  // and removals live with no watcher of our own.
  readonly property var allApps: {
    const out = [];
    const values = DesktopEntries.applications.values || [];
    for (let i = 0; i < values.length; i++) {
      const entry = values[i];
      if (!entry || entry.noDisplay)
        continue;
      out.push(entry);
    }
    out.sort((a, b) => String(a.name).toLowerCase().localeCompare(String(b.name).toLowerCase()));
    return out;
  }

  // Typing filters in place, the way Launchpad's search does.
  readonly property var apps: {
    const q = root.query.trim().toLowerCase();
    if (q.length === 0)
      return root.allApps;
    return root.allApps.filter(entry => {
      return String(entry.name || "").toLowerCase().includes(q)
          || String(entry.genericName || "").toLowerCase().includes(q);
    });
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

  function displayLabel(value) {
    const text = String(value || "");
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

  function iconFor(entry) {
    const fallback = Quickshell.iconPath("application-x-executable", true);
    const name = String((entry && entry.icon) || "");
    if (name.length === 0 || name.length > root.maxIconPathLength)
      return fallback;
    if (name.startsWith("/"))
      return name.indexOf("..") === -1 ? "file://" + name : fallback;
    if (root.looksLikeIconName(name)) {
      const themed = Quickshell.iconPath(name, true);
      if (themed.length > 0)
        return themed;
    }
    return fallback;
  }

  // A desktop file id is a filename, so it has a filename's shape. Rejecting
  // anything else keeps a path out of the argument list -- execDetached takes
  // an array and never goes through a shell, so there is no quoting to get
  // wrong, but "../../something.desktop" is still not an id.
  function looksLikeDesktopId(value) {
    return value.length > 0
        && value.length <= 255
        && /^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(value)
        && value.indexOf("..") === -1;
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
    const name = root.displayLabel(entry && entry.name);
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
  // is a webapp, a terminal wrapper, a user-written .desktop file, a pacman
  // package or a Flatpak, and for the privileged cases opens a floating
  // terminal so the sudo prompt is visible to the user. This plugin therefore
  // contains no sudo, no package manager, and no shell string -- which is the
  // difference between delegating a privileged action and performing one.
  //
  // Snapshot the id, name and icon at request time: the grid re-filters live,
  // so the entry under the cursor is not guaranteed to still be there when the
  // dialog is answered.
  property var uninstallTarget: null

  function requestUninstall(entry) {
    if (!root.canUninstall)
      return;
    const id = String((entry && entry.id) || "");
    if (!root.looksLikeDesktopId(id))
      return;
    root.uninstallTarget = {
      id: id,
      name: root.displayLabel(entry && entry.name),
      icon: root.iconFor(entry)
    };
  }

  function cancelUninstall() {
    root.uninstallTarget = null;
  }

  function confirmUninstall() {
    const target = root.uninstallTarget;
    root.uninstallTarget = null;
    if (!target || !root.canUninstall)
      return;
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
        onTapped: root.uninstallTarget ? root.cancelUninstall() : root.dismiss()
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

          // Escape backs out one level at a time: the confirm dialog first, then
          // Launchpad itself.
          Keys.onEscapePressed: root.uninstallTarget ? root.cancelUninstall() : root.dismiss()
          // Enter deliberately does nothing while the dialog is up. An alert
          // that uninstalls on the key the user was already pressing to launch
          // something is a trap; the answer has to be a deliberate click.
          Keys.onReturnPressed: if (!root.uninstallTarget && root.apps.length > 0) root.launch(root.apps[0])
          Keys.onEnterPressed: if (!root.uninstallTarget && root.apps.length > 0) root.launch(root.apps[0])
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
          required property int index
          width: pages.width
          height: pages.height

          Grid {
            anchors.centerIn: parent
            columns: root.columns
            rowSpacing: 0
            columnSpacing: 0

            Repeater {
              model: {
                const start = index * root.perPage;
                return root.apps.slice(start, start + root.perPage);
              }

              delegate: Item {
                id: tile
                required property var modelData
                width: panel.cellW
                height: panel.cellH

                Rectangle {
                  anchors.fill: parent
                  anchors.margins: Math.round(panel.cellW * 0.06)
                  radius: Math.round(panel.iconSize * 0.22)
                  color: hover.hovered ? Qt.rgba(1, 1, 1, 0.14) : "transparent"
                  Behavior on color { ColorAnimation { duration: 120 } }
                }

                Column {
                  anchors.centerIn: parent
                  spacing: Math.round(panel.iconSize * 0.14)

                  Image {
                    anchors.horizontalCenter: parent.horizontalCenter
                    source: root.iconFor(tile.modelData)
                    sourceSize.width: panel.iconSize
                    sourceSize.height: panel.iconSize
                    width: panel.iconSize
                    height: panel.iconSize
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                    scale: hover.hovered ? 1.06 : 1.0
                    Behavior on scale { NumberAnimation { duration: 120 } }
                  }

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: panel.cellW * 0.9
                    horizontalAlignment: Text.AlignHCenter
                    text: root.displayLabel(tile.modelData.name)
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
                TapHandler { onTapped: root.launch(tile.modelData) }

                // Right-click to uninstall. A separate handler rather than
                // acceptedButtons on the one above, so a right-click can never
                // fall through to launching.
                TapHandler {
                  acceptedButtons: Qt.RightButton
                  enabled: root.canUninstall
                  onTapped: root.requestUninstall(tile.modelData)
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

        Rectangle {
          id: card
          anchors.centerIn: parent
          width: Math.round(Math.min(panel.width * 0.30, panel.height * 0.62))
          height: Math.round(card.width * 0.72)
          radius: Math.round(card.width * 0.045)
          color: "#1b1e2b"
          border.width: 1
          border.color: Qt.rgba(1, 1, 1, 0.14)

          // Swallows clicks so answering the dialog does not also hit the
          // scrim behind it and cancel.
          MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

          Column {
            anchors.centerIn: parent
            width: parent.width - Math.round(card.width * 0.14)
            spacing: Math.round(card.width * 0.045)

            Image {
              anchors.horizontalCenter: parent.horizontalCenter
              source: (root.uninstallTarget && root.uninstallTarget.icon) || ""
              width: Math.round(card.width * 0.20)
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
              font.pixelSize: Math.round(card.width * 0.062)
              font.bold: true
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "Omarchy decides how: a package, a Flatpak, a web app or just "
                  + "a launcher entry. If it needs root, a terminal opens for your "
                  + "password."
              textFormat: Text.PlainText
              color: Qt.rgba(1, 1, 1, 0.62)
              font.pixelSize: Math.round(card.width * 0.040)
              wrapMode: Text.Wrap
              lineHeight: 1.25
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Math.round(card.width * 0.04)
              topPadding: Math.round(card.width * 0.02)

              // Cancel is first and is the wider target: the destructive answer
              // should never be the one the hand lands on by default.
              Rectangle {
                width: Math.round(card.width * 0.40)
                height: Math.round(card.width * 0.115)
                radius: height / 2
                color: cancelHover.containsMouse ? Qt.rgba(1, 1, 1, 0.20)
                                                 : Qt.rgba(1, 1, 1, 0.12)
                Behavior on color { ColorAnimation { duration: 100 } }

                Text {
                  anchors.centerIn: parent
                  text: "Cancel"
                  textFormat: Text.PlainText
                  color: "#ffffff"
                  font.pixelSize: Math.round(card.width * 0.045)
                }

                MouseArea {
                  id: cancelHover
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.cancelUninstall()
                }
              }

              Rectangle {
                width: Math.round(card.width * 0.40)
                height: Math.round(card.width * 0.115)
                radius: height / 2
                color: removeHover.containsMouse ? "#c0392b" : Qt.rgba(0.75, 0.22, 0.17, 0.85)
                Behavior on color { ColorAnimation { duration: 100 } }

                Text {
                  anchors.centerIn: parent
                  text: "Uninstall"
                  textFormat: Text.PlainText
                  color: "#ffffff"
                  font.pixelSize: Math.round(card.width * 0.045)
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
