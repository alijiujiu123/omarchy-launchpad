-- Optional touchpad gesture, for ~/.config/hypr/input.lua.
--
-- Four-finger pinch in, the same gesture macOS uses. `toggle` rather than a
-- separate open/close pair, because a pinch has no natural inverse the way a
-- swipe up has a swipe down -- pinch out is already Mission Control territory
-- on macOS ("show desktop"), so leave it alone.
--
-- Testing note: there is no unset/ungesture in the Lua API (only hl.unbind for
-- keys), so a `hyprctl reload` cannot remove a gesture registered earlier in
-- the session. Editing this file and reloading is NOT a valid way to test a
-- gesture change -- log out and back in. Relatedly, if gestures stop responding
-- entirely, that is a known upstream Hyprland bug rather than a conflict with
-- this one; restarting the compositor clears it.

hl.gesture({
  fingers = 4,
  direction = "pinchin",
  action = function()
    hl.dispatch(hl.dsp.exec_cmd(
      "omarchy-shell shell toggle io.github.andyweiboan.launchpad '{}'"))
  end,
})
