// login-layout: classic
//
// Login screen layout fragment, staged next to install-sddm-theme.sh and
// composed into layouts/active.js by scripts/set-login-layout.sh. The theme's
// Main.qml includes the active fragment and reads these three variables;
// anything missing falls back to the shipped arrangement.
//
// The shipped look: clock top-centre, login column just below centre.
var align = "center"          // "center" or "left"
var verticalOffset = 0.04     // column offset from centre, as a fraction of screen height
var clockVisible = true

var hud = false
