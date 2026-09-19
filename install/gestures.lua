-- Optional touchpad gesture, for ~/.config/hypr/input.lua.
--
-- Four fingers together to open. ONLY the opening half belongs here; closing is
-- the plugin's own, and that split is the whole point.
--
-- THE DIRECTION NAMES ARE NOT WHAT THEY LOOK LIKE. `pinchin` fires when the
-- fingers move APART and `pinchout` when they come together -- Hyprland names
-- them after the zoom ("pinch in" = zoom in = spread), not after what the hand
-- does. Confirmed by registering `pinchin` and watching it open the grid on an
-- outward spread while an inward pinch did nothing at all. Read the line below
-- as its comment, not as its name.
--
-- WHY CLOSING IS NOT HERE. Hyprland forwards trackpad pinches to whichever
-- client holds pointer focus, over zwp_pointer_gestures_v1, four fingers
-- included, and it does so even while its own gesture config is watching the
-- same pinch. So once the overlay is up it can read the spread itself and run
-- the close frame by frame off the fingers. A `pinchin` -> hide registered here
-- would fire at the compositor's own threshold and cut that short.
--
-- WHY OPENING HAS TO BE. Before the overlay exists there is no surface for the
-- compositor to send a gesture to, and a configured gesture is one action at
-- one threshold -- there is no progress to read. It is not a total loss: when
-- pointer focus moves to the overlay mid-pinch, Hyprland issues a fresh begin
-- to it, so the plugin picks the gesture up in flight and finishes the
-- entrance off the remaining travel.
--
-- TESTING NOTE: there is no unset/ungesture in the Lua API (only hl.unbind for
-- keys), so a `hyprctl reload` cannot remove a gesture registered earlier in
-- the session -- a re-registration is shadowed by the one already there and the
-- OLD behaviour wins. Editing this file and reloading is NOT a valid way to
-- test a gesture change: log out and back in. Relatedly, if gestures stop
-- responding entirely, that is a known upstream Hyprland bug rather than a
-- conflict with this one; restarting the compositor clears it.

-- Fingers TOGETHER -- open.
hl.gesture({
  fingers = 4,
  direction = "pinchout",
  action = function()
    hl.dispatch(hl.dsp.exec_cmd(
      "omarchy-shell -q shell summon io.github.andyweiboan.launchpad '{}'"))
  end,
})
