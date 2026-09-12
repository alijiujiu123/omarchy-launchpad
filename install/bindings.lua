-- Launchpad keybinding, for ~/.config/hypr/bindings.lua (Omarchy's Lua
-- Hyprland config). Plugins cannot bind keys themselves, so this is manual.
--
-- SUPER+A rather than SUPER+SPACE: Omarchy's own launcher already owns
-- SUPER+SPACE, and the two answer different questions -- the launcher is for
-- "I know what I want", Launchpad is for "show me everything".

o.bind("SUPER + A", "Launchpad (app grid)",
  "omarchy-shell shell toggle io.github.andyweiboan.launchpad '{}'")
