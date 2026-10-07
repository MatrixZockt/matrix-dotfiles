// login-layout: sheet
// COMPOSED FILE -- written by scripts/set-login-layout.sh, included by
// the SDDM theme's Main.qml. Change the layout with:
//   set-login-layout.sh <beacon|classic|corner|glass|minimal|ops|sheet|studio>
// The "sheet" arrangement: Stacked's architecture (clock top-right, form
// bottom-left, telemetry in the corners) with Ledger's square account tile
// and its `local · admin` title, and none of Ledger's horizontal ruling --
// the only line on screen is the password field's own baseline.
//
// Set by: set-login-layout.sh sheet
//
// `sheet` is the one variable this fragment adds. The other five are set to
// harmless values because Main.qml still reads them: `align` is ignored while
// `sheet` is true, and `card` must stay false so the frosted panel behind the
// column (which belongs to the glass family) does not appear here.
var align = "left"
var verticalOffset = 0.04
var clockVisible = true

var hud = false
var card = false
var clockScale = 1.0

var sheet = true
// activeLayout is appended by set-login-layout.sh when this fragment is
// composed into active.js, so it is deliberately not set here.
var activeLayout = "sheet"
