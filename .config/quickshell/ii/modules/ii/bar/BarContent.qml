import qs.modules.ii.bar.weather
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import Quickshell.Bluetooth
import Quickshell.Services.UPower
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.modules.common.flare
import "../../common/models/quickToggles" as Toggles

Item { // Bar content region
    id: root
    // ── The liquid pocket's drop-down ───────────────────────────────────
    // Sits BELOW the bar row (parented here, out of the row's bounds): the
    // bar's stretched skin in Bar.qml draws behind it. The hovered widget
    // arms GlobalStates.barPocketId (see the hover handlers below); the
    // spring (LiquidBar.t) fades and slides it in, then rubber-bands it
    // back when the pointer leaves.
    function setPocket(id) {
        // Retired with the drop (see armPocket's note): this used to open
        // the below-bar droplet directly. It can only close now.
        LiquidBar.setPocket("");
    }

    // The DROPLET's content: a narrow column only as wide as the hovered
    // icon needs (the icon's center x and the content width come in through
    // LiquidBar.dropX / dropWidth, published by the hover handlers below).
    // Not the whole bar's length -- just the small curved section hanging
    // under the icon, like a raindrop merged back into the bar's underside.
    // Bounds the drop may occupy, in bar coordinates. Default: the whole bar.
    // The right island sets its own left edge so a pocket hanging off one of
    // its widgets can never stretch across the island's boundary into the gap
    // -- the glitch this replaces.
    property real pocketMinX: 0
    property real pocketMaxX: Number.MAX_VALUE

    // ── Inline mode ──────────────────────────────────────────────────────
    // An inline pocket opens inside the right island, filling the empty run
    // between the centre island and the icons up to the chrome the hairline
    // needs -- and in no case truncates its words to make that fit: if there
    // is not room, a pocket either stays un-shown or (before the drop was
    // retired) took the droplet under the bar instead.
    property string inlinePocketId: ""
    readonly property bool inlineMode: inlinePocketId !== ""
    // The island's inner padding. Left and right are SEPARATE numbers because
    // only the right one has to leave room for the hairline/rule; the left
    // only has to clear the island. Using one number and pretending they were
    // the same is what crowded the text into the icons: the same air applied
    // on the icon side on top of the rule's own bit made the text sit on them.
    readonly property real inlinePad: 16

    // The right island's extent with the pocket CLOSED -- which is the space an
    // inline pocket may claim. Measured from the row's own implicit width
    // rather than `rightIsland.x`, which already includes the inline growth:
    // measuring the grown island against itself is circular, and the available
    // gap would creep outward on every hover.
    readonly property real rightIconsW: barRightSideMouseArea.implicitWidth
    // The icons' layout box, left edge: where the right section's own content
    // begins, in bar coordinates. The island's right edge is one `gap` inside
    // this, and each control inside adds its own padding on top.
    readonly property real rightIconsLeft: barRightSideMouseArea.x
        + barRightSideMouseArea.width - root.rightIconsW
    readonly property real rightIslandBaseX: barRightSideMouseArea.x
        + barRightSideMouseArea.width - rightIconsW - (rightIsland.visible ? rightIsland.gap : 0)
    // How close the right island may come to the centre one when an inline
    // pocket has taken all the room it can. Small on purpose: this is the
    // width the two islands are ALLOWED to reach, not a gap the bar tries to
    // keep, so it is the last thing to give way, not the first.
    readonly property real inlineMinGap: 6
    // The centre island's right edge -- the wall the right island grows up
    // against. Falls back to the middle section's own left edge when there is
    // no centre island, so a bar without one still has a left limit instead of
    // letting a long title stretch the island across the whole screen.
    readonly property real inlineLimitX: centerIsland.visible
        ? centerIsland.x + centerIsland.width
        : (middleSection.visible ? middleSection.x : 0)
    // The empty run between the centre island and the right island's icons.
    // This is the pocket's WHOLE budget: the island may grow to exactly this
    // and no further, which is what makes "max width = touch the middle bar"
    // a property of the layout rather than a number someone typed.
    readonly property real inlineSpace: Math.max(0,
        rightIslandBaseX - root.inlineLimitX - root.inlineMinGap)
    // ── The hairline's two gaps are ONE number ──────────────────────────
    //
    // The inline pocket reads as:
    //
    //     [pad] text [G] |(1px)| [G] icons
    //
    // G is `inlineRuleGap`, used on BOTH sides and nowhere else. It used to be
    // 16 + 14 of air against 10 on the icon side, so the line sat visibly
    // nearer the controls it was dividing the text from, and read as a stray
    // tick welded to them rather than as a separator. One number, used twice,
    // is the only way the two sides can stay equal as either one moves.
    readonly property real inlineRuleGap: 16
    // ONE duration for the whole open/close, shared by everything that moves.
    //
    // The island's grow, the host's grow and the swipe used to carry their own
    // 240 / 260 / 260. Three numbers that are meant to describe a single motion
    // is three chances to desynchronise, and they had: the island finished
    // growing 20ms before the row inside it did, so the text was still
    // travelling while the pill it lives in had already stopped. One constant
    // makes them the same motion by construction.
    // 170, down from 200: ~15% quicker, which is the smallest change that is
    // actually perceptible on a gesture this short. The swipe has to stay
    // clearly longer than a tap's own feedback or it reads as a jump rather
    // than a movement, and the text has to finish materialising before the
    // pointer is already moving on -- so this is nudged, not halved.
    //
    // The blur's own 160 is deliberately left alone rather than folded in here:
    // it is an effect on a layer that switches itself off at rest, not one of
    // the three motions above, and at 10ms apart the two are already
    // indistinguishable.
    readonly property int inlineOpenMs: 170
    // How far the inline row rides ABOVE its host's geometric centre.
    //
    // One number, used by BOTH the text block and the hairline, because both
    // are wrong by the same amount and for the same reason: the host is a
    // 40px box, but nothing visible is centred in it.
    //
    // The icons beside it are true icons -- their ink is drawn in the upper
    // part of their box, so it reads ~5px above the host's centre. A line of
    // text is worse: the line box reserves a full ascent and descent that
    // "Not connected" or "80%" never uses, and the ink lands low in that box.
    // Centred on the box, the words hung at row 29.5 against icons at 24.
    //
    // So the box is the wrong ruler. `inlineTextLift` is the measured distance
    // from the host's centre down to where the icons' ink actually is, and
    // everything the pocket draws is raised by it. Measured on the live bar:
    // icons 24.0, text 24.5, rule 30.0 before; icons 24.0 after.
    readonly property real inlineTextLift: 5.5
    // ── The wifi icon's hover, first line ─────────────────────────────────
    // What the connectivity icon says it is connected TO. The two links
    // want different answers (requested 2026-09-29), so this is one
    // named thing rather than an expression buried in a tooltip binding
    // where nobody would look for it next time.
    //
    // Wired: the IPv4 address. A wired connection's NAME says nothing --
    // every one of them is called "Wired connection 1" -- so the tooltip
    // was quoting a string that could not distinguish one wired link from
    // another, while the one fact that is not obvious from a "lan" glyph
    // went unsaid: which address the machine is holding.
    //
    // Wi-Fi: the SSID and the radio's state, as before. The address is the
    // wrong way round on this branch -- which network you are joined to is
    // what you hover an icon to find out, and the address is four numbers
    // you already know.
    //
    // Each branch falls back to ITS OWN kind of label. A wired link whose
    // address has not arrived yet (DHCP still running) must not fall back
    // to the network name, which on that machine is the useless
    // "Wired connection 1" all over again.
    readonly property string networkIdentity: Network.ethernet
        ? (Network.wiredIp || Translation.tr("Wired connection"))
        : ((Network.networkName || Translation.tr("Not connected"))
            + (Network.wifiStatus === "connected" ? "" : " · " + Network.wifiStatus))
    // How far the text travels on its way in. Shorter than it was: the row now
    // has a hard clip at the icons, so a long throw spent most of its time
    // hidden behind that edge, which read as a slow start rather than a slide.
    readonly property real inlineSwipePx: 96
    // The leftmost offset of a VISIBLE child inside `item`, relative to that
    // item. Used to step past a container's own padding to the thing inside it
    // that actually paints.
    function firstVisibleOffset(item: Item): real {
        const kids = item.children;
        for (let i = 0; i < kids.length; i++) {
            const kid = kids[i];
            if (kid.visible && kid.width > 0) return kid.x;
        }
        return 0;
    }
    // Where the icons' own ink begins, in bar coordinates -- the point the eye
    // reads as "the controls start here".
    //
    // The TRAY ARROW, not the connectivity pill. These are different points
    // and the choice is visible: the strip is laid out right-to-left, so the
    // tray chevron is the strip's LEFTMOST item and the pill sits inside the
    // strip, to its right. Anchoring to the pill therefore put the divider
    // BETWEEN the tray arrow and the wifi glyph -- hard against the arrow's
    // right-hand side, reading as though the line belonged to the tray rather
    // than dividing the bar's information from its controls. The boundary the
    // eye wants is the one before the FIRST control, which is the arrow.
    //
    // The same inset applies: the chevron is a `cellSize` square with a
    // centred `larger` glyph, the same construction as the pill's icons, so
    // the box edge is the same distance left of the ink.
    //
    // Falls back to the pill's first indicator, and then to the island's own
    // left edge, so the divider still lands somewhere sane with the tray
    // hidden (`useShortenedForm`) or with no wifi/Bluetooth configured.
    //
    // Deliberately the wifi/Bluetooth pill's INDICATOR row and not the pill
    // itself. The pill no longer pads its own edges (see `iconInset`), so
    // the row inside it and the pill's own left edge are the same number --
    // either would do, and using the row keeps the divider on the glyphs'
    // side of every future change to the pill's own box.
    //
    // Falls back to the row's own left edge when the pill is hidden, so the
    // divider still lands somewhere sane with no wifi/bluetooth indications
    // configured at all.
    //
    // Summed out of plain `x` properties rather than measured with
    // `mapFromItem`. That call is a one-shot coordinate conversion: it
    // notifies nothing, so a binding built on it is evaluated once during the
    // first layout pass -- while the row is still at its pre-layout position
    // -- and never again. The divider then sat 145px from where it belonged,
    // which is the same bug wearing a different hat. Every term here is a
    // property Qt tracks, so the value follows the layout as it settles.
    // ── ONE even inset for every icon in the right strip ──────────────────
    // EVERY control in the top-right run is inset by this same number on BOTH
    // its left and its right, and the strip's own `spacing` is 0 (see
    // `rightSectionRowLayout`). The gap between any two neighbouring icons is
    // therefore exactly `2 * iconInset`, for EVERY pair, whatever set of
    // widgets happens to be visible -- even by construction.
    //
    // This is the shape that cannot come out uneven, and it is the end of a
    // long line of attempts that kept a single strip `spacing` and then let
    // one or two icons carry margins of their own on top of it: the pill
    // reserved `realSpacing * 2` of its own padding, and the battery carried a
    // `7` on its left and a `16` on its right. Those margins are what the eye
    // kept catching -- measured on the live bar, pill-to-sound sat at 6 while
    // sound-to-battery sat at 13, and no amount of tuning the strip's single
    // number could fix it, because the asymmetry lived in the icons' own
    // margins, not in the gap between them.
    //
    // So there are no per-icon margins left anywhere in the strip: one number,
    // applied to every icon on both sides, is the whole of the spacing. The
    // pill's own two glyphs read the same number (see `indicatorsRowLayout`),
    // so the run has exactly one spacing to reason about and one place to
    // change it.
    // 9, not the 6 this started at: 6 read as compressed once the run had
    // three or more icons on it, because the number is the HALF gap -- the air
    // the eye sees between two icons is 2 x this (18 now). One number still
    // governs everything in the strip and the pill's inner row; only its value
    // moved.
    readonly property real iconInset: 9
    // Air inside the connectivity pill, per side, for the pill's own glyphs.
    //
    // The pill's box used to be the glyph row's width EXACTLY, so the first and
    // last glyph sat flush against the pill's rounded ends -- 5px of glyph
    // cell, then the edge -- while every icon outside it enjoyed a real gap.
    // That contrast is what "the top bar looks compressed" is: the pill is the
    // one control where the row's spacing cannot reach the ends.
    //
    // The pill is therefore wider by `2 * pillPad` and carries exactly that
    // much LESS outer margin (`iconInset - pillPad`), so an icon beside it is
    // still `2 * iconInset` away from its neighbour on the inside -- the same
    // distance as everywhere else. Padding that did not give the margin back
    // would just stack on the inset and re-open the uneven-gap bug this strip
    // was rebuilt to close.
    readonly property real pillPad: 6

    // How far the glyph sits inside the first indicator's own box.
    //
    // `firstVisibleOffset` returns the first indicator's LEFT EDGE, and that
    // box is a `HoverIconButton`: a 26px square with the glyph CENTRED in it.
    // So the box edge is several pixels left of where the ink actually starts,
    // and the divider was being placed against the box rather than the ink.
    //
    // Measured on the live bar, network glyph, dark theme: ink at x 1424, the
    // divider at 1400-1401, the text ending at 1383. That is 16px of air on the
    // text side and 22 on the icon side -- the same number, `inlineRuleGap`,
    // producing two different gaps, which is exactly "the spacing around the
    // separator is not the same for every icon". The 7 is that overshoot.
    //
    // It is a constant rather than a measurement because the ink cannot be
    // measured in QML, and the value it corrects is fixed by the button's
    // geometry (26px box, a centred `larger` glyph) -- not by which icon is
    // showing.
    readonly property real indicatorInset: 7
    readonly property real iconsInkX: barSysTray.visible
        ? barRightSideMouseArea.x + rightSectionRowLayout.x
            + barSysTray.x + root.indicatorInset
        : (rightSidebarButton.visible
            ? barRightSideMouseArea.x + rightSectionRowLayout.x
                + rightSidebarButton.x + indicatorsRowLayout.x
                + root.firstVisibleOffset(indicatorsRowLayout) + root.indicatorInset
            : root.rightIconsLeft)
    // What the content column is inset by, per side. These are NOT the same
    // number inline, and that is deliberate.
    //
    // The run is laid out as one strip, and these are its two ends:
    //
    //     text ... [G] |rule| [G] icons
    //
    // The host's right edge is the rule's right edge (it is pinned
    // `inlineRuleGap` short of `iconsInkX`), so the rule needs no inset of its
    // own -- `inlineRuleInset` is 0 and the position cannot drift from the
    // gap. The text then stops `inlineRuleGap` short of the text edge of the
    // run, which is the rule's left edge MINUS the gap, hence `G + 1`: the
    // extra 1 is the hairline itself, and dropping it is what left the line
    // sitting a pixel nearer the words than the icons.
    readonly property real contentStartPad: inlineMode ? inlinePad : pocketHost.sidePad
    readonly property real contentEndPad: inlineMode
        ? root.inlineRuleGap + 1 : pocketHost.sidePad

    // A SINGLE pixel is the hairline. Expansion below hardens the gap between
    // left text and right icons from a hairline to a firm rule, but it is the
    // only number that grows: the left inset is untouched, so a line of text
    // does not get pushed into the icons when the air between it and a rule
    // is also counted as icon-side clearance (that was the old mistake). The
    // right inset is still the only place a rule is allowed to touch the text.
    readonly property real inlineRuleInset: 0
    // Everything the island spends on chrome around the text. The cap below is
    // taken off the content BEFORE this, never after: the old cap limited the
    // content to the whole free run and then added 65px of padding on top, so
    // the island could grow 77px further left than there was room for and the
    // text ended up sitting on the icons.
    readonly property real inlineChrome: contentStartPad + contentEndPad
    // How wide the open pocket's TEXT may actually get: everything the run
    // between the two islands has left after the chrome.
    //
    // There is no second, smaller cap under this one any more, and that is the
    // point. A soft cap used to sit at 340px, and its only job was to be
    // exceeded: a long track title or a full battery line was handed more room
    // than it could use, so it was quietly TRUNCATED -- "Plugged in · 3 h 20
    // min" became "Plug…". Truncating is the one thing this bar must not do.
    //
    // So the cap is now the whole budget, and `pocketFitsInline` uses it as a
    // YES/NO test instead: content that fits opens inline at its full width,
    // content that does not takes the drop under the bar. The answer is a
    // second surface with room to breathe, never a cut-off word.
    readonly property real inlineCapW: root.inlineSpace
    readonly property real inlineNeededW: inlineMode
        ? pocketHost.contentW + root.inlineChrome : 0

    // The inline host's ACTUAL width: whatever the pocket needs, up to and
    // INCLUDING the whole run between the two islands. That run is the wall
    // -- the middle isle -- so the cap here is the same number the island's
    // own width is capped by (`inlineSpace`), and the info is allowed to use
    // all of it rather than being stopped short of it.
    //
    // The cap is NOT `inlineSpace - chrome` any more: subtracting the
    // padding meant the text always stopped one chrome-width short of the
    // wall, which is precisely the "the info is cut off while there is still
    // room left" report. Only content that is genuinely wider than the whole
    // run is shortened, and then it is the last word, not the middle of a
    // value.
    readonly property real inlineHostW: Math.min(root.inlineNeededW,
        root.inlineSpace > 0 ? root.inlineSpace : root.inlineNeededW)
    function pocketItemFor(id) {
        switch (id) {
            case "sound": return soundPocket;
            case "network": return networkPocket;
            case "bluetooth": return bluetoothPocket;
            case "battery": return batteryPocket;
            case "notifications": return notificationsPocket;
            case "media": return mediaPocket;
            case "nowbar": return nowbarPocket;
            case "meter": return meterPocket;
            case "status": return statusPocket;
            // A pinned quick toggle: one shared pocket, labelled from whichever
            // pin the pointer is on (see hoveredPinName).
            case "pin": return pinPocket;
            case "vpn": return vpnPocket;
        }
        return null;
    }

    // May this pocket open inside the island?
    //
    // It opens inline when it FITS, and drops under the bar when it does not.
    // That is the whole rule, and it replaced the old one, which was "always
    // open inline and shorten the words until they fit" -- which is how a
    // battery line came to be called "Plug…".
    //
    // The test is made against the pocket's own measured width, the same number
    // the island then grows to, so the two can never disagree: if this says
    // yes, the row opens at FULL width with nothing elided; if it says no,
    // there is no partial answer to trim down to.
    //
    // A pocket that is not inline-eligible is NOT a right-island icon (the now
    // bar, which is the centre island's own wide card) and still drops.
    // The measured width of the status row's TEXT, synchronously, on the
    // exact string the row is about to paint -- computed from the real font
    // metrics, not from a Text item that may not have been re-laid-out yet
    // when the fit decision is made. `Text.implicitWidth` of a newly armed
    // pocket can lag the string it was just handed by a frame (polish runs
    // later); measuring here is current by construction, so the fit test and
    // the settled layout can never disagree. The numbers mirror the PocketLine
    // label: `smallie` pixels, the main family, plus the same variable axes.
    FontMetrics {
        id: statusLineMetrics
        font.family: Appearance.font.family.main
        font.pixelSize: Appearance.font.pixelSize.smallie
        font.variableAxes: Appearance.font.variableAxes.main
    }
    // label + gap + value + the row's spacing + a hair of slack so a
    // hinting difference between metrics and render never flips a row that
    // truly fits into the drop. The words mirror the row's own bindings, so
    // this is the width the row is actually going to paint.
    readonly property real statusNaturalW: {
        const plainWait = GlobalStates.loadingPending
            && !GlobalStates.loadingFailed && !GlobalStates.loadingInfo;
        const label = plainWait ? Translation.tr("Opening") : Translation.tr("Status");
        // Only a LIVE lifecycle has words. `loadingText` alone is not enough:
        // it is a plain string that good launches used to leave behind (see
        // finishLoading), and measuring it kept the row at the width of an
        // app name nothing was opening.
        const value = (GlobalStates.loadingPending || GlobalStates.loadingFailed
            || GlobalStates.loadingInfo || GlobalStates.loadingFailureInBar)
            ? (GlobalStates.loadingText || "") : "";
        return statusLineMetrics.advanceWidth(label)
            + 10
            + statusLineMetrics.advanceWidth(value)
            + 4;
    }

    // Forwarded pocket sizing for the IPC diagnostic (ids are not visible
    // from outside the file, so Bar.qml's statusFit reads these).
    readonly property real statusPocketContentW: pocketHost.contentW
    readonly property real statusPocketDropW: pocketHost.dropW
    function statusFitDiag(): string {
        const item = pocketItemFor("status");
        const col = statusPocket;
        const line = col && col.children.length > 0 ? col.children[0] : null;
        const lbl = line ? line.children.find(c => c.objectName === "pocketLineLabel") : null;
        const val = line ? line.children.find(c => c.objectName === "pocketLineValue") : null;
        return "text=" + Math.round(statusNaturalW)
            + " cap=" + Math.round(inlineCapW)
            + " space=" + Math.round(inlineSpace)
            + " needed=" + Math.round(inlineNeededW)
            + " hostW=" + Math.round(inlineHostW)
            + " inlineWanted=" + inlinePocketId
            + " dropId=" + LiquidBar.pocketId
            + " contentW=" + Math.round(statusPocketContentW)
            + " dropW=" + Math.round(statusPocketDropW)
            + " colW=" + (col ? Math.round(col.width) : -1)
            + " rowW=" + (line ? Math.round(line.width) : -1)
            + " rowImplicit=" + (line ? Math.round(line.implicitWidth) : -1)
            + " lblW=" + (lbl ? Math.round(lbl.width) + "/" + Math.round(lbl.implicitWidth) : "?")
            + " valW=" + (val ? Math.round(val.width) + "/" + Math.round(val.implicitWidth) : "?")
            + " loadingText=" + JSON.stringify(GlobalStates.loadingText)
            + " pending=" + String(GlobalStates.loadingPending);
    }

    // May this pocket open inside the island? YES for every right-icon
    // pocket EXCEPT the status row when its text is too wide for the gap.
    //
    // The hover pockets keep the permanent-inline presentation that was
    // asked for and kept: their info extends to the LEFT inside the island
    // and never drops, an unusually long device name elides inside the row
    // rather than pushing the island into the centre one.
    //
    // The STATUS row ("Opening <app>…") is the exception, and it is one
    // because its text carries an APP NAME the user just clicked: an app
    // name may never be cut, so when its measured natural width does not
    // fit the empty run between the two islands the row does not open
    // inline at all -- it drops under the bar, where the drop sizes to the
    // content and the full name always fits, un-elided.
    // (Kept inline on hover because of the old "same icon shows its info in
    // a different place depending on the length of a device name" report;
    // the status row is not hover-picked, it arrives unsolicited, so the
    // inconsistency objection does not apply to it.)
    //
    // The status row now ALWAYS opens inline when the island is visible,
    // regardless of its natural width -- the island grows to fit rather than
    // the row being trimmed to "…". This replaces the old "fits or stays in
    // the drop" decision, which was the last remaining place the bar still
    // elided whole lines.
    function pocketFitsInline(id) {
        if (!rightIsland.visible) return false;
        const item = pocketItemFor(id);
        if (item === null || item.inlineEligible !== true) return false;
        // All right-icon pockets (network, bluetooth, battery, media,
        // meter, notifications) and now the status row too open inline
        // whenever the island is visible -- their content is promised at
        // full width, nowhere to be truncated.
        return true;
    }

    // Horizontal extent the right-icon inline pockets may use: the WHOLE run
    // between the centre island and the icons, which is exactly what "as wide
    // as the space up to the middle isle" means. It is stated here and the
    // layout is capped by the same number (`inlineSpace`), so the measurement
    // path and the fit test can never disagree.
    readonly property real rightIconSlotMaxW: Math.max(0, root.inlineCapW)

    // Take the status row down, if it is still up and the launch lifecycle
    // has nothing left to say. The lifecycle has THREE live flags and not
    // every end is a change of `loadingPending` -- an "already open" notice
    // begins with that one already false -- so the row's retirement is keyed
    // on the whole state. Without this the row could stay armed with an
    // empty value: a status chip that never left (2026-10-19).
    function retireStatusRow() {
        if (GlobalStates.loadingPending || GlobalStates.loadingFailed
            || GlobalStates.loadingInfo || GlobalStates.loadingFailureInBar)
            return;
        if (root.inlinePocketId === "status" || LiquidBar.pocketId === "status")
            root.armPocket("", root.centerXFor(soundButton),
                root.rightIslandLeft, root.rightIslandRight);
    }

    function armPocket(id, centerX, minX, maxX, forceDrop) {
        // ── THE DROP IS RETIRED (2026-10-07, user request) ──────────────
        // The droplet hanging below the bar was this shell's message
        // channel at the beginning; near the end it surfaced on its own --
        // auto-armed by status/meter messages or racing its own geometry --
        // as a broken empty box under the bar. The user asked for it to be
        // eliminated outright, so arming is now INLINE-ONLY: a pocket opens
        // inside the right island if it fits there and is not shown at all
        // otherwise. Nothing hands LiquidBar a non-empty id any more, so
        // the spring stays at rest and no drop can ever render -- not from
        // hover, not from a status message, and not from the IPC test hooks
        // (Bar.qml `pocket`, shell.qml `liquidbar set`), which are
        // close-only now too. The skin, pocketHost and every pocket below
        // stay where they are: publishDropGeometry still reads pocketHost's
        // geometry, and the machinery is unreachable while pocketId is
        // empty. `forceDrop` -- the status row's mid-life retarget into a
        // drop -- is accepted but ignored, for the same reason: a status
        // line too wide for the gap is dropped entirely rather than
        // becoming a box (the corner card still carries failures).
        root.pocketMinX = minX ?? 0;
        root.pocketMaxX = maxX ?? Number.MAX_VALUE;
        LiquidBar.dropCenter = centerX ?? 0;
        // Inline is tried FIRST, and an inline pocket arms NO drop at all (an
        // empty id), so the liquid skin stays retracted and there is nothing
        // hanging under the bar. Anything that does not qualify arms nothing:
        // this used to take the drop, which no longer exists.
        root.inlinePocketId = root.pocketFitsInline(id) ? id : "";
        LiquidBar.setPocket("");
        // The pocket may be changing, which changes the content size, and the
        // center has to be re-clamped against the new width. Publishing here
        // covers the arming frame; the content's own size changes re-publish
        // through pocketHost's handlers.
        //
        // (The droplet's width is now the info's full natural width plus chip,
        // not the old smaller number: the drop was the last surface where a
        // long line was allowed to breathe, and with the drop retired the info
        // must still measure at that width so the island can grow to hold it.)
        root.publishDropGeometry();
    }

    // ── Hover is not a request for the card ───────────────────────────────
    //
    // The bar's icons give their OWN hover feedback now (the swell), and a
    // card that popped the instant the pointer arrived buried it. Worse: every
    // icon the pointer crossed on its way somewhere else popped one, and each
    // pop re-tessellated the liquid skin, re-laid-out the pocket's content
    // and re-committed the window's input region -- the bar visibly glitched
    // for as long as the pointer was travelling along it.
    //
    // So the card is for a pointer that has STOPPED. It opens after a short
    // dwell (moving through never reaches it) and closes the instant the
    // pointer leaves, so the feedback you get from sweeping the bar is the
    // icons' own, and the card is still one hover-and-rest away.
    // Dwell, tuned per the user's "snappier" ask: 260ms read as a lag before
    // the info appeared. 180ms is still longer than a brush-by (dragging the
    // cursor across the bar to reach something else never arms a pocket) but
    // reads as instant-ish on a deliberate stop. The spring itself already
    // extends in ~55ms; the dwell was the whole wait.
    // Which pinned toggle the pointer is over, for the shared pin pocket: the
    // bar's hover line is one surface, so it reads the model of the pin that
    // asked for it rather than existing nine times.
    //
    // The MODEL is held, not copies of its two strings. The line has to follow
    // the toggle while the pointer is still resting on it, and the power icon is
    // exactly that case: a tap on it changes the mode the line is describing, so
    // a snapshot would keep advertising the mode you just left until you moved
    // off and back. `statusText` is a live binding on the toggle model, so these
    // two read through to it.
    property var hoveredPinModel: null
    property bool hoveredPinIsPower: false
    readonly property string hoveredPinName: hoveredPinIsPower
        ? Translation.tr("Power mode")
        : (hoveredPinModel?.name ?? "")
    readonly property string hoveredPinStatus: hoveredPinModel?.statusText ?? ""

    // The pin menu (two-finger tap on the power icon). On the root, not on the
    // delegate: the delegate is one of nine Repeater instances, so an id on it
    // is not addressable from the panel that has to be told to open.
    property bool pinPopupOpen: false

    readonly property int pocketDwellMs: 180
    property string dwellPocketId: ""
    property real dwellCenterX: 0
    property real dwellMinX: 0
    property real dwellMaxX: 0

    function hoverPocket(hovered, id, centerX, minX, maxX) {
        if (hovered) {
            root.dwellPocketId = id;
            root.dwellCenterX = centerX;
            root.dwellMinX = minX;
            root.dwellMaxX = maxX;
            pocketDwellTimer.restart();
            return;
        }
        // ── STALE LEAVE GUARD ────────────────────────────────────────────
        // Moving from icon A to icon B can deliver A's leave AFTER B's enter
        // (Qt does not order the two handlers). The unconditional stop+disarm
        // that used to live here then killed B's pending dwell -- or B's
        // already-open pocket -- which is the user's exact report: hover a
        // few icons, land on the network one, and its info never shows until
        // a re-hover. A leave may only take down ITS OWN icon's pending
        // dwell or open pocket; a newer hover's business is not theirs.
        const openId = root.inlinePocketId !== "" ? root.inlinePocketId : LiquidBar.pocketId;
        if (root.dwellPocketId !== "" && root.dwellPocketId !== id)
            return; // a newer icon's dwell is pending -- not ours to cancel
        if (openId !== "" && openId !== id)
            return; // another icon's pocket is open -- not ours to close
        pocketDwellTimer.stop();
        root.dwellPocketId = "";
        root.armPocket("", centerX, minX, maxX);
    }

    Timer {
        id: pocketDwellTimer
        interval: root.pocketDwellMs
        onTriggered: {
            // Only if the pointer is still on the icon that asked: the leave
            // handler stops this timer, but a fire that lands in the same
            // frame as a leave would still pop a card nobody is looking at.
            if (root.dwellPocketId === "")
                return;
            root.armPocket(root.dwellPocketId, root.dwellCenterX,
                root.dwellMinX, root.dwellMaxX);
            root.dwellPocketId = "";
        }
    }

    // Publish the droplet's geometry to the one place every consumer reads
    // from: the skin, the window's height, and the input mask.
    //
    // The center slides inward just enough to keep the drop fully on screen --
    // the rightmost icons (battery, sound) sit a few pixels from the monitor
    // edge, and an unclamped drop was being sliced in half there.
    function publishDropGeometry() {
        LiquidBar.dropWidth = pocketHost.dropW;
        LiquidBar.dropHeight = pocketHost.dropH;
        const half = LiquidBar.dropWidth / 2;
        // Clamp against the ISLAND edge, not the raw screen: the rightmost
        // icons sit right at the right island's edge, and a drop clamped only
        // to the screen put its wall -- and worse, its 9px shadow blur --
        // past the visible surface ("the border is not inside the top bar").
        // The margin is the island gap plus the shadow's reach, so the drop
        // and its shadow both stay on the island.
        const margin = Appearance.sizes.hyprlandGapsOut + 6;
        // The arming section's bounds first (a right-island pocket may not
        // cross the island's left edge), then the island's painted edge --
        // exactly the clamping this always did, unchanged for every drop
        // that fits its section.
        const lo = Math.max(margin + half, root.pocketMinX + half);
        const hi = Math.max(lo, Math.min(root.pocketMaxX - half, root.width - margin - half));
        // The screen's own bounds, applied LAST as pure safety. For a drop
        // that fits its section the clamp above already lands inside these,
        // so this is a no-op; for a drop WIDER than its section -- the
        // status drop carrying a long app name -- the section clamp used to
        // win and pin the drop's left edge at the island, running its right
        // half past the display edge: the value inside it cut mid-word,
        // which is exactly the report. A drop sliced by the screen is the
        // one outcome here that destroys information rather than merely
        // placing it imperfectly, so the screen wins in that case and only
        // in that case.
        const screenLo = margin + half;
        const screenHi = Math.max(screenLo, root.width - margin - half);
        LiquidBar.dropX = root.width > 0
            ? Math.max(screenLo,
                Math.min(Math.max(lo, Math.min(LiquidBar.dropCenter, hi)), screenHi))
            : LiquidBar.dropCenter;
    }

    // Map a position from a child widget up to bar coordinates: the bar row
    // is this item's own space, so mapToItem(root) gives the right frame.
    /**
     * Test hook for the VPN popup: opens or closes it through the very flag
     * the bar icon writes, so the panel can be exercised without a pointer.
     *
     * A layer surface can be neither clicked nor screenshotted from a script,
     * and on this machine a synthetic ydotool click is not delivered to the
     * bar at all (verified across the whole strip) -- so this is the only way
     * to prove the popup genuinely comes up.
     *   qs -c ii ipc call bar vpnPanel true
     */
    function vpnPanelToggle(on): string {
        vpnButton.popupOpen = on;
        return "popupOpen=" + String(vpnButton.popupOpen);
    }

    /**
     * The same hook for the two connectivity menus, for the same reason.
     *   qs -c ii ipc call bar wifiPanel true
     *   qs -c ii ipc call bar bluetoothPanel true
     */
    function wifiPanelToggle(on): string {
        networkButton.popupOpen = on;
        return "popupOpen=" + String(networkButton.popupOpen);
    }

    function bluetoothPanelToggle(on): string {
        bluetoothButton.popupOpen = on;
        return "popupOpen=" + String(bluetoothButton.popupOpen);
    }

    /**
     * The sound panel, openable without a touchpad.
     *
     * Same purpose as its three siblings above: the two-finger tap is the one
     * gesture on this bar that cannot be exercised from a terminal, so the flag
     * it drives has to be reachable by name.
     *   qs -c ii ipc call bar soundPanelToggle true
     */
    function soundPanelToggle(on): string {
        soundButton.popupOpen = on;
        return "popupOpen=" + String(soundButton.popupOpen);
    }

    /**
     * The same hook for the pin menu (two-finger tap on the power icon), for
     * the same reason: the pin is a Repeater delegate and its panel is a layer
     * surface, so neither can be clicked or screenshotted from a script.
     *   qs -c ii ipc call bar pinPanel true
     */
    function pinPanelToggle(on): string {
        root.pinPopupOpen = on;
        return "popupOpen=" + String(root.pinPopupOpen);
    }

    // Whether a press in one of the bar's stretch areas landed on BARE BAR.
    //
    // The left and right stretches are the click zones for the empty bar: they
    // run from the screen edge to the centre island and answer a left press
    // with the desktop overview. They also run UNDER their island, which is
    // the problem this fixes -- an island is a pill carrying the icons, and the
    // pixels between two icons (or the padding around them) are that pill, not
    // empty bar. A press there fell through to the stretch, so clicking in the
    // gap between the battery and the power pin -- aiming at nothing, or
    // mis-aiming at a pin -- threw the desktop overview over the screen.
    //
    // So a press is only "on the bar" while it is outside the island's painted
    // box. The classic single-slab bar has no islands (`island.visible` false):
    // there the whole stretch keeps its old meaning, because the slab IS the
    // bar and everything on it is content over the same surface.
    //
    // Coordinates: both the stretch and the island live in this item's frame,
    // so the press (in stretch-local x) is compared after adding the stretch's
    // own x rather than being mapped item-to-item.
    function pressedOnBareBar(event, stretch, island) {
        if (!island || !island.visible)
            return true;
        const pressX = stretch.x + event.x;
        return pressX < island.x || pressX > island.x + island.width;
    }

    function centerXFor(item) {
        return root.mapFromItem(item, item.width / 2, 0).x;
    }

    // The RIGHT ISLAND's painted edges, in bar coordinates -- the box a
    // hovered drop is allowed to occupy.
    //
    // These used to be the right-side MouseArea's own bounds, but that item
    // stretches from the middle island all the way to the screen edge: it is
    // the whole click zone, empty stretch included. A drop clamped only to it
    // could therefore slide LEFT of the island's painted edge and hang in the
    // gap between the two islands -- the drop's mouth and its hairline drawn
    // over bare desktop, which is exactly "a box floating off the bar's
    // length". Anchored to the island, the drop is always attached to
    // something painted, however long or short the bar (or the island) is.
    //
    // The classic single-slab skin has no islands, so the old bounds stay the
    // fallback there.
    // The islands' corner radius (they are `radius: windowRounding` pills).
    // A drop whose mouth reaches the island's extreme left/right edge butts
    // against the island's OWN rounded bottom corner, and its fill/fillet pokes
    // a small hook past the corner into the gap. Insetting the bounds by this
    // radius puts the mouth squarely on the island's flat bottom run, so the
    // widest drop (the now bar) merges as cleanly as a narrow one.
    readonly property real islandRadius: Appearance.rounding.windowRounding
    readonly property real rightIslandLeft: rightIsland.visible
        ? rightIsland.x + islandRadius : root.mapFromItem(barRightSideMouseArea, 0, 0).x
    readonly property real rightIslandRight: rightIsland.visible
        ? rightIsland.x + rightIsland.width - islandRadius : root.width

    // The centre island's painted edges, for the same reason. The now bar's
    // pocket is the WIDEST drop in the shell (up to 420px), so without a floor
    // it is the one most able to reach out past the island it grows from and
    // leave its mouth drawn over bare desktop.
    readonly property real centerIslandLeft: centerIsland.visible
        ? centerIsland.x + islandRadius : 0
    readonly property real centerIslandRight: centerIsland.visible
        ? centerIsland.x + centerIsland.width - islandRadius : root.width

    // ── The ONE completion handler for this object ───────────────────────
    // QML allows exactly one assignment per signal handler per object, and a
    // second `Component.onCompleted` here is a hard load failure
    // ("Property value set multiple times") that takes the whole shell down
    // -- every later line of this file, and the bar with it.
    //
    // It does two things, and both belong here because there is nowhere else
    // to put the second one:
    //
    //   1 · Publishes the pocket geometry once the row has been laid out, so
    //       the droplet's numbers are already sane before the first hover
    //       (the skin and the input mask read them from the moment the bar
    //       exists).
    //   2 · Decides which bar form this screen gets: `useShortenedForm` is 0
    //       normal, 1 shortened, 2 hella shortened. The read needs the
    //       window's screen, which only exists once the component is
    //       complete -- and it cannot live in the property initializer
    //       because `?` on a property initializer is a parse error in this
    //       engine.
    Component.onCompleted: {
        root.publishDropGeometry();
        screen = root.QsWindow.window ? root.QsWindow.window.screen : undefined;
        brightnessMonitor = Brightness.getMonitorForScreen(screen);
        if (screen && screen.width) {
            if (Appearance.sizes.barHellaShortenScreenWidthThreshold >= screen.width)
                useShortenedForm = 2;
            else if (Appearance.sizes.barShortenScreenWidthThreshold >= screen.width)
                useShortenedForm = 1;
            else
                useShortenedForm = 0;
        } else {
            useShortenedForm = 0;
        }
    }



    Item {
        id: pocketHost
        z: 10 // above the droplet's skin, which is z: 1
        x: LiquidBar.dropX - width / 2
        // Anchored to the MOUTH itself -- the bar's painted bottom edge, which is
        // the line the drop's silhouette is drawn from -- and NOT padded here:
        // the column inside carries `padV` on both sides, so adding it again was
        // padding the top twice. Measured on the battery pocket: 27px of air
        // above the first line and 5px below the last. Now it starts at the
        // mouth, and the column's own equal padding centres the block.
        y: dropPainter.barH
        // The shell itself is the mask: the content is cut at the shell's
        // current bottom edge, so the information unfurls as the drop grows and
        // nothing can ever hang below the skin it belongs to.
        clip: true

        // ── the pocket's size ──────────────────────────────────────────────
        // The info's own natural size plus padding, quantized to 8px so a live
        // value -- the battery's percentage, a track title -- cannot make the
        // shell twitch.
        //
        // Vertical padding is equal above and below the block, which is what
        // centres the content between the mouth line and the drop's bottom by
        // construction.
        readonly property real padV: 12
        // Horizontal clearance from the drop's OUTER edge. The wall beside the
        // content is vertical (see dropPainter), so this is the content's real
        // distance from it -- not a nominal inset that a flare then eats into.
        readonly property real sidePad: 20
        // An inline pocket arms an EMPTY pocketId (it has no drop at all), so it
        // names itself here. Without this it would fall through to
        // `lastPocketId` -- the id of whatever drop was open BEFORE -- and the
        // wrong content would fly into the island.
        readonly property string resolvedId: root.inlinePocketId !== ""
            ? root.inlinePocketId
            : (LiquidBar.pocketId !== "" ? LiquidBar.pocketId : LiquidBar.lastPocketId)
        readonly property Item activePocket: {
            // Resolved through `lastPocketId` as well, so the content stays
            // measurable while the pocket retracts.
            switch (resolvedId) {
                case "sound": return soundPocket;
                case "network": return networkPocket;
                case "bluetooth": return bluetoothPocket;
                case "battery": return batteryPocket;
                case "notifications": return notificationsPocket;
                case "media": return mediaPocket;
                case "nowbar": return nowbarPocket;
                case "meter": return meterPocket;
                case "status": return statusPocket;
                // A pinned quick toggle and the VPN: without these two the
                // resolver returned null, so `contentW` was 0 and the text was
                // clipped to a stub ("Powe...") in a box sized for nothing.
                case "pin": return pinPocket;
                case "vpn": return vpnPocket;
            }
            return null;
        }
        // The content's NATURAL width, not the layout's implicitWidth. Every
        // row in the column is `Layout.fillWidth`, so the column's implicit
        // width is whatever the host happened to hand it -- which is why this
        // read as "almost nothing" and pinned every drop to its 200px floor
        // while the values inside elided at a hard 180px. The shell now
        // measures the text it is actually going to paint. The now bar is a
        // plain Item that still reports an honest implicitWidth, and has no
        // `naturalWidth` to offer, so it falls through to that.
        readonly property real contentW: activePocket
            ? (activePocket.naturalWidth !== undefined && activePocket.naturalWidth > 0
                ? activePocket.naturalWidth
                : activePocket.implicitWidth)
            : 0
        readonly property real contentH: activePocket ? activePocket.implicitHeight : 0
        // Quantized UP (ceil), never down: rounding to the nearest 8 shaved
        // the last characters of wide content off the side of the box.
        // Never wider than the island it hangs from: a drop WIDER than its
        // island cannot be centred on it, so on a short bar it would hang half
        // off the edge onto bare desktop -- the same "box floating beside the
        // bar" read, from the other end.
        //
        // The drop is now the answer for anything the bar cannot hold, so it is
        // sized for its CONTENT rather than for the island it hangs from: it
        // used to be capped at the island's own width (~250px), which meant the
        // pocket that dropped was also the pocket that got cut off -- the drop
        // inherited the very truncation the bar was avoiding. `dropMaxW` is the
        // only limit now, and the screen clamp in `publishDropGeometry` keeps
        // it on the display.
        readonly property real dropMaxW: 2000
        readonly property real dropW: Math.ceil(Math.min(dropMaxW,
            Math.max(200, contentW + sidePad * 2)) / 8) * 8
        readonly property real dropH: contentH + padV * 2
        onDropWChanged: {
            shownW = dropW;
            root.publishDropGeometry();
        }
        onDropHChanged: {
            shownH = dropH;
            root.publishDropGeometry();
        }

        // The size the skin and the shell actually use: the target above, but
        // smoothed. Moving the pointer from the battery (four lines, tall) to
        // bluetooth (two lines, short) changes the target in one frame, and a
        // hard jump there is the one motion in this whole thing that could read
        // as a glitch. Assignments (not a binding) so the Behaviour is certain
        // to animate them.
        property real shownW: dropW
        property real shownH: dropH
        Behavior on shownW {
            animation: Appearance.animation.elementMoveSmall.numberAnimation.createObject(this)
        }
        Behavior on shownH {
            animation: Appearance.animation.elementMoveSmall.numberAnimation.createObject(this)
        }

        width: shownW
        // The shell's height tracks the SAME spring as the droplet's skin: the
        // reveal and the shell are one motion, and the snap-back overshoot
        // carries the content with it. No separate fade-in choreography to
        // drift out of phase.
        height: Math.max(0, LiquidBar.t) * shownH
        visible: LiquidBar.t > 0.001
        opacity: Math.min(1, Math.max(0, LiquidBar.t) * 2.2)

        // Resting the pointer inside the droplet keeps it extended. The
        // handoff matters: moving from the icon into the drop is one continuous
        // hover, so the drop must NOT blink closed in between. The icon's
        // handlers (below, on the bar row) clear the pocket on leave; this
        // handler re-arms it the moment the pointer arrives inside the drop --
        // by then pocketId is already "" (the icon's leave fired first), so
        // the re-arm uses lastPocketId, the content still on screen. The
        // spring keeps its velocity through the retarget, so the journey
        // from the icon down into the drop is one motion. Leaving the drop
        // entirely clears the pocket here, which closes it.
        HoverHandler {
            // Retired with the drop: re-arming from inside the droplet can
            // never happen (it is never visible); this only ever closes.
            onHoveredChanged: if (!hovered) LiquidBar.setPocket("")
        }

        // A pocket's content block. Top-anchored at the skin's own padding, at
        // the skin's own padding from the sides: with equal padding above and
        // below, the block is centred in the drop by construction -- the old
        // version centred it in a fixed-height box that taller pockets (the
        // battery's four lines) overflowed, which cut the last line off below
        // the shell.
        component PocketColumn: ColumnLayout {
            // A pocket that may live INSIDE the island row instead of in a
            // drop below it. Only a SINGLE-ROW pocket may set this: the island
            // is one bar-height tall, and a two-line pocket squeezed into it
            // would clip its own second line.
            property bool inlineEligible: false
            // Set where the rows cannot measure themselves: a `Layout.fillWidth`
            // slider reports an implicit width of nearly zero, and a wrapped
            // notification body measures at whatever width the host gave it.
            // Those pockets state their real width here.
            property real naturalWidthOverride: 0

            // ONE parent at a time, whichever mode won. Both hosts are plain
            // Items, so this is a reposition -- not a reparent into a layout,
            // which would have the RowLayout fight the content for sizing.
            parent: root.inlineMode ? inlineHost : pocketHost
            x: root.contentStartPad
            // In the drop, the column's own equal padding centres the block
            // between the mouth and the floor. Inline, the host is already the
            // island's height, so the block centres itself in it.
            y: root.inlineMode
                ? Math.max(0, (parent.height - implicitHeight) / 2 - root.inlineTextLift)
                : pocketHost.padV
            // The two insets are SEPARATE numbers, and inline they are not
            // equal: the right one carries the air the hairline needs, the
            // left one does not. Subtracting the same pad twice is what put
            // the text under the icons -- it silently handed back the
            // hairline's own breathing room.
            width: Math.max(0, parent.width - root.contentStartPad - root.contentEndPad)
            spacing: 3
            // The width this column wants, measured from its rows. `children`
            // holds Items only (the WheelHandler is a pointer handler, not
            // one), so the 2px spacers contribute 0 and the widest row wins.
            readonly property real naturalWidth: {
                if (naturalWidthOverride > 0) return naturalWidthOverride;
                let widest = 0;
                for (let i = 0; i < children.length; i++) {
                    const child = children[i];
                    const w = child.naturalWidth !== undefined
                        ? child.naturalWidth
                        : (child.implicitWidth ?? 0);
                    widest = Math.max(widest, w);
                }
                return widest;
            }

            // Horizontal slot the right-icon inline pockets may use, expressed
            // in CONTENT space (the host's width after the two chrome insets
            // have been subtracted). This is the same budget the fit test uses
            // (`inlineCapW`) but stated for the pocket's own measurement path,
            // so `naturalWidth` can be the single width source for both "will it
            // fit inline" and "how wide is the island this pocket wants" -- and
            // the two can never disagree.
            readonly property real rightIconSlotMaxW: root.inlineCapW
        }

        PocketColumn {
            id: soundPocket
            visible: pocketHost.resolvedId === "sound"
            inlineEligible: true
            // ONE line, read at a glance: how loud it is, and where it is
            // coming out. The slider that used to live here is gone -- it was
            // the reason this pocket needed a box of its own, and the wheel
            // handler below still changes the volume in place.
            //
            // Two things this line got wrong, both fixed here.
            //
            // 1 · It showed the raw PipeWire description, and PipeWire names a
            // sink after its hardware chain: this machine's default is "700
            // Series Chipset Family HD Audio Speaker" -- 41 characters, mostly
            // vendor and chipset, to end on the one word that answers the
            // question. It was then cut to "Speaker" to save the bar 250px.
            // That trade is over: the bar now has somewhere to put a name that
            // does not fit, so the full name is shown and the row is measured
            // rather than guessed at.
            //
            // 2 · The level and the device were one undifferentiated run of
            // text: "50%  700 Series Chipset Family HD Audio Speaker". Nothing
            // said which half was the number. They are now split by a rule, so
            // the eye lands on the level, then reads the device as a label.
            RowLayout {
                id: soundInlineRow
                Layout.fillWidth: true
                spacing: 8
                // The device's FULL name, and the row's real measured width.
                //
                // The name used to be shortened ("Speaker" for "700 Series
                // Chipset Family HD Audio Speaker") against a hard 150px cap,
                // with the long form waiting in a tooltip. That is the same
                // trade this bar has just been told to stop making everywhere
                // else: if the full name does not fit beside the icons, the
                // pocket DROPS under the bar, where there is room for all of
                // it. Nothing is abbreviated, so nothing needs a tooltip to
                // recover what was hidden.
                readonly property string deviceName: Audio.sink?.description
                    || Audio.sink?.name || Translation.tr("No output device")
                // Two gaps (three children) + the 1px rule, then the name as
                // wide as it actually is.
                readonly property real naturalWidth: pct.implicitWidth + (spacing * 2) + 1
                    + deviceLabel.implicitWidth

                // ── The level ────────────────────────────────────────────
                // Measured at its NATURAL width, no fixed 40px box: the old box
                // reserved "100" of room for every value, so "80%" sat
                // right-aligned with a slab of dead air on its left and the
                // separator's left gap read double the right one (the
                // "separator | spacing not symmetrical" report). Natural width
                // makes both gaps exactly `spacing` (8px), whatever the number.
                StyledText {
                    id: pct
                    Layout.alignment: Qt.AlignVCenter
                    // Through `currentVolume`, so the number is on the shell's
                    // own scale (100% = the loud end) and this pill can never
                    // read "200%": the sink's own value is a fraction of two.
                    text: (Audio.sink?.audio?.muted ?? false)
                        ? Translation.tr("Muted")
                        : `${Math.round(Audio.currentVolume() * 100)}%`
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    font.weight: Font.Medium
                    color: (Audio.sink?.audio?.muted ?? false) ? Appearance.colors.colOutline : Appearance.colors.colPrimary
                    horizontalAlignment: Text.AlignRight
                }
                // The separator that turns one run of text into two labelled
                // facts. Deliberately dim and 1px: it has to say "these are
                // separate" without becoming a thing you look at.
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 11
                    color: Appearance.colors.colOutline
                    opacity: 0.5
                }
                // ── The device ───────────────────────────────────────────
                StyledText {
                    id: deviceLabel
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    text: soundInlineRow.deviceName
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    color: Appearance.colors.colOnLayer0
                }
            }
            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => {
                    if (!Audio.sink?.audio) return;
                    if (root.padScrollBlocked) { event.accepted = true; return; }
                    const step = event.angleDelta.y > 0 ? 0.05 : -0.05;
                    // Through the door, so the step is 5% of the shell's scale
                    // and the ceiling is 100% -- the same 2.0 sink value the
                    // rail ends at.
                    Audio.setSinkVolume(Audio.currentVolume() + step);
                    if (Audio.sink.audio.muted && step > 0) Audio.sink.audio.muted = false;
                    event.accepted = true;
                }

    }
}


        // NETWORK: connection name, ssid and signal -- the "which network and
        // how good" glance.
        PocketColumn {
            id: networkPocket
            visible: pocketHost.resolvedId === "network"
            inlineEligible: true
            PocketLine {
                label: Network.ethernet ? Translation.tr("Wired") : Translation.tr("Wi-Fi")
                // The value is `networkIdentity` -- the address on the wire,
                // the SSID on the radio -- for the reason documented there:
                // a wired connection's NAME cannot tell one wired link from
                // another, and it is the one line the user hovers this icon
                // to read.
                //
                // Inline, the row may now use up to the whole slot between the
                // centre island and the icons (inlineCapW). Those values should
                // never be truncated in inline mode; the fit test is conservative
                // for them and the layout gives each of them to their natural
                // width when they fit, and hides them (never elides) when they
                // would not.
                // The signal percentage is appended on the WIFI branch only.
                // It used to be appended unconditionally, which put a Wi-Fi
                // strength reading next to a wired link: "Wired · Wired
                // connection 1 · 85%", a number describing a radio that is
                // not carrying the traffic.
                // Inline: the network row may now use up to the whole slot
                // between the centre island and the icons (inlineCapW), just
                // like the other right-icon pockets. The island grows to that
                // full natural width when it fits, and the row is hidden (never
                // elided) when it would not.
                value: root.networkIdentity
                    + (!Network.ethernet && Network.networkStrength > 0
                        ? ` · ${Network.networkStrength}%` : "")
            }
        }

        // BLUETOOTH
        PocketColumn {
            id: bluetoothPocket
            visible: pocketHost.resolvedId === "bluetooth"
            inlineEligible: true
            PocketLine {
                label: Translation.tr("Bluetooth")
                value: !BluetoothStatus.enabled ? Translation.tr("Off")
                    : (BluetoothStatus.firstActiveDevice?.name ?? Translation.tr("Not connected"))
            }
        }

        // PINNED QUICK TOGGLES -- every one of them, present and future.
        //
        // These had a tooltip and nothing else, so a hover gave no bar-level
        // answer at all: the bar's line, the surface every other icon uses, said
        // nothing for them. A pin is no less worth knowing about -- "Night
        // Light · Inactive" is exactly the kind of fact that line exists for.
        //
        // One pocket rather than nine: `hoveredPinName`/`Status` are set by the
        // pin's own hover handler, so a quick toggle pinned later is covered
        // without another pocket to write.
        PocketColumn {
            id: pinPocket
            visible: pocketHost.resolvedId === "pin"
            inlineEligible: true
            PocketLine {
                label: root.hoveredPinName
                value: root.hoveredPinStatus
            }
        }

        // VPN -- the last indicator without a line of its own. Its glyph says
        // whether the tunnel is up, which is why it went without one, but "up
        // to what" lived only in a tooltip.
        PocketColumn {
            id: vpnPocket
            visible: pocketHost.resolvedId === "vpn"
            inlineEligible: true
            PocketLine {
                label: Translation.tr("VPN")
                value: !Tailscale.installed ? Translation.tr("Not installed")
                    : (Tailscale.connected ? Translation.tr("Connected") : Translation.tr("Off"))
            }
        }

        // BATTERY: one line, in the order the eye wants it -- the level, the
        // number, then the rest of the story (state, time left, draw) as one
        // eliding tail. A second row cannot exist inline: the island is one
        // bar-height tall, and a second line in it is a clipped first line.
        PocketColumn {
            id: batteryPocket
            visible: pocketHost.resolvedId === "battery"
            inlineEligible: true
            RowLayout {
                id: batteryInlineRow
                Layout.fillWidth: true
                spacing: 10
                // The row's NATURAL width, measured from the row itself.
                //
                // It used to be stated on the POCKET (batteryPocket), naming
                // `gaugeItem`/`pct`/`tail` -- ids that live in here. An id is
                // not visible in an enclosing scope, so that binding threw
                // "ReferenceError: gaugeItem is not defined" on every layout
                // pass and the pocket fell back to the column's own guess. The
                // row's own implicit width IS this number (a layout's implicit
                // width is its children's preferred/implicit widths plus the
                // spacing), so it is stated here where it can be measured.
                readonly property real naturalWidth: implicitWidth
                // The level bar: a static gauge (not a slider — charge is not
                // something you scrub), XS-thin. Fixed width so the number and
                // the tail keep their places while the value ticks.
                Item {
                    Layout.preferredWidth: 64
                    Layout.preferredHeight: 12
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 6
                        radius: 3
                        color: Appearance.colors.colLayer1
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(6, parent.width * Math.max(0, Math.min(1, Battery.percentage)))
                            height: parent.height
                            radius: 3
                            color: Battery.isCharging ? "#2BD86B"
                                : Battery.percentage < 0.2 ? Appearance.colors.colError
                                : Appearance.colors.colPrimary
                            Behavior on width {
                                animation: Appearance.animation.elementMoveSmall.numberAnimation.createObject(this)
                            }
                            Behavior on color {
                                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                            }
                        }
                    }
                }
                StyledText {
                    Layout.preferredWidth: 38
                    Layout.alignment: Qt.AlignVCenter
                    text: Math.round(Battery.percentage * 100) + "%"
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    font.weight: Font.Medium
                    color: Battery.isCharging ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
                    horizontalAlignment: Text.AlignRight
                }
                StyledText {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    text: {
                        const state = Battery.isCharging ? Translation.tr("Charging")
                            : Battery.isPluggedIn ? Translation.tr("Plugged in")
                            : Translation.tr("On battery");
                        const s = Battery.isCharging ? Battery.timeToFull : Battery.timeToEmpty;
                        let time = "";
                        if (s > 0) {
                            const h = Math.floor(s / 3600), m = Math.round((s % 3600) / 60);
                            time = (Battery.isCharging ? Translation.tr("full in") : Translation.tr("empty in"))
                                + (h > 0 ? ` ${h} h ${m} min` : ` ${m} min`);
                        }
                        const draw = `${Battery.energyRate.toFixed(1)} W`;
                        return [state, time, draw].filter(Boolean).join(" · ");
                    }
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }
            }
            // Inline, the row may now use up to the whole slot between the
            // centre island and the icons (inlineCapW), so there is no
            // hidden truncation path on the bar itself: the fit test and the
            // settled layout both use the same budget, and the row is only
            // hidden (never elided) when even that full slot would not hold
            // this single line. That is the same rule the other right-icon
            // pockets already use. (Its width is declared on the row above.)
        }

        // NOTIFICATIONS: the last notification as it arrived -- the hover
        // preview for the unread chip (left of the battery). The chip's own
        // click still opens the right sidebar's notification list; this answers
        // "what came in?" without leaving the bar.
        PocketColumn {
            id: notificationsPocket
            visible: pocketHost.resolvedId === "notifications"
            inlineEligible: true
            // ONE line: who, when, and what -- in that order, eliding from the
            // right. The three stacked rows this used to be needed a box of its
            // own; inline, the body cannot wrap, so the whole notification is
            // one string and the island's cap decides how much of it is read.
            readonly property var last: Notifications.list.length > 0 ? Notifications.list[0] : null
            readonly property string lastTime: {
                const n = notificationsPocket.last;
                if (!n || !(n.time > 0)) return "";
                const ms = n.time > 1e12 ? n.time : n.time * 1000;
                return Qt.formatDateTime(new Date(ms), "HH:mm");
            }
            StyledText {
                Layout.fillWidth: true
                // The app name in the accent colour is what tells you WHERE the
                // notification came from at a glance, so it stays; the summary
                // carries the content and the body is the fallback when there
                // is no summary. Inline, whatever runs long is cut at the
                // island's cap -- the same slot the other right-icon pockets
                // use, so the truncation path is one place and no longer this
                // pocket's own middle-isle wall).
                text: {
                    const n = notificationsPocket.last;
                    if (!n) return Translation.tr("No notifications");
                    const what = (n.summary && n.summary.length > 0) ? n.summary : (n.body ?? "");
                    return [`${n.appName}${notificationsPocket.lastTime ? " · " + notificationsPocket.lastTime : ""}`, what]
                        .filter(Boolean).join(" — ");
                }
                font.pixelSize: Appearance.font.pixelSize.smallie
                font.weight: Font.Medium
                color: Appearance.colors.colPrimary
                elide: Text.ElideRight
            }
        }

        // METER: brightness + volume, live, while either is being changed.
        // This is the extended-top-bar answer to "what am I changing": the
        // island extends the way it already does on icon hover, and instead of
        // a floating label the two readings sit in the row -- accent-coloured
        // on whichever half is actively changing, dim on the other. StatusSignal
        // owns the show clock (re-armed per change, so a swipe keeps it up).
        PocketColumn {
            id: meterPocket
            visible: pocketHost.resolvedId === "meter"
            inlineEligible: true
            readonly property bool briLive: StatusSignal.meterLive
                && StatusSignal.meterKind === "brightness"
            readonly property bool volLive: StatusSignal.meterLive
                && StatusSignal.meterKind === "volume"
            // ONE row at a time: the value being changed. The other reading
            // is still there when nothing is live (idle state), so the row
            // never empty -- but the moment a swipe starts, the island shows
            // exactly the thing being changed and nothing else.
            readonly property bool showBrightness: briLive
                || (!volLive && StatusSignal.meterKind !== "volume")
            PocketLine {
                visible: meterPocket.showBrightness
                label: Translation.tr("Brightness")
                value: Math.round(Brightness.brightnessFraction() * 100) + "%"
                accent: meterPocket.briLive ? Appearance.colors.colTertiary : "transparent"
            }
            PocketLine {
                visible: !meterPocket.showBrightness
                label: Translation.tr("Volume")
                value: Math.round(Audio.currentVolume() * 100) + "%"
                accent: meterPocket.volLive ? Appearance.colors.colPrimary : "transparent"
            }
        }

        // Arms the meter pocket when a value starts changing, retires it when
        // the meter goes quiet. Never fights a pocket the pointer itself
        // opened: arming only happens when nothing else is showing, and the
        // retire only takes down the meter's own pocket.
        Connections {
            target: StatusSignal
            function onMeterLiveChanged() {
                if (StatusSignal.meterLive) {
                    if (LiquidBar.pocketId === "" && root.inlinePocketId === "")
                        root.armPocket("meter", root.centerXFor(soundButton),
                            root.rightIslandLeft, root.rightIslandRight);
                } else if (root.inlinePocketId === "meter" || LiquidBar.pocketId === "meter") {
                    root.armPocket("", root.centerXFor(soundButton),
                        root.rightIslandLeft, root.rightIslandRight);        }

    }
}


        // The status twin: arms the extended island whenever the launch
        // lifecycle has something to say -- a wait ("Opening Firefox"), a
        // failure ("Couldn't open X", red), an already-open notice, a
        // download. The line stays the colour face of the same fact; this is
        // where the words live. Same courtesy rule as the meter: a pocket the
        // pointer opened is never yanked away, and the retire only takes down
        // the status's own pocket.
        Connections {
            target: StatusSignal
            function onLoadingLineChanged() {
                const show = StatusSignal.loadingLine || GlobalStates.loadingInfo;
                if (show) {
                    if (LiquidBar.pocketId === "" && root.inlinePocketId === "")
                        root.armPocket("status", root.centerXFor(soundButton),
                            root.rightIslandLeft, root.rightIslandRight);
                } else if (!GlobalStates.loadingFailureInBar
                    && (root.inlinePocketId === "status" || LiquidBar.pocketId === "status")) {
                    root.armPocket("", root.centerXFor(soundButton),
                        root.rightIslandLeft, root.rightIslandRight);        }

    }
}

        // Also arm the status pocket as soon as a launch is pending, so
        // fast launches (which arrive before the 600ms loading-line grace)
        // still get the "Opening X…" text in the extended island. The
        // loading-line path covers slow launches; this covers the rest.
        // Retirement is handled by onLoadingLineChanged (for slow launches)
        // and onLoadingPendingChanged (for fast launches that never trigger
        // the loading line).
        Connections {
            target: GlobalStates
            function onLoadingPendingChanged() {
                const isPlainWait = GlobalStates.loadingPending
                    && !GlobalStates.loadingFailed && !GlobalStates.loadingInfo;
                if (isPlainWait && LiquidBar.pocketId === "" && root.inlinePocketId === "") {
                    root.armPocket("status", root.centerXFor(soundButton),
                        root.rightIslandLeft, root.rightIslandRight);
                } else if (!GlobalStates.loadingPending
                    // A failure that owns the row (see loadingFailureInBar) is
                    // NOT an ending: the wait's retire must not take the row
                    // down the instant the failure replaces it.
                    && !GlobalStates.loadingFailureInBar
                    && (root.inlinePocketId === "status" || LiquidBar.pocketId === "status")) {
                    root.armPocket("", root.centerXFor(soundButton),
                        root.rightIslandLeft, root.rightIslandRight);
                }
            }
            // The open row's TEXT can change while it is already on screen:
            // a second click folds into the pending-launch guard by
            // rewriting `loadingText`, and a download rewrites it with its
            // own name. Re-judge the fit on exactly the measurement the fit
            // test uses, so a row that arrived short and is then handed a
            // longer name switches to the drop (still up, full text) instead
            // of eliding in place -- which is the truncation this row was
            // promised it would never do.
            function onLoadingTextChanged() {
                if (!root.inlineMode || root.inlinePocketId !== "status")
                    return;
                root.armPocket("status", root.centerXFor(soundButton),
                        root.rightIslandLeft, root.rightIslandRight, true);
            }
        }


        // Continuous loading state's OPEN right-icon pocket (network, bluetooth,
        // battery, meter, notifications) never gets the status row swapped in
        // over it without the loading line being retired first -- that is the
        // "only statusLife arms the status pocket" path. So this connection is
        // the ONE arm/retire for the loading-status pocket, and the lone
        // reported symptom for it ("Loading" stays) is answered by retiring the
        // loading line elsewhere; here it either arms the status row from
        // nothing, or stands down when loading ends and the line is gone.
        Connections {
            target: GlobalStates
            function onLoadingPendingChanged() {
                const isPlainWait = GlobalStates.loadingPending
                    && !GlobalStates.loadingFailed && !GlobalStates.loadingInfo;
                if (isPlainWait && LiquidBar.pocketId === "" && root.inlinePocketId === "") {
                    root.armPocket("status", root.centerXFor(soundButton),
                        root.rightIslandLeft, root.rightIslandRight);
                } else if (!GlobalStates.loadingPending
                    // A failure that owns the row (see loadingFailureInBar) is
                    // NOT an ending: the wait's retire must not take the row
                    // down the instant the failure replaces it.
                    && !GlobalStates.loadingFailureInBar
                    && (root.inlinePocketId === "status" || LiquidBar.pocketId === "status")) {
                    root.armPocket("", root.centerXFor(soundButton),
                        root.rightIslandLeft, root.rightIslandRight);
                }
            }
            // The notice and the failure end without touching `loadingPending`
            // (both start with it already false), so their own endings take the
            // row down here. 
            function onLoadingInfoChanged() { root.retireStatusRow(); }
            function onLoadingFailedChanged() { root.retireStatusRow(); }
            // A LAUNCH FAILURE is the row's own message now (the corner card
            // is gone for it), so it arms the row itself and holds it for the
            // failure's twelve seconds. Its retirement runs through the same
            // idle test, which is what keeps one state machine in charge.
            function onLoadingFailureInBarChanged() {
                if (GlobalStates.loadingFailureInBar) {
                    if (LiquidBar.pocketId === "" && root.inlinePocketId === "")
                        root.armPocket("status", root.centerXFor(soundButton),
                            root.rightIslandLeft, root.rightIslandRight);
                } else {
                    root.retireStatusRow();
                }
            }
        }


        // STATUS: "Opening Firefox" / "Couldn't open Firefox" / "X is already
        // open" / "Downloading X" -- the launch lifecycle in the extended
        // island, matching the under-bar line that carries the same fact as a
        // colour. The corner card keeps the long-form messages; this is the
        // glanceable twin of the line's charge/red faces.
        PocketColumn {
            id: statusPocket
            visible: pocketHost.resolvedId === "status"
            inlineEligible: true
            // The row's width, stated rather than measured: the Text items
            // inside lag the string by a polish pass, and the host sizing
            // below reads THIS number in the same frame the pocket is armed
            // -- so the island is grown to the new name's width immediately
            // and the value never starts its life inside a too-narrow row.
            // Inline, the host's width is already capped at the middle-isle
            // wall, so a very long application name is allowed to claim up to
            // the whole run between the centre island and the icons, without
            // being truncated to "…". The host still clips it for a frame or
            // two while it recognises the new width, but the settled row is
            // always the full natural width -- and the drop was only ever
            // the status row's second surface, so this path is now dead code
            // under the new always-inline rule (statusNaturalW vs inlineCapW
            // was the last remaining status decision, already removed).
            naturalWidthOverride: root.statusNaturalW
            PocketLine {
                // A launch in progress is the one case where the row's own
                // heading beats the generic one: "Opening" says what is
                // happening, where "Status" only said that something was --
                // and the value beside it is the bare app name, so the pair
                // read as "Status freebuff", which names the fact without
                // stating it. Everything else this channel carries is
                // already a sentence ("Couldn't open X", "X is already
                // open") and reads correctly under the old label, so the
                // substitution is deliberately narrow.
                readonly property bool plainWait: GlobalStates.loadingPending
                    && !GlobalStates.loadingFailed && !GlobalStates.loadingInfo
                // A launch in flight announces what is starting, so the row
                // names the app the user just clicked on and then goes away
                // again when the window arrives. The label carries "Opening …"
                // and the value carries the bare app name, so the pair reads
                // as "Opening Thunderbird" without a generic "Status:" label
                // in front of it.
                label: plainWait
                    ? Translation.tr("Opening")
                    : Translation.tr("Status")
                // Priority: battery alert ("Low battery" -- rare, urgent) >
                // download (name + %) > the launch lifecycle's own sentence
                // ("Opening Firefox" / "Couldn't open X" / "already open").
                value: {
                    if (StatusSignal.hasBatteryAlert)
                        return StatusSignal.batteryAlert.text;
                    // Charger in/out: the blink's own sentence ("Battery
                    // charging"), so the green flash is named where the
                    // extended island can be read.
                    if (loadingLine.blinkLive && loadingLine.blinkText !== "")
                        return loadingLine.blinkText;
                    if (GlobalStates.downloadProgress >= 0 && GlobalStates.downloadName !== "")
                        return GlobalStates.downloadName
                            + " · " + Math.round(GlobalStates.downloadProgress * 100) + "%";
                    // The name, plus the ellipsis that says "not here yet".
                    // Only on a plain wait: the failure and notice texts are
                    // whole sentences and take no suffix.
                    // No trailing "…" anywhere. It was meant as the "not
                    // here yet" mark, but it is visually identical to the
                    // elision mark, so on the inline row it read as "cut
                    // off" -- the exact report -- and on the drop it read as
                    // nothing at all. The wait is already carried by the
                    // accent colour and the under-island line; the name
                    // stands alone, whole, in both presentations.
                    //
                    // And only while the lifecycle is LIVE. `loadingText` is a
                    // plain string that outlives the card in older state (see
                    // GlobalStates.finishLoading), so the row must ask the
                    // lifecycle, not the string, whether it has anything to
                    // say -- otherwise it keeps painting the last app opened.
                    const waitLive = GlobalStates.loadingPending
                        || GlobalStates.loadingFailed || GlobalStates.loadingInfo
                        || GlobalStates.loadingFailureInBar;
                    return waitLive ? (GlobalStates.loadingText || "") : "";

                }
                // Battery alert and launch failure take the error colour; a
                // plain wait takes the primary accent so "Opening …" reads
                // as live.
                //
                // The failure BLINKS here, on the same clock as the bar line
                // under the island (StatusSignal.loadingFailOn), rather than
                // sitting at one flat red. Two reasons, and both are the point
                // of the request this answers:
                //
                //   * The line is 2px tall and sits in the gap below the bar.
                //     The extended top tab is the surface the user is actually
                //     looking at when a launch fails, and it was showing the
                //     sentence in a colour that did not move -- so on the tab
                //     the failure read as a state, not as an event.
                //   * On the OFF beat the value drops to the ordinary body
                //     colour instead of going invisible, so the row keeps its
                //     shape and the flash reads as THIS ROW blinking rather
                //     than as the content appearing and disappearing.
                //
                // `accent` is the row's single colour hook (label and value
                // both read it), so one expression drives the whole blink.
                accent: StatusSignal.hasBatteryAlert
                    ? Appearance.colors.colError
                    : (GlobalStates.loadingFailureInBar
                        // Steady, not blinking: the message IS the failure, so
                        // the words hold still while the screen's edge does the
                        // pointing (see ScreenFlash's held mode).
                        ? Appearance.colors.colError
                        : (GlobalStates.loadingFailFlash
                            ? (StatusSignal.loadingFailOn
                                ? Appearance.colors.colError
                                : ColorUtils.transparentize(Appearance.colors.colError, 0.72))
                            : (loadingLine.blinkLive && loadingLine.blinkText !== ""
                                ? loadingLine.blinkColor
                                : (StatusSignal.loadingLine ? Appearance.colors.colPrimary : "transparent"))))
            }
        }

        // MEDIA: the title stays visible in the bar row, so the pocket spends
        // its one line on what the title does not say -- who is playing it, and
        // which app is doing the playing. Inline, this line may use the full
        // right-icon slot the other right-icon pockets use, so it is never
        // silently truncated on the bar itself: the fit test and the settled
        // layout both use the same budget, and the row is only hidden (never
        // elided) when the slot would not hold the whole line.
        PocketColumn {
            id: mediaPocket
            visible: pocketHost.resolvedId === "media"
            inlineEligible: true
            PocketLine {
                label: Translation.tr("Playing")
                value: [barContent.mediaArtist, barContent.mediaPlayerName]
                    .filter(t => t && t.length > 0).join(" · ")
            }
        }

        // ── NOW BAR: the middle island's extended detail ────────────────
        // GlobalStates.nowBarMode says which view it is showing (0 pomodoro /
        // 1 media / 2 AI / 3 performance).
        //
        // The box FITS its content: the size is measured from whichever view
        // is live instead of the fixed 300x96 slab it was, which cropped the
        // taller sections and left others swimming in empty space. The host
        // adds one even frame around this -- padV above and below the mouth
        // line, sidePad to each wall -- so the content lands centered with
        // the same clearance on every side. Width is quantized UP in 8px
        // steps (dropW), so a live value can still never twitch the box.
        Item {
            id: nowbarPocket
            visible: pocketHost.resolvedId === "nowbar"
            implicitWidth: Math.max(pomodoroView.implicitWidth, mediaView.implicitWidth,
                aiView.implicitWidth, perfView.implicitWidth)
            implicitHeight: Math.max(pomodoroView.implicitHeight, mediaView.implicitHeight,
                aiView.implicitHeight, perfView.implicitHeight)

            // The machine's four readings -- the same data the island shows
            // (NowBar's perfGauges), spelled out with the labels the island
            // has no room for. Static like the island's list: the live half
            // is read inside the delegates through perfValue / perfLoad /
            // perfHistory below, so a sampling tick re-binds the numbers
            // instead of rebuilding the row (a changing model makes the
            // Repeater recreate every tile, which flickers the whole view).
            readonly property var perfGauges: [
                { key: "cpu", name: Translation.tr("CPU"), icon: "planner_review", accent: Appearance.colors.colPrimary },
                { key: "ram", name: Translation.tr("RAM"), icon: "memory", accent: Appearance.colors.colTertiary },
                { key: "gpu", name: Translation.tr("GPU"), icon: "developer_board", accent: Appearance.colors.colSecondary },
                { key: "temp", name: Translation.tr("Temp"), icon: "thermostat", accent: Appearance.colors.colError }
            ]

            // The live half of perfGauges; see NowBar for the full story on
            // why these are functions instead of model entries.
            function perfValue(key) {
                if (key === "cpu") return SystemNow.pct(SystemNow.cpuPct);
                if (key === "ram") return SystemNow.pct(SystemNow.ramPct);
                if (key === "gpu") return SystemNow.pct(SystemNow.gpuClockPct);
                if (key === "temp") return SystemNow.tempText(SystemNow.tempC);
                return "--";
            }
            function perfLoad(key) {
                if (key === "cpu") return SystemNow.cpuPct;
                if (key === "ram") return SystemNow.ramPct;
                if (key === "gpu") return SystemNow.gpuClockPct;
                if (key === "temp") return SystemNow.tempLoad(SystemNow.tempC);
                return -1;
            }

            readonly property int mode: GlobalStates.nowBarMode
            readonly property var player: MprisController.activePlayer
            readonly property var track: MprisController.activeTrack

            // Which service is playing: the player's own identity when it is a
            // dedicated app, its track metadata when it is a browser.
            readonly property string provider: {
                const p = nowbarPocket.player;
                if (!p) return "";
                const id = (p.identity ?? "").toLowerCase();
                if (id.includes("spotify")) return "Spotify";
                if (id.includes("youtube")) return "YouTube Music";
                const src = `${p.trackArtUrl ?? ""} ${nowbarPocket.track?.url ?? ""}`.toLowerCase();
                if (src.includes("music.youtube")) return "YouTube Music";
                if (src.includes("youtube")) return "YouTube";
                if (src.includes("spotify")) return "Spotify";
                return p.identity ?? "";
            }
            readonly property real progress: {
                const p = nowbarPocket.player;
                const len = p?.length ?? 0;
                if (!len || len <= 0) return 0;
                return Math.max(0, Math.min(1, (p?.position ?? 0) / len));
            }
            // Same normalization as the island: a string or a list.
            readonly property string artistText: {
                const a = nowbarPocket.player?.trackArtists ?? "";
                return Array.isArray(a) ? a.join(", ") : String(a);
            }
            function clock(sec) {
                const s = Math.max(0, Math.floor(sec ?? 0));
                return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
            }

            // ── 0 · Pomodoro detail ─────────────────────────────────────
            ColumnLayout {
                id: pomodoroView
                visible: nowbarPocket.mode === 0
                anchors.fill: parent
                spacing: 6
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        width: 10
                        height: 10
                        radius: 5
                        color: Appearance.colors.colError
                    }
                    StyledText {
                        text: nowbarPocket.clock(TimerService.pomodoroSecondsLeft)
                        font.family: Appearance.font.family.monospace
                        font.pixelSize: Appearance.font.pixelSize.large
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnLayer0
                    }
                    StyledText {
                        Layout.alignment: Qt.AlignBottom
                        text: Translation.tr("timer")
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colSubtext
                    }
                    Item { Layout.fillWidth: true }
                    RippleButton {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: 26
                        implicitHeight: 26
                        colRipple: Appearance.colors.colLayer1Hover
                        onClicked: TimerService.togglePomodoro()
                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: TimerService.pomodoroRunning ? "pause" : "play_arrow"
                            iconSize: 18
                            fill: 1
                            color: Appearance.colors.colOnLayer0
                        }
                    }
                    RippleButton {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: 26
                        implicitHeight: 26
                        colRipple: Appearance.colors.colLayer1Hover
                        onClicked: TimerService.resetPomodoro()
                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: "restart_alt"
                            iconSize: 18
                            color: Appearance.colors.colOnLayer0
                        }
                    }
                }
                StyledText {
                    Layout.fillWidth: true
                    Layout.maximumWidth: 240
                    text: TimerService.pomodoroRunning
                        ? Translation.tr("Running · tap the island to pause")
                        : Translation.tr("Paused · tap the island to start")
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }
            }

            // ── 1 · Media detail ────────────────────────────────────────
            RowLayout {
                id: mediaView
                visible: nowbarPocket.mode === 1
                anchors.fill: parent
                spacing: 12

                // Cover art, as the service serves it (MPRIS art URL).
                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    implicitWidth: 62
                    implicitHeight: 62
                    radius: Appearance.rounding.small
                    color: Appearance.colors.colLayer1
                    clip: true
                    IconImage {
                        anchors.fill: parent
                        source: nowbarPocket.player?.trackArtUrl ?? ""
                        asynchronous: true
                        visible: (nowbarPocket.player?.trackArtUrl ?? "") !== ""
                    }
                    MaterialSymbol {
                        anchors.centerIn: parent
                        visible: (nowbarPocket.player?.trackArtUrl ?? "") === ""
                        text: "music_note"
                        iconSize: 26
                        color: Appearance.colors.colOutline
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 2

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        // Provider badge: Spotify / YouTube / YouTube Music.
                        Rectangle {
                            visible: nowbarPocket.provider !== ""
                            implicitWidth: badgeText.implicitWidth + 12
                            implicitHeight: 16
                            radius: 8
                            color: ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.2)
                            StyledText {
                                id: badgeText
                                anchors.centerIn: parent
                                text: nowbarPocket.provider
                                font.pixelSize: Appearance.font.pixelSize.tiny
                                color: Appearance.colors.colPrimary
                            }
                        }
                        StyledText {
                            Layout.fillWidth: true
                            Layout.maximumWidth: 225
                            text: nowbarPocket.track?.album ?? ""
                            font.pixelSize: Appearance.font.pixelSize.tiny
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideRight
                        }
                    }
                    StyledText {
                        Layout.fillWidth: true
                        Layout.maximumWidth: 225
                        text: MprisController.mediaTitle(nowbarPocket.player) || Translation.tr("Nothing playing")
                        font.pixelSize: Appearance.font.pixelSize.small
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnLayer0
                        elide: Text.ElideRight
                    }
                    StyledText {
                        Layout.fillWidth: true
                        Layout.maximumWidth: 225
                        text: nowbarPocket.artistText
                        font.pixelSize: Appearance.font.pixelSize.smallie
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }
                    // Progress: position / duration.
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 10
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width
                            height: 3
                            radius: 1.5
                            color: Appearance.colors.colLayer1
                            Rectangle {
                                width: parent.width * nowbarPocket.progress
                                height: parent.height
                                radius: 1.5
                                color: Appearance.colors.colPrimary
                                Behavior on width {
                                    animation: Appearance.animation.elementMoveSmall.numberAnimation.createObject(this)
                                }
                            }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        StyledText {
                            text: nowbarPocket.clock(nowbarPocket.player?.position ?? 0)
                            font.family: Appearance.font.family.monospace
                            font.pixelSize: Appearance.font.pixelSize.tiny
                            color: Appearance.colors.colSubtext
                        }
                        Item { Layout.fillWidth: true }
                        StyledText {
                            text: nowbarPocket.clock(nowbarPocket.player?.length ?? 0)
                            font.family: Appearance.font.family.monospace
                            font.pixelSize: Appearance.font.pixelSize.tiny
                            color: Appearance.colors.colSubtext
                        }
                        // Transport: previous / play-pause / next.
                        RippleButton {
                            implicitWidth: 22
                            implicitHeight: 22
                            colRipple: Appearance.colors.colLayer1Hover
                            onClicked: nowbarPocket.player?.previous()
                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: "skip_previous"
                                iconSize: 16
                                fill: 1
                                color: Appearance.colors.colOnLayer0
                            }
                        }
                        RippleButton {
                            implicitWidth: 22
                            implicitHeight: 22
                            colRipple: Appearance.colors.colLayer1Hover
                            onClicked: nowbarPocket.player?.togglePlaying()
                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: (nowbarPocket.player?.isPlaying ?? false) ? "pause" : "play_arrow"
                                iconSize: 16
                                fill: 1
                                color: Appearance.colors.colOnLayer0
                            }
                        }
                        RippleButton {
                            implicitWidth: 22
                            implicitHeight: 22
                            colRipple: Appearance.colors.colLayer1Hover
                            onClicked: nowbarPocket.player?.next()
                            MaterialSymbol {
                                anchors.centerIn: parent
                                text: "skip_next"
                                iconSize: 16
                                fill: 1
                                color: Appearance.colors.colOnLayer0
                            }
                        }
                    }
                }
            }

            // ── 2 · AI usage: the weekly schema ─────────────────────────
            // A GitHub-style grid over the last four weeks, built from the
            // provider's own reported history ([[timestamp, used], ...] per
            // window -- the same series the flare usage sheet draws).
            RowLayout {
                id: aiView
                visible: nowbarPocket.mode === 2
                anchors.fill: parent
                spacing: 14

                ColumnLayout {
                    Layout.alignment: Qt.AlignTop
                    Layout.preferredWidth: 150
                    spacing: 3
                    StyledText {
                        Layout.fillWidth: true
                        text: root.nowbarAiCell ? `${root.nowbarAiCell.name} · ${root.nowbarAiCell.plan}` : "AI idle"
                        font.pixelSize: Appearance.font.pixelSize.small
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnLayer0
                        elide: Text.ElideRight
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: root.nowbarAiCell?.todayText ?? ""
                        font.pixelSize: Appearance.font.pixelSize.smallie
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: root.nowbarAiWeeklySummary
                        font.pixelSize: Appearance.font.pixelSize.tiny
                        color: Appearance.colors.colSubtext
                        wrapMode: Text.WordWrap
                    }
                }

                // The grid: 7 columns (weekdays) x 4 rows (weeks), oldest
                // first, each cell shaded by the usage in force that day.
                ColumnLayout {
                    Layout.alignment: Qt.AlignTop
                    spacing: 4
                    Grid {
                        columns: 7
                        rowSpacing: 3
                        columnSpacing: 3
                Repeater {
                    objectName: "widgets"
                    model: ["M", "T", "W", "T", "F", "S", "S"]
                            StyledText {
                                required property string modelData
                                width: 12
                                horizontalAlignment: Text.AlignHCenter
                                text: modelData
                                font.pixelSize: Appearance.font.pixelSize.tiny
                                color: Appearance.colors.colSubtext
                            }
                        }
                        Repeater {
                            model: 28
                            Rectangle {
                                required property int index
                                readonly property var day: root.nowbarAiDays[index] ?? null
                                width: 12
                                height: 12
                                radius: 3
                                color: root.nowbarAiCellColor(day)
                            }
                        }
                    }
                    RowLayout {
                        spacing: 4
                        StyledText {
                            text: Translation.tr("less")
                            font.pixelSize: Appearance.font.pixelSize.tiny
                            color: Appearance.colors.colSubtext
                        }
                Repeater {
                    objectName: "widgets"
                    model: [0.0, 0.3, 0.55, 0.8, 1.0]
                            Rectangle {
                                required property real modelData
                                Layout.preferredWidth: 9
                                Layout.preferredHeight: 9
                                radius: 2
                                color: ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.15 + 0.85 * modelData)
                            }
                        }
                        StyledText {
                            text: Translation.tr("more")
                            font.pixelSize: Appearance.font.pixelSize.tiny
                            color: Appearance.colors.colSubtext
                        }
                    }
                }
            }

            // ── 3 · Performance detail ──────────────────────────────────
            // The island's four instruments spelled out: the full-size gauge
            // tiles (SystemGauge, not its compact island form) carry the
            // label, the caption and the sparkline the island strip has no
            // room for -- the same readings, with room to read them. The
            // pocket box sizes itself from this content, so nothing is
            // cropped and the two-column grid lands with the same clearance
            // as every other pocket.
            ColumnLayout {
                id: perfView
                visible: nowbarPocket.mode === 3
                anchors.fill: parent
                spacing: 8

                Grid {
                    columns: 2
                    columnSpacing: 18
                    rowSpacing: 6

                    Repeater {
                        model: nowbarPocket.perfGauges
                        SystemGauge {
                            required property var modelData
                            readonly property string key: modelData.key
                            icon: modelData.icon
                            label: modelData.name
                            value: nowbarPocket.perfValue(key)
                            caption: {
                                const l = nowbarPocket.perfLoad(key);
                                return l >= 0 ? Math.round(l * 100) + "% " + nowbarPocket.perfCaption(key) : "";
                            }
                            load: nowbarPocket.perfLoad(key)
                            history: nowbarPocket.perfHistory(key)
                            // The GPU's history is sampled four times a second
                            // rather than once, so the chart has to show fewer
                            // of its samples to cover a readable span -- see
                            // perfPoints and SystemNow.gpuWindowSeconds.
                            points: nowbarPocket.perfPoints(key)
                            accent: modelData.accent
                        }
                    }
                }
                StyledText {
                    Layout.fillWidth: true
                    Layout.maximumWidth: 360
                    text: nowbarPocket.perfSummary()
                    font.pixelSize: Appearance.font.pixelSize.tiny
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }
            }

            // Which history series feeds which instrument, and what its
            // number is a fraction of -- kept beside perfGauges so the
            // pocket can never disagree with itself.
            function perfHistory(key) {
                if (key === "cpu") return ResourceUsage.cpuUsageHistory;
                if (key === "ram") return ResourceUsage.memoryUsageHistory;
                // The busiest chip's series -- see SystemNow.gpuMetricPct.
                if (key === "gpu") return SystemNow.gpuMetricHistory;
                if (key === "temp") return SystemNow.tempLoadHistory;
                return [];
            }
            // How much of that history the chart draws. The processor's and
            // memory's arrive one per second, so all sixty are a readable
            // minute; the GPU's arrive four a second, and all sixty of THOSE
            // are fifteen seconds of the same samples drawn four times as
            // wide -- a step that only becomes a plateau once the window has
            // scrolled past it. SystemNow owns the number so this gauge, the
            // card's metric band and the island cannot disagree about it.
            function perfPoints(key) {
                return key === "gpu" ? SystemNow.gpuWindowPoints : 0;
            }
            function perfCaption(key) {
                if (key === "cpu") return Translation.tr("of all cores");
                if (key === "ram") return Translation.tr("of memory");
                // "utilization", not "of max clock": the number this pairs
                // with is the card's busy fraction (SystemNow.gpuClockPct),
                // not its clock over its ceiling. The tooltip reads "12%
                // utilization", which is what the GPU tile is actually
                // showing.
                if (key === "gpu") return Translation.tr("utilization");
                if (key === "temp") return Translation.tr("thermal load");
                return "";
            }
            function perfSummary() {
                let top = null;
                for (const g of nowbarPocket.perfGauges) {
                    const l = nowbarPocket.perfLoad(g.key);
                    if (l >= 0 && (!top || l > nowbarPocket.perfLoad(top.key)))
                        top = g;
                }
                if (!top) return Translation.tr("Waiting for readings…");
                return Translation.tr("Busiest right now: %1 at %2").arg(top.name).arg(nowbarPocket.perfValue(top.key));
            }
        }
    }

    // How tight this bar has to be, decided from the screen it landed on:
    // 0 = normal, 1 = shortened, 2 = hella shortened. Declared HERE with a
    // plain literal, and given its real value in onCompleted below -- the
    // decision needs the window's screen, which does not exist until the
    // component is complete.
    property real useShortenedForm: 0
    // `?.` and ternary-on-property-initializer are both parse errors in
    // this qs build, so these three stay un-initialized here and are filled
    // in by the ONE Component.onCompleted above (see the note there: a
    // second handler on this object would fail the whole config load).
    property var screen: undefined
    property var brightnessMonitor: undefined

    // `shownPlayer`, not `activePlayer`: the bar's Playing line follows the app
    // that is making sound right now (see MprisController), so stopping the
    // music hands the line to whatever else is playing -- a game, Discord, a
    // video -- instead of freezing on the song that was stopped.
    readonly property string mediaArtist: (MprisController.shownPlayer && MprisController.shownPlayer.trackArtist) ? MprisController.shownPlayer.trackArtist : ""
    // The name of what is actually being heard, audible browser tab included.
    readonly property string mediaPlayerName: MprisController.nowPlayingName

    // ── The now bar's AI detail: four weeks of usage ────────────────────
    // `history` on a flare cell is a map of window id -> [[timestamp, used],
    // ...] -- the same series the flare usage sheet draws. Four weeks of it,
    // one cell per day, shaded by the value in force at the end of that day.
    readonly property var nowbarAiCell: {
        const cells = FlareData.usageCells;
        return cells.find(c => c.metered && c.used !== null) ?? cells[0] ?? null;
    }
    readonly property var nowbarAiSeries: {
        const c = root.nowbarAiCell;
        if (!c)
            return [];
        const hist = c.history || {};
        const wid = c.head ? c.head.id : undefined;
        const series = hist[wid] ?? (Object.keys(hist).length > 0 ? hist[Object.keys(hist)[0]] : []) ?? [];
        return series.slice().sort((a, b) => a[0] - b[0]);
    }
    readonly property var nowbarAiDays: {
        const out = [];
        const dayLen = 86400;
        const today = Math.floor(Date.now() / 1000 / dayLen) * dayLen;
        for (let i = 27; i >= 0; i--) {
            const end = today - i * dayLen + dayLen;
            let v = null;
            for (const p of root.nowbarAiSeries) {
                if (p[0] <= end)
                    v = p[1];
                else
                    break;
            }
            out.push((v === null || !isFinite(v)) ? null : Math.max(0, Math.min(1, Number(v))));
        }
        return out;
    }
    readonly property string nowbarAiWeeklySummary: {
        const days = root.nowbarAiDays.filter(d => d !== null);
        if (days.length === 0)
            return Translation.tr("No history reported yet");
        const avg = days.reduce((a, b) => a + b, 0) / days.length;
        const peak = Math.max.apply(null, days);
        const pct = v => `${Math.round(v * 100)}%`;
        return Translation.tr("%1 of the last 28 days · avg %2 · peak %3")
            .arg(days.length).arg(pct(avg)).arg(pct(peak));
    }
    function nowbarAiCellColor(day) {
        if (day === null || day === undefined)
            return Appearance.colors.colLayer1;
        return ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.15 + 0.85 * day);
    }

    // ── The swipe hint: tick + chevrons, hover-only ────────────────────────
    // A short tick, vertically centred in the gap, with the UP chevron above
    // it and the DOWN chevron below it -- the two directions read spatially.
    // Appears ONLY while the cursor is over the gap and fades out when it
    // leaves: no loop, no breathing, no enlarging -- the fade in/out IS the
    // whole animation.
    // ── The gap hint: a joystick you can see ──────────────────────────────
    // The two empty stretches between the islands, where a two-finger vertical
    // swipe drives brightness (left) and volume (right).
    //
    // What is drawn there is a JOYSTICK, not a gauge. A line rests in the
    // middle between two chevrons and DOES NOT MOVE -- it is the
    // placeholder, and it is there for the whole gesture. What a swipe
    // pushes is that line's CONTENT: a smaller bar of the same accent lying
    // invisibly inside it, which slides out of the top or the bottom while
    // the line stays exactly where it is. Letting go always sends the
    // content back inside, and the line has not moved at all -- whatever
    // the brightness or the volume ended up being. An earlier version of
    // this drew the VALUE on the rail instead,
    // and that was wrong: the line was pinned to a height, so raising the
    // volume by one percent visibly moved a control nobody was touching, and
    // the thing the fingers were actually doing (which way, how far) was the
    // one thing it never showed. The value is not this widget's business.
    // The bar's own readouts and the OSD carry the number; this carries the
    // gesture.
    //
    // The chevrons stay as the FIRST indication: at rest, with the line
    // centred, they are what says "up and down are available here". They fade
    // as the line travels toward them, so the direction is carried by the
    // line once the gesture starts and the arrows do not compete with it.
    //
    // The hover area is the WHOLE gap, edge to edge, not a 40px box in the
    // middle of it. The artwork is centred inside this item, so widening the
    // item to the full gap moved nothing on screen -- it only made the hint
    // answer to the cursor anywhere in the spacing, which is what a gap is
    // for. A target you have to thread a hand into is a target you do not use.
    component SwipeGapHint: Item {
        id: gapHintRoot
        required property color accent
        required property bool upOnLeft
        // How far the gesture has pushed this gap's line, -1 (down) to +1
        // (up), 0 at rest. SIGNED displacement, not a value: see the note
        // above. The owning side zeroes it for the gap nobody is touching,
        // so a swipe in the brightness gap does not twitch the volume line.
        required property real push
        // A gesture owns this gap right now (past the dead zone, so the line
        // has actually left the middle).
        required property bool live
        // The cursor's x across the whole bar, and whether it is over the bar
        // at all. Fed from the bar's full-width tracker (see `cursorTrack`),
        // because this hint's own hover handler stops reporting the moment
        // the gap is covered -- which is exactly the case this needs.
        required property real cursorX
        required property bool cursorInBar
        // Whether the cursor is over the bar's MIDDLE -- the clock / now bar.
        //
        // The hold below keeps a line lit when the gap it lives in moves under
        // a cursor that has not left the bar, so that a swipe which grows an
        // island into its own gap does not make the line vanish mid-gesture.
        // That hold only asked "is the cursor still ON the bar", and the
        // middle is on the bar -- so once the centre island's width shifted at
        // all (the clock re-laying out, the now-bar pocket resizing, a
        // fraction of a pixel of reflow), `displaced` went true and both
        // lines stayed lit with the cursor parked on the middle of the bar,
        // which is where a cursor rests most of the time.
        //
        // The middle is not the island that grows into either gap, so the hold
        // has no business surviving there: it exists to cover the cursor
        // being slid sideways onto the ONE island that moved, and the centre is
        // not it. So the hold is cut wherever the cursor is over the middle.
        required property bool overCenterIsland
        // Whether a fullscreen window owns this monitor (Bar.qml's
        // `overFullscreen`, which is also what makes these gaps click-through
        // -- see `gapPassthrough`). It changes WHEN the hint is allowed to
        // appear, and nothing else about it.
        required property bool fullscreen
        HoverHandler { id: gapHover }
        readonly property bool hovered: gapHover.hovered
        // ── Hovering, versus the gap having moved ───────────────────────
        // The bug this fixes: raising the volume extends the RIGHT island
        // leftward across the gap. The cursor has not moved an inch, but it
        // is now over the island, so the gap's hover handler correctly says
        // "not over you" and the whole hint went away mid-gesture -- for
        // doing nothing but watching the volume change.
        //
        // The obvious fix is to let the island itself hover the hint, and
        // that is wrong: it would make the volume button's own hover arm the
        // swipe gesture, which is a different gesture with a different
        // meaning. So instead of widening the target, the hint holds itself
        // up through the moment when its own geometry moved.
        //
        // TWO independent reasons to hold, because the first attempt at this
        // did not work and the reason is worth recording:
        //
        //   1. `displaced` -- the gap is no longer the shape it was when the
        //      cursor was last genuinely on it. This one needs nothing but
        //      this item's own `x`/`width`, so it cannot be defeated by a
        //      cursor tracker that turns out not to report. It is the
        //      load-bearing half.
        //   2. `cursorUnmoved` -- the cursor is still within a pixel of
        //      where it was (needs the bar's full-width tracker). This is
        //      the half that keeps the hold honest: it releases the moment
        //      the user actually moves onto the island.
        //
        // `displaced` alone would keep the hint up for as long as the island
        // stays out, even if the user had walked off -- so it is conjoined
        // with the cursor still being on the bar (see `displaced`), and that
        // is what cuts that case short.
        //
        // `hasAnchor` is false until a genuine hover, and every term below is
        // gated on it, so parking the cursor on the right island from a cold
        // start shows nothing -- the constraint that ruled out the wide hit
        // area in the first place.
        property bool hasAnchor: false
        property real anchorGeomX: 0
        property real anchorGeomW: 0
        property real anchorCursorX: -1
        // Half a pixel of slack: the gap's width is fractional and reflows
        // can land a hair either way, and a spurious "displaced" would hold
        // the hint open on nothing.
        readonly property bool displaced: hasAnchor
            // AND the cursor is still somewhere on the bar. That conjunction
            // is the whole fix for a line that never went away.
            //
            // `displaced` says the gap is no longer the shape it was when the
            // cursor was last genuinely on it -- which is true for as long as
            // the island that grew into it stays grown. A swipe is what grows
            // it: changing the volume extends the right island leftward, and
            // changing the brightness does the same on the left, so the very
            // gesture that moved the control is the one that arms this hold.
            //
            // On its own it never expired. The note below predicted exactly
            // this -- "displaced alone would keep the hint up for as long as
            // the island stays out, even if the user had walked off" -- and
            // relied on `cursorUnmoved` to cut it short. But `cursorUnmoved`
            // requires `cursorInBar`, so the moment the cursor left the bar for
            // any reason the other half switched off and this one stayed on,
            // with nothing to bring it down: the line stayed lit at the top of
            // the screen for the rest of the session, after every swipe that
            // changed a value.
            //
            // The hold is for exactly one situation -- the gap moved under a
            // cursor that has not left the bar -- so that is what it now
            // tests. The cursor is not required to be within the pixel it was
            // anchored at: it may well have been slid sideways onto the island
            // that grew into the gap, which is the case the hold exists for.
            // It only has to still be ON the bar.
            && gapHintRoot.cursorInBar
            && (Math.abs(x - gapHintRoot.anchorGeomX) > 0.5
                || Math.abs(width - gapHintRoot.anchorGeomW) > 0.5)
        readonly property bool cursorUnmoved: hasAnchor && anchorCursorX >= 0
            && cursorInBar
            && cursorX > anchorCursorX - 1 && cursorX < anchorCursorX + 1
        readonly property bool hovering: gapHover.hovered
            || (!gapHintRoot.overCenterIsland && gapHintRoot.hasAnchor
                && (gapHintRoot.displaced || gapHintRoot.cursorUnmoved))
        // ── The hold must EXPIRE ───────────────────────────────────────
        // The gap moved under a cursor that has not left the bar, and the
        // hint holds itself up through that. Right for the moment it
        // describes, and a leak for as long as the cursor parks.
        //
        // The failure this closes is specific and was reported: swipe the
        // volume with the cursor resting on the bar, and the right island
        // grows leftward across the gap. `gapHover.hovered` goes false --
        // the island is now over the cursor -- so the anchor timer (which
        // only runs while `hovered`) stops, leaving the anchor frozen at
        // the pre-swipe geometry. `displaced` is then true FOREVER: the
        // gap is permanently "not the shape it was", the cursor is still
        // `cursorInBar`, and nothing re-anchors or clears it. The line
        // stays lit at the top of the screen for the rest of the session.
        //
        // A deadline is the only thing that ends it, and it must NOT be
        // renewed merely because the hold is still running -- that is the
        // leak. It is renewed on exactly one condition: THE GAP IS STILL
        // MOVING. A live gesture moves it every frame, so a genuine long
        // swipe keeps its hint; a cursor parked on a settled bar stops
        // moving it, and the hold runs out.
        readonly property int holdMs: 2500
        property real holdGeomX: 0
        property real holdGeomW: 0
        property real holdDeadline: 0
        Timer {
            id: holdClock
            interval: 200
            repeat: true
            // Only while the hold is what is keeping the hint up: a real
            // hover re-anchors on its own timer and needs none of this.
            running: gapHintRoot.hasAnchor && !gapHintRoot.hovered
            onTriggered: {
                const moved = Math.abs(gapHintRoot.x - gapHintRoot.holdGeomX) > 0.5
                    || Math.abs(gapHintRoot.width - gapHintRoot.holdGeomW) > 0.5;
                if (moved) {
                    // Still moving: the gesture is live. Re-arm.
                    gapHintRoot.holdGeomX = gapHintRoot.x;
                    gapHintRoot.holdGeomW = gapHintRoot.width;
                    gapHintRoot.holdDeadline = Date.now() + gapHintRoot.holdMs;
                } else if (gapHintRoot.holdDeadline === 0) {
                    gapHintRoot.holdDeadline = Date.now() + gapHintRoot.holdMs;
                }
                if (Date.now() > gapHintRoot.holdDeadline) {
                    gapHintRoot.hasAnchor = false;
                    gapHintRoot.holdDeadline = 0;        }

    }
}

        // ── When the hint is allowed to exist at all ───────────────────
        // Hovering the gap shows the hint, because hovering the gap is a
        // statement of intent -- that is where a swipe would land -- and a
        // live gesture shows it too.
        //
        // It used to be `fullscreen ? live : hovering`: over a fullscreen
        // window the hover was dropped and only fingers on the trackpad lit
        // the line. The reason was real when it was written, and it is kept
        // here so it is not re-invented: with `gapPassthrough` ON (Bar.qml)
        // these gaps are HOLES in the bar's input region -- a click meant for
        // the app underneath has to land on the app -- so the bar is never
        // told the pointer is there at all, and a cursor crossing the top
        // strip on its way into a game would light a mark in the corner of
        // it. Measured, with that cut live: `hover=false` in the gap over a
        // fullscreen window, however long the cursor sat there.
        //
        // The cut is OFF now (swiping in a gap scrolled the app under it too;
        // see the note on `gapPassthrough`), so the strip is one piece and the
        // pointer IS delivered across the spacing -- `hovering` goes true when
        // the cursor is genuinely on the bar and stays false when it is not.
        // Measured on this machine over a fullscreen window: `hover=true` in
        // the brightness gap, with the bar out.
        //
        // And "the bar out over a fullscreen window" is not a thing a cursor
        // passing by can produce: the bar only comes out there on the edge
        // press or the IPC, i.e. because someone asked for it, and it goes
        // again when that hold runs out. So a hover on the spacing in that
        // state is the same statement of intent it is anywhere else -- and
        // dropping it was the whole of "the hover indications are missing over
        // a fullscreen window".
        //
        // Keyed on the hover rather than on `fullscreen` so the two cannot
        // drift apart: turn the cut back on and the gaps stop reporting hover
        // by themselves, which restores the old behaviour through this same
        // expression.
        readonly property bool showing: gapHintRoot.hovering || gapHintRoot.live
        // Re-take the anchor for as long as the hover is real, so it always
        // describes the geometry the cursor is actually sitting in. Without
        // this an unrelated reflow -- the centre island's clock changing
        // width -- would leave a permanently "displaced" anchor and hold the
        // hint open long after the user had left. Cheap, and it only runs
        // while the hint is genuinely up.
        Timer {
            interval: 50
            repeat: true
            running: gapHintRoot.hovered
            onTriggered: {
                gapHintRoot.hasAnchor = true;
                gapHintRoot.anchorGeomX = gapHintRoot.x;
                gapHintRoot.anchorGeomW = gapHintRoot.width;
                gapHintRoot.anchorCursorX = gapHintRoot.cursorX;
                // A genuine hover is the anchor's own refresh, so it also
                // restarts the hold's clock and geometry watch.
                gapHintRoot.holdGeomX = gapHintRoot.x;
                gapHintRoot.holdGeomW = gapHintRoot.width;
                gapHintRoot.holdDeadline = Date.now() + gapHintRoot.holdMs;
            }
        }
        // The hit target. Hover only answers inside geometry that can be
        // hit-tested, and everything visual here hangs off the parent's
        // edges (centres, bottom, under-edge) -- the Item itself had not one
        // painted pixel, so the handler had almost nowhere to fire. This
        // transparent fill makes the whole strip hoverable.
        //
        // A plain Rectangle, not a MouseArea: it takes the hover and nothing
        // else, so a press in the gap still reaches the bar underneath.
        Rectangle {
            anchors.fill: parent
            color: "transparent"
        }
        opacity: gapHintRoot.showing ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                // The appearance fade, halved. 180ms was a soft, deliberate
                // fade -- correct when the design still had three filled
                // islands competing for attention, and wrong now that the
                // hint is a 4px mark in a large empty gap: at 180ms it reads
                // as something materialising rather than as a line that was
                // always conceptually there and simply lit up. 90ms is the
                // point where it snaps into being.
                //
                // Still asymmetric for fullscreen, and by more than a little:
                // the place the short fade was for is a gesture answered over a
                // fullscreen window, where the fingers are already moving and
                // there is no hover to ease in from -- so it comes up almost at
                // once and goes the same way when they lift. The state that
                // brought the bar out is the state the line appears in, which
                // is what makes one duration right for both halves of it.
                duration: gapHintRoot.fullscreen ? 55 : 90
                easing.type: Easing.OutCubic
            }
        }

        // ── The rail ────────────────────────────────────────────────────
        // Half the travel, in px, measured so the moving CONTENT's centre
        // lands on a chevron's centre at each end: with the original layout the up
        // chevron hung 10px above the tick's centre and the down chevron 10px
        // below (13px glyph + 2px margin + half the 3px tick), so 10 is the
        // number that makes "the line reached the arrow" true rather than
        // approximate. The bar strip is only ~50px tall, so this is a small
        // travel -- deliberately: it says which way and roughly how far, and
        // the fingers are doing the real work.
        readonly property real railHalf: 10
        readonly property real railMid: height / 2
        // Clamped so nothing upstream can throw the line off its rail.
        readonly property real displacement: Math.max(-1, Math.min(1, push))
        // The travelling content's centre, and how far it is thrown. A
        // shorter throw than the old whole-line rail, and that is the point
        // of the redesign: the LINE stays put, so the content has to break
        // clear of a 4px mark without sailing off into the empty strip and
        // losing all relationship to it. 8 clears the line by 5px, which
        // reads unmistakably as "out of the line" while still arriving on
        // the chevron it is heading for.
        readonly property real contentTravel: 8
        readonly property real contentY: railMid - displacement * contentTravel

        // How far each chevron is on its way out. Zero at rest, so both are
        // fully drawn until the gesture starts -- that is the "first
        // indication" doing its job. The fade begins at just under half the
        // travel rather than immediately: a linear fade from the first pixel
        // would dim an arrow while the line was still nowhere near it, and
        // the arrow is the thing telling you the direction is available.
        readonly property real topFade: Math.max(0,
            Math.min(1, (displacement - 0.45) / 0.55))
        readonly property real bottomFade: Math.max(0,
            Math.min(1, (-displacement - 0.45) / 0.55))

        // ── The placeholder ──────────────────────────────────────────────
        // This line NEVER MOVES, for the whole gesture. That is what makes
        // it a placeholder rather than a control: the thing you look at
        // before you touch it is still there, unchanged, after you have
        // pushed the content out of it and after the content comes home.
        //
        // What travels is `gapContent` below -- a smaller bar of the same
        // accent, lying invisibly on top of this one. Same colour, strictly
        // inside its bounds, so at rest the two composite into exactly ONE
        // clean thin line with no seam, no stub and no second mark. Push up
        // and the content slides out of the top; the line stays where it
        // was. The bar looks like it opened, not like it slid away.
        //
        // The camouflage is arithmetic, not luck, and three things enforce
        // it. The content is FLAT accent and this line's gradient is pinned
        // to pure accent across the entire band the content covers (stops
        // at 0.25 and 0.75 of a 4px line), so where they overlap they are
        // the same colour rather than merely similar. The content carries NO
        // shadow of its own -- a shadow falling across the middle of this
        // line would print a dark band on it at rest, which is precisely
        // the opposite of invisible. And neither item changes colour when
        // `live` flips, because a track that brightened under a resting
        // finger would stop matching the content sitting on it. The shadow
        // belongs to the line, which is the thing actually there.
        Item {
            id: gapLine
            width: 30
            height: 4
            x: (gapHintRoot.width - width) / 2
            y: gapHintRoot.railMid - height / 2
            Behavior on scale {
                NumberAnimation { duration: 130; easing.type: Easing.OutQuad }
            }
            // Barely-there swell while a finger is on it. Small on purpose:
            // this line is now a fixed landmark, and anything that reads as
            // motion here would contradict the whole point. It also stays
            // well inside the flat accent band at this scale, so the
            // content lying on it keeps matching it.
            scale: gapHintRoot.live ? 1.08 : 1.0

            // The shadow it casts on the bar. Two stacked slabs of falling
            // opacity rather than a blur: a 30x4 DropShadow effect on every
            // hover frame is a render target for a two-pixel dark edge, and
            // this file already runs a full-screen layer surface.
            Rectangle {
                anchors.fill: parent
                anchors.topMargin: 3
                radius: height / 2
                color: Qt.rgba(0, 0, 0, 0.16)
            }
            Rectangle {
                anchors.fill: parent
                anchors.topMargin: 1.5
                radius: height / 2
                color: Qt.rgba(0, 0, 0, 0.22)
            }
            // The body: a lit ridge, but with the light and the shade
            // compressed into the outer pixels so the middle half is dead
            // flat accent. The ridge is the 3D; the flat middle is what
            // the content disappears into.
            Rectangle {
                anchors.fill: parent
                radius: height / 2
                gradient: Gradient {
                    GradientStop {
                        position: 0.0
                        color: Qt.lighter(gapHintRoot.accent, 1.45)
                    }
                    GradientStop { position: 0.25; color: gapHintRoot.accent }
                    GradientStop { position: 0.75; color: gapHintRoot.accent }
                    GradientStop {
                        position: 1.0
                        color: Qt.darker(gapHintRoot.accent, 1.3)
                    }        }

    }
}


        // ── The content ──────────────────────────────────────────────────
        // The part that moves. Drawn AFTER the line so it sits in front of
        // it, 22x2 against 30x4, centred: strictly inside on every side, so
        // at rest there is nothing to see. NO rotation, and no shadow -- see
        // the note on the line above. It leans now only in the sense that
        // its travel is linear, and it does not fade out as it goes: the
        // line it came out of is still on screen, and a content that
        // vanished at the far end of the throw would leave the gesture
        // looking like nothing had happened.
        Rectangle {
            id: gapContent
            width: 22
            height: 2
            radius: 1
            x: (gapHintRoot.width - width) / 2
            y: gapHintRoot.contentY - height / 2
            color: gapHintRoot.accent
            Behavior on y {
                // ONE duration for both halves of the gesture, and short.
                // Events arrive every 10-30ms, so anything slow leaves the
                // content permanently trailing behind a swipe; and the spring
                // home has to feel SNAPPED -- 55ms across an 8px throw is
                // quick enough to read as a release and slow enough to be
                // seen arriving. No overshoot: on a 2px-tall mark, a spring
                // would visibly wobble on every one of those events.
                //
                // The EASING is what actually reads as snappy, and it was the
                // one thing the number could not fix. OutQuad reaches a third
                // of the throw by 17% of the duration and is still creeping at
                // the end, which is what made the content look like it was
                // being carried rather than thrown. OutCubic is 66% out by
                // the same point and visibly arrives; it is the closest
                // QML curve to the front-loaded bezier the design previews
                // used (cubic-bezier(.2,.85,.3,1)).
                NumberAnimation { duration: 55; easing.type: Easing.OutCubic }
            }
        }

        // ── The two chevrons ─────────────────────────────────────────────
        // Anchored to the RAIL, not to the line. They used to hang off the
        // tick's own top and bottom, which was fine for a tick that never
        // moved and would have dragged both arrows along with the line the
        // moment it did. Their centres are the rail's two ends, so the line
        // arrives exactly where they are.
        MaterialSymbol {
            id: gapArrowUp
            anchors.horizontalCenter: parent.horizontalCenter
            y: gapHintRoot.railMid - gapHintRoot.railHalf - height / 2
            text: "keyboard_arrow_up"
            iconSize: 13
            color: gapHintRoot.accent
            opacity: 0.9 * (1 - gapHintRoot.topFade)
            Behavior on opacity {
                NumberAnimation { duration: 70; easing.type: Easing.OutCubic }
            }
        }
        MaterialSymbol {
            id: gapArrowDown
            anchors.horizontalCenter: parent.horizontalCenter
            y: gapHintRoot.railMid + gapHintRoot.railHalf - height / 2
            text: "keyboard_arrow_down"
            iconSize: 13
            color: gapHintRoot.accent
            opacity: 0.9 * (1 - gapHintRoot.bottomFade)
            Behavior on opacity {
                NumberAnimation { duration: 70; easing.type: Easing.OutCubic }
            }
        }
    }

    component PocketLine: RowLayout {
        property string label: ""
        property string value: ""
        // Optional accent: the row's label takes this colour when set, so a
        // live reading can be told from a static field at a glance.
        property color accent: "transparent"
        Layout.fillWidth: true          // Side padding is the COLUMN's job now (pocketHost.sidePad): one place
          // decides the inset, so the label and the value line up with the skin
          // instead of each row adding its own 14px on top of it.
        spacing: 10
        StyledText {
            id: pocketLineLabel
            objectName: "pocketLineLabel"
            text: label
            font.pixelSize: Appearance.font.pixelSize.smallie
            color: accent.a > 0 ? accent : Appearance.colors.colSubtext
        }
        StyledText {
            id: pocketLineValue
            objectName: "pocketLineValue"
            text: value
            font.pixelSize: Appearance.font.pixelSize.smallie
            color: Appearance.colors.colOnLayer0
            elide: Text.ElideRight
            // A backstop, not the layout's width: the column now measures this
            // row's NATURAL width (below) and sizes the drop to it, so the cap
            // only ever bites on a pathological value -- a 40-character SSID --
            // where the text elides and the drop stays a drop. It used to be
            // 180, which is what forced the mismatch: the box wanted 200 and
            // the text was cut at 180 regardless of what it actually said.
            // Takes the slack itself, right-aligned -- which is what the
            // `Item { Layout.fillWidth: true }` spacer it replaced was
            // emulating, except that this one can also SHRINK.
            // No elision cap: the full text "Opening <app>…" must always
            // fit without truncation. The drop sizes to the content.
            Layout.fillWidth: true
            Layout.minimumWidth: 24
            Layout.maximumWidth: 2000
            horizontalAlignment: Text.AlignRight
        }
        // The natural width of this row: label + value at their natural
        // text widths, plus the row's spacing. This is what the column's
        // naturalWidth measures, and the host is then sized from that same
        // number -- so it is also the width the value is actually granted.
        //
        // The +2 is SLACK, and it is load-bearing: the value can only be
        // shorter than this if the host came out shorter than the text asked
        // for, and a sub-pixel rounding difference between the measured width
        // and the laid-out width was enough to turn the last visible glyph
        // into "…" -- the "my IP address ends in dots" report. Two pixels of
        // overshoot is invisible on a row this long and removes the whole
        // class of rounding-elision.
        readonly property real naturalWidth: pocketLineLabel.implicitWidth
            + spacing
            + pocketLineValue.implicitWidth
            + 2
        // No trailing chevron: it was borrowed from the sidebar's list rows,
        // where it means "opens something". Inside the droplet it means
        // nothing, and it ate the width the value needed.
        }

    // Open the settings app on one of its pages.
    //
    // Through scripts/launch/settings.sh, which is also what decides whether
    // this starts the app or walks the copy that is already open to that page.
    // Clicking Wi-Fi and then Bluetooth used to leave two settings windows on
    // the desktop; there is one now, and the second click just changes its tab.
    //
    // The page is named by its `slug` -- never by its translated name -- so this
    // keeps working in any language.
    //
    // `section` narrows that further, to a page that holds more than one thing:
    // the Network page carries Wi-Fi and Bluetooth, and the icon you clicked
    // decides which of the two you meant. Empty means the page's own default.
    function openSettingsPage(slug, section) {
        Quickshell.execDetached([
            "bash",
            Quickshell.shellPath("scripts/launch/settings.sh"),
            slug ?? "",
            section ?? ""
        ]);
    }

    component VerticalBarSeparator: Rectangle {
        Layout.topMargin: Appearance.sizes.baseBarHeight / 3
        Layout.bottomMargin: Appearance.sizes.baseBarHeight / 3
        Layout.fillHeight: true
        implicitWidth: 1
        color: Appearance.colors.colOutlineVariant
    }

    // ── User-added top-bar toggles (singletons, see the Repeater below) ──
    Toggles.NightLightToggle { id: nightLightModel }
    Toggles.DarkModeToggle { id: darkModeModel }
    Toggles.BluetoothToggle { id: bluetoothModel }
    Toggles.NetworkToggle { id: networkModel }
    Toggles.MicToggle { id: micModel }
    Toggles.IdleInhibitorToggle { id: idleInhibitorModel }
    Toggles.GameModeToggle { id: gameModeModel }
    Toggles.PerformanceToggle { id: performanceModel }
    Toggles.PowerProfilesToggle { id: powerProfilesModel }
    Toggles.ScreenSnipToggle { id: screenSnipModel }
    Toggles.ColorPickerToggle { id: colorPickerModel }

    // ── One ink size for the icons in the run ───────────────────────────
    // Every icon in the strip is drawn at `Appearance.font.pixelSize.larger`,
    // and Material Symbols' ink box is not uniform per glyph: measured on the
    // live bar at that em, the wifi, the volume and the bluetooth fill 12-14.7px
    // of ink while the power profile's eco leaf fills 10.0 and its airwave 11.3.
    // That is the "the icons are very slightly smaller than the rest" report --
    // the glyph, not the em.
    //
    // So the profile glyphs carry the multiplier that lands their ink on the
    // run's 12px. Keyed by GLYPH and not by toggle, and a MULTIPLIER of
    // `larger` rather than a fixed size, so an accessibility text scale moves
    // them together, a glyph that is not listed keeps the strip's own em, and a
    // pin that is not on the bar today is sized the day it is pinned.
    readonly property var pinGlyphEm: ({
        "airwave": 1.05,              // balanced
        "energy_savings_leaf": 1.05,  // eco
        "local_fire_department": 1.00 // performance
    })

    component HoverIconButton: Rectangle {
        id: hoverIconButton
        property alias symbol: hoverIconSymbol
        property string tooltipText: ""
        property bool hovered: false
        // ── Hover that the pointer did not cause ─────────────────────────
        // The bar's cursor position, fed in by whoever can see it (only the
        // bar's full-width tracker does -- see `cursorTrack`). Defaults mean
        // no other instance of this component changes behaviour.
        property real cursorX: -1
        property bool cursorInBar: false
        // Where the cursor and this button were the last time the hover was
        // real. -1 / NaN = never hovered.
        property real hoverAnchorX: -1
        property real hoverAnchorBtnX: NaN
        // THE STUCK HOVER. A volume or brightness change arms the meter
        // pocket, which is centred on this very button and resizes the
        // extended island -- so the bar's icons shift sideways and this one
        // slides under a cursor that never moved. The HoverHandler reports
        // that as a genuine hover, and because nothing about the pointer
        // ever changed again, no leave event ever arrives: the glyph stays
        // filled and accent-coloured long after the pocket is gone, which
        // reads as the icon stuck switched on.
        //
        // So a hover is only believed while the pointer has stayed put AND
        // this button has stayed where it was. If either moved, the hover
        // was the layout's doing, not the user's, and is not shown. The
        // pointer half is what keeps this from swallowing a real hover: walk
        // the cursor onto the icon after it settles and both anchors match
        // again, so the feedback comes straight back.
        readonly property bool movedUnderCursor: hoverAnchorX >= 0
            && cursorInBar
            && cursorX > hoverAnchorX - 1 && cursorX < hoverAnchorX + 1
            && Math.abs(x - hoverAnchorBtnX) > 0.5
        // What the glyph and the pocket arming actually read.
        readonly property bool reallyHovered: hovered && !movedUnderCursor
        // An attached panel ("desktop app" pinned under the icon) this button
        // opens on tap. Null = no panel; the button then does nothing on tap
        // unless a use site adds its own handler.
        property Component panelComponent: null
        // What a left click does instead of opening `panelComponent`. Used by
        // the Wi-Fi and Bluetooth icons, which open the full settings app on
        // their page rather than a popup holding only a list of names.
        property var activateAction: null
        // What a right click does. Null = nothing.
        property var altAction: null
        implicitWidth: 26
        implicitHeight: 26
        radius: Appearance.rounding.full
        // NO hover fill. This painted a second background behind the glyph --
        // `colOnLayer0` at 16% in a circle -- so hovering an icon put a visible
        // disc on the bar that was a different colour from the surface it sat
        // on, and read as a stray box rather than as feedback. Two surfaces of
        // slightly different grey next to each other is exactly what the eye
        // calls a rendering fault.
        //
        // The hover feedback is the GLYPH: it takes the accent and fills in. One
        // colour change on the thing you are pointing at, rather than a plate
        // behind it plus a colour change on it.
        // Optional glyph colour, for a pin whose colour IS its state -- the
        // power profile's green leaf and fire-orange flame. Unset ("transparent")
        // leaves the strip's own logic below in charge.
        //
        // A glyph, not a disc behind it: the bar's icons are all outline glyphs
        // on the bar's own surface, and a coloured disc broke that run -- it read
        // as a different kind of control sitting in the strip.
        property color symbolColor: "transparent"
        color: "transparent"
        MaterialSymbol {
            id: hoverIconSymbol
            anchors.centerIn: parent
            iconSize: Appearance.font.pixelSize.larger
            // A pin with its own colour keeps it, hover or not: that colour is
            // the mode, not a hover state. Everything else does what every
            // other icon in the strip does.
            color: hoverIconButton.symbolColor.a > 0
                ? hoverIconButton.symbolColor
                : (hoverIconButton.reallyHovered ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0)
            // The hover swell is the FILL axis, not a scale: these glyphs are
            // native-rendered, so enlarging one stretches its rasterized pixels
            // and the icon visibly softens exactly when the eye is on it. The
            // filled outline redraws crisply at the same size.
            fill: hoverIconButton.reallyHovered ? 1 : 0
            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
        }
        // Keeps the two anchors describing where things actually are, for as long
        // as the hover lasts. It runs only while the button is lit, so the
        // idle bar pays nothing for it.
        Timer {
            interval: 50
            repeat: true
            running: hoverIconButton.hovered
            onTriggered: {
                hoverIconButton.hoverAnchorX = hoverIconButton.cursorX;
                hoverIconButton.hoverAnchorBtnX = hoverIconButton.x;
            }
        }
        function togglePanel() {
            if (!panelComponent)
                return;
            if (panelLoader.item) {
                if (panelLoader.item.open)
                    panelLoader.item.close();
                else
                    panelLoader.item.open = true;
            } else {
                // Built on first use; onLoaded anchors and opens it.
                panelLoader.active = true;
            }
        }
        // A MouseArea, not a TapHandler.
        //
        // This button lives inside the bar's own section MouseArea
        // (barRightSideMouseArea). That ancestor is an input item and grabs the
        // press, so a TapHandler here -- which only observes, and never grabs --
        // never completed: clicking the wifi or bluetooth icon did nothing at
        // all. A MouseArea is itself an input item, sits in front of the
        // ancestor, and takes the press first. When this button has no panel it
        // stays disabled, so the pill behind still opens the sidebar.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            enabled: hoverIconButton.panelComponent !== null || hoverIconButton.activateAction !== null
            cursorShape: Qt.PointingHandCursor
            onClicked: (mouse) => {
                if (mouse.button === Qt.LeftButton) {
                    // Left click: toggle icon on/off
                    if (hoverIconButton.activateAction) hoverIconButton.activateAction();
                    else hoverIconButton.togglePanel();
                } else if (mouse.button === Qt.RightButton) {
                    // Right click: open detailed view
                    if (hoverIconButton.altAction) hoverIconButton.altAction();
                    return;
                }
            }
        }
        Loader {
            id: panelLoader
            active: false
            sourceComponent: hoverIconButton.panelComponent
            onLoaded: {
                item.anchorItem = hoverIconButton;
                item.open = true;
            }
        }
        // The built panel, or null before the first open. Exposed because the
        // panel is LAZY: an IpcHandler inside BackgroundAppsPanel.qml would
        // only exist once the panel had been built, which means it could never
        // be the thing that builds it. Anything that has to reach a bar panel
        // from outside the component asks here.
        readonly property var panelItem: panelLoader.item
        // NO TOOLTIP HERE, deliberately.
        //
        // It used to be gated on `LiquidBar.pocketId === ""` so it would stay
        // out of the way while a pocket was open. That gate never fired for an
        // INLINE pocket, because inline arms no drop at all -- the id is
        // deliberately empty -- so hovering an icon showed the bar's own info
        // AND a floating card repeating it underneath, two surfaces saying the
        // same thing at once.
        //
        // The bar row is now the single place this information appears: the
        // pocket grows out of the island the pointer is already over, which is
        // strictly better than a card that appears somewhere else and has to
        // be aimed at. So the tooltip is gone rather than re-gated, and
        // `tooltipText` survives only as the text the pockets themselves read.
    }


    Loader {
        // Islands carry their own per-island shadows (see above); this is the
        // classic slab's shadow only.
        active: !root.islandsEnabled && Config.options.bar.showBackground && Config.options.bar.cornerStyle === 1 && Config.options.bar.floatStyleShadow
        anchors.fill: barBackground
        sourceComponent: StyledRectangularShadow {
            anchors.fill: undefined // The loader's anchors act on this, and this should not have any anchor
            target: barBackground
        }
    }

    // ── The liquid droplet's skin ────────────────────────────────────────────
    // The small curved section that hangs under the hovered bar icon and merges
    // back into the bar's underside with concave fillets on each side. Two
    // measured facts decide how it is drawn:
    //
    //  1. It is painted HERE, after the bar's shadow. StyledRectangularShadow
    //     blurs ~9px past the bar, and with the skin drawn before it that blur
    //     landed straight on the drop's head -- a dark slit that made the drop
    //     look stuck onto the bar instead of grown out of it.
    //  2. A float-style bar (`cornerStyle: 1`) insets its background by
    //     hyprlandGapsOut on every side, so the drawn band ends at
    //     `barHeight - gap`, not at `barHeight`. The first attempt hung the drop
    //     from `barHeight + 4` and left those 9px of shadow showing between bar
    //     and drop.
    //
    // Stacking: content z: 10 (on top), this skin z: 1, bar shadow and bar
    // background z: 0.
    Item {
        id: dropPainter
        z: 1

        // Same frame and footprint as the pocket's content (pocketHost), so the
        // skin is never narrower than what it carries -- and the SMOOTHED size,
        // so skin and content resize as one body when the pointer moves between
        // two icons with different amounts of info.
        readonly property real dropWidth: pocketHost.shownW
        readonly property real spring: Math.max(0, LiquidBar.t)
        readonly property real gap: Config.options.bar.cornerStyle === 1 ? Appearance.sizes.hyprlandGapsOut : 0
        // Where the drop starts: the bar's painted bottom edge.
        readonly property real barH: Appearance.sizes.barHeight - gap
        // The shape's own top edge, a few pixels ABOVE the bar's bottom edge.
        //
        // This is what makes the bar and the drop one layer: the bar's
        // background carries a 1px hairline border along its bottom, and a drop
        // that began exactly at that line left the hairline running straight
        // across the droplet's mouth -- reading as a capsule tucked under the
        // bar. The fill now covers that line across the mouth (it is the same
        // colour as the bar's own fill, so the overlap is invisible), and the
        // silhouette reads as one shape bulging downward.
        readonly property real topY: barH - 3
        // The pull, measured from the bar's painted bottom edge. The content is
        // anchored one `padV` below that same line, so the two agree exactly.
        readonly property real depth: spring * pocketHost.shownH
        readonly property real botY: barH + depth
        // ── the mouth fillet ──────────────────────────────────────────────
        // The trick, and what the reference does: the side leaves the bar's
        // underside HORIZONTALLY and only then turns down. Because the tangent
        // at the mouth is parallel to the bar there is no corner where the bar
        // ends -- the surface simply continues downward. A side that starts out
        // vertical (what this replaced) turns 90 degrees at the bar's edge, and
        // can only ever read as a box parked underneath it.
        //
        // Measured off the reference the user sent: the bar's hairline runs
        // FLAT along its bottom edge right up to the drop's wall, then turns
        // down over ~9px across by ~11px deep. An earlier 13x36 meniscus left
        // the tangent too early and bowed the surface away from the bar, which
        // is what still read as "a shape parked underneath" rather than the
        // bar's own surface descending. Both scale with the pull so the first
        // frames stay sane.
        // The circle's kappa. A cubic through control points placed by this
        // constant traces the TRUE quarter arc; the hand-picked ones this
        // replaces (0.92*W on the horizontal, 0.55*H on the vertical) bulge
        // past the arc and then snap into it, which is what left the drop
        // reading as a hard box instead of a curve.
        readonly property real kappa: 0.5523
        // Bottom corners, rounded like a PANEL rather than like the bar's
        // hairline: the islands are small pills (windowRounding, 8 on the
        // Material default), and a drop rounded to the same 8px reads as a
        // rectangular box with softened corners -- the exact thing this shape
        // is not. The panel scale (large/verylarge) is what makes the drop
        // read as its own surface, and it is bounded by the pull so the first
        // spring frames stay sane.
        readonly property real rad: Math.max(0, Math.min(
            Appearance.rounding.large,
            dropWidth * 0.22,
            Math.max(0, depth * 0.4)
        ))
        // ── the mouth fillet ──────────────────────────────────────────────
        // The side leaves the bar's underside HORIZONTALLY and only then turns
        // down, so there is no corner where the bar ends: the surface simply
        // continues downward.
        //
        // Both terms are BOUNDS, never fixed pixels, and both are taken from
        // the drop's own width and the current pull -- so the silhouette is the
        // same shape whether the drop is 200px or 420px wide, and the same on a
        // long bar as on a short one. The 9x11px chamfer these replace was
        // small enough to read as a corner and large enough to overlap the
        // island's own bottom curve.
        readonly property real filletW: Math.max(0, Math.min(
            18,
            dropWidth * 0.13,
            Math.max(0, (dropWidth - rad * 2) * 0.5)
        ))
        readonly property real filletH: Math.max(0, Math.min(24, depth * 0.5))

        // ── the droplet ───────────────────────────────────────────────────
        // The card that hangs under the bar is a DROPLET, not a box: the body
        // runs past the content and tapers into a rounded tip, so it reads as
        // a drop of the bar hanging below it rather than a panel parked
        // underneath. This started out gated on a very large bar, but that
        // gate only meant the card kept its box shape -- the shape is the
        // design, and it is the design at every bar size.
        //
        // Everything below is derived from the drop's own width and the
        // current pull, so the silhouette is the same shape whether the card
        // is 170px or 420px wide, and the first spring frames stay sane.
        readonly property bool dropletMode: true
        // How deep the taper is. Bounded by the pull so the first spring
        // frames stay sane, and small enough that it never eats into the
        // content block (which hangs from the top of the drop).
        readonly property real tipH: Math.max(0, Math.min(30, depth * 0.3))
        // The tip is a quarter-round on each side meeting at the centre, so
        // it is the drop's own half-width that decides how much of the bottom
        // the curve takes.
        readonly property real tipR: Math.max(0, Math.min(
            (dropWidth - filletW * 2) * 0.5,
            tipH
        ))
        // Where the straight wall ends and the taper begins. Owned HERE, not
        // on the Shape: inside a `component` the word `parent` means the
        // component's own scope, so a `parent.something` reference silently
        // resolved to undefined and the tip was drawn from NaN control
        // points.
        readonly property real taperTop: Math.max(0, botY - tipH)

        x: LiquidBar.dropX - dropWidth / 2
        width: dropWidth
        y: 0
        height: Appearance.sizes.barHeight + spring * pocketHost.shownH + 2
        visible: width > 0 && LiquidBar.t > 0.001

        Shape {
            anchors.fill: parent
            // The panel-bottom silhouette below, or -- on a very large bar --
            // the droplet, which is the same body with a tapering tip.
            visible: !dropPainter.dropletMode
            // Curve renderer: curved geometry is tessellated directly, with no
            // per-frame offscreen texture. This shape re-tessellates on every
            // spring frame, and an FBO there is exactly the cost the rest of the
            // interface avoids.
            preferredRendererType: Shape.CurveRenderer

            // The silhouette, filled. Drawn first so the outline below sits on
            // top of it.
            ShapePath {
                strokeColor: "transparent"
                strokeWidth: -1
                fillColor: Config.options.bar.showBackground ? Appearance.colors.colBarBackground : "transparent"

                // Starts a few pixels ABOVE the bar's own bottom edge (topY) so
                // the fill covers the bar's hairline across the mouth -- without
                // that the bar's border runs straight across the opening and the
                // drop reads as a capsule tucked under it.
                startX: 0
                startY: dropPainter.topY
                PathLine { x: 0; y: dropPainter.barH }
                // Mouth fillet: horizontal at the bar, vertical at the wall --
                // a true quarter ellipse (kappa), not a chamfer.
                PathCubic {
                    control1X: dropPainter.filletW * dropPainter.kappa
                    control1Y: dropPainter.barH
                    control2X: dropPainter.filletW
                    control2Y: dropPainter.barH + dropPainter.filletH * (1 - dropPainter.kappa)
                    x: dropPainter.filletW
                    y: dropPainter.barH + dropPainter.filletH
                }
                // Left wall: dead vertical, as in the reference.
                PathLine { x: dropPainter.filletW; y: dropPainter.botY - dropPainter.rad }
                // Bottom-left corner: same kappa arc as the mouth, so the
                // drop is rounded by the same hand as the island.
                PathCubic {
                    control1X: dropPainter.filletW
                    control1Y: dropPainter.botY - dropPainter.rad * dropPainter.kappa
                    control2X: dropPainter.filletW + dropPainter.rad * (1 - dropPainter.kappa)
                    control2Y: dropPainter.botY
                    x: dropPainter.filletW + dropPainter.rad
                    y: dropPainter.botY
                }
                PathLine { x: dropPainter.width - dropPainter.filletW - dropPainter.rad; y: dropPainter.botY }
                PathCubic {
                    control1X: dropPainter.width - dropPainter.filletW - dropPainter.rad * (1 - dropPainter.kappa)
                    control1Y: dropPainter.botY
                    control2X: dropPainter.width - dropPainter.filletW
                    control2Y: dropPainter.botY - dropPainter.rad * dropPainter.kappa
                    x: dropPainter.width - dropPainter.filletW
                    y: dropPainter.botY - dropPainter.rad
                }
                PathLine { x: dropPainter.width - dropPainter.filletW; y: dropPainter.barH + dropPainter.filletH }
                // Mouth fillet, mirrored.
                PathCubic {
                    control1X: dropPainter.width - dropPainter.filletW
                    control1Y: dropPainter.barH + dropPainter.filletH * (1 - dropPainter.kappa)
                    control2X: dropPainter.width - dropPainter.filletW * dropPainter.kappa
                    control2Y: dropPainter.barH
                    x: dropPainter.width
                    y: dropPainter.barH
                }
                PathLine { x: dropPainter.width; y: dropPainter.topY }
                // Closed along that top edge by the fill rule -- which is inside
                // the bar's own band, so the seam can never be seen.
            }

            // The bar's hairline, carried around the drop.
            //
            // This is the other half of "it has to look like the bar": the bar
            // wears a 1px border along its bottom edge, and the drop's outline
            // must be that same line continuing down the fillet, around the
            // bottom and back up. The path is deliberately OPEN -- closed, it
            // would draw a line straight across the mouth, which is the seam we
            // are removing -- and it begins and ends on the bar's border row
            // (barH - 0.5), so the two lines meet end to end with no break.
            ShapePath {
                fillColor: "transparent"
                strokeColor: Appearance.colors.colBarBackgroundBorder
                strokeWidth: 1

                // Identical geometry to the fill above, from the same kappa
                // properties -- the outline can never disagree with the shape
                // it is outlining, which is how a hairline ends up inside the
                // fill and the mouth shows a seam.
                startX: 0
                startY: dropPainter.barH - 0.5
                PathCubic {
                    control1X: dropPainter.filletW * dropPainter.kappa
                    control1Y: dropPainter.barH
                    control2X: dropPainter.filletW
                    control2Y: dropPainter.barH + dropPainter.filletH * (1 - dropPainter.kappa)
                    x: dropPainter.filletW
                    y: dropPainter.barH + dropPainter.filletH
                }
                PathLine { x: dropPainter.filletW; y: dropPainter.botY - dropPainter.rad }
                PathCubic {
                    control1X: dropPainter.filletW
                    control1Y: dropPainter.botY - dropPainter.rad * dropPainter.kappa
                    control2X: dropPainter.filletW + dropPainter.rad * (1 - dropPainter.kappa)
                    control2Y: dropPainter.botY
                    x: dropPainter.filletW + dropPainter.rad
                    y: dropPainter.botY
                }
                PathLine { x: dropPainter.width - dropPainter.filletW - dropPainter.rad; y: dropPainter.botY }
                PathCubic {
                    control1X: dropPainter.width - dropPainter.filletW - dropPainter.rad * (1 - dropPainter.kappa)
                    control1Y: dropPainter.botY
                    control2X: dropPainter.width - dropPainter.filletW
                    control2Y: dropPainter.botY - dropPainter.rad * dropPainter.kappa
                    x: dropPainter.width - dropPainter.filletW
                    y: dropPainter.botY - dropPainter.rad
                }
                PathLine { x: dropPainter.width - dropPainter.filletW; y: dropPainter.barH + dropPainter.filletH }
                PathCubic {
                    control1X: dropPainter.width - dropPainter.filletW
                    control1Y: dropPainter.barH + dropPainter.filletH * (1 - dropPainter.kappa)
                    control2X: dropPainter.width - dropPainter.filletW * dropPainter.kappa
                    control2Y: dropPainter.barH
                    x: dropPainter.width
                    y: dropPainter.barH - 0.5        }

    }
}


        // ── The droplet silhouette ────────────────────────────────────────
        // The same body as the panel silhouette above -- same mouth fillet,
        // same hairline, same spring -- except that the walls run STRAIGHT
        // down past the content and only the last stretch tapers into a
        // rounded tip. It is a second Shape rather than a branch inside the
        // one above because the fill and the outline have to agree exactly,
        // and duplicating one geometry is cheaper than making every segment
        // of the panel shape conditional.
        Shape {
            anchors.fill: parent
            visible: dropPainter.dropletMode
            preferredRendererType: Shape.CurveRenderer

            component MouthAndWalls: ShapePath {
                fillColor: "transparent"
                strokeWidth: -1
                startX: 0
                startY: dropPainter.topY
                // Left edge up from the bar's bottom, then the mouth fillet:
                // the surface leaves the bar horizontally, so there is no
                // corner where the bar ends.
                PathLine { x: 0; y: dropPainter.barH }
                PathCubic {
                    control1X: dropPainter.filletW * dropPainter.kappa
                    control1Y: dropPainter.barH
                    control2X: dropPainter.filletW
                    control2Y: dropPainter.barH + dropPainter.filletH * (1 - dropPainter.kappa)
                    x: dropPainter.filletW
                    y: dropPainter.barH + dropPainter.filletH
                }
                // The straight wall. Without it the taper's own curve starts
                // at the mouth and the whole card reads as a triangle.
                PathLine { x: dropPainter.filletW; y: dropPainter.taperTop }
                // The taper: tangent to the wall where it leaves it, tangent
                // to the tip where it arrives, so the tip is a smooth
                // continuation of the body instead of a corner stuck on it.
                PathCubic {
                    control1X: dropPainter.filletW
                    control1Y: dropPainter.taperTop + (dropPainter.botY - dropPainter.taperTop) * 0.45
                    control2X: dropPainter.width / 2 - dropPainter.tipR * 1.15
                    control2Y: dropPainter.botY
                    x: dropPainter.width / 2 - dropPainter.tipR
                    y: dropPainter.botY
                }
                // The tip: a half-round, so the droplet ends in a point of
                // curve rather than a corner.
                PathCubic {
                    control1X: dropPainter.width / 2 - dropPainter.tipR * (1 - dropPainter.kappa)
                    control1Y: dropPainter.botY
                    control2X: dropPainter.width / 2
                    control2Y: dropPainter.botY
                    x: dropPainter.width / 2
                    y: dropPainter.botY
                }
                PathCubic {
                    control1X: dropPainter.width / 2
                    control1Y: dropPainter.botY
                    control2X: dropPainter.width / 2 + dropPainter.tipR * (1 - dropPainter.kappa)
                    control2Y: dropPainter.botY
                    x: dropPainter.width / 2 + dropPainter.tipR
                    y: dropPainter.botY
                }
                PathCubic {
                    control1X: dropPainter.width / 2 + dropPainter.tipR * 1.15
                    control1Y: dropPainter.botY
                    control2X: dropPainter.width - dropPainter.filletW
                    control2Y: dropPainter.taperTop + (dropPainter.botY - dropPainter.taperTop) * 0.45
                    x: dropPainter.width - dropPainter.filletW
                    y: dropPainter.taperTop
                }
                PathLine { x: dropPainter.width - dropPainter.filletW; y: dropPainter.barH + dropPainter.filletH }
                // Mouth fillet, mirrored.
                PathCubic {
                    control1X: dropPainter.width - dropPainter.filletW
                    control1Y: dropPainter.barH + dropPainter.filletH * (1 - dropPainter.kappa)
                    control2X: dropPainter.width - dropPainter.filletW * dropPainter.kappa
                    control2Y: dropPainter.barH
                    x: dropPainter.width
                    y: dropPainter.barH
                }
                PathLine { x: dropPainter.width; y: dropPainter.topY }
            }

            // The filled body.
            MouthAndWalls {
                fillColor: Config.options.bar.showBackground ? Appearance.colors.colBarBackground : "transparent"
                strokeColor: "transparent"
            }

            // The bar's hairline, carried around the droplet. Same geometry,
            // opened along the mouth so no seam shows across it.
            MouthAndWalls {
                fillColor: "transparent"
                strokeColor: Appearance.colors.colBarBackgroundBorder
                strokeWidth: 1
            }
        }
    }

    // ── Background: three floating islands ─────────────────────────────────
    // The bar is no longer one slab: left (clock/app icon), centre (now bar)
    // and right (status icons) are separate capsules floating over the
    // desktop, each with its own shadow. `islandsEnabled` keeps the classic
    // single-slab rendering one switch away (bar.islands: false).
    //
    // The island rectangles are positioned against the actual content rows
    // (barLeftSideMouseArea / middleSection / barRightSideMouseArea) and grow
    // with them, so the capsules are always exactly as wide as what they
    // carry -- including the now bar's mode changes, which re-measure live.
    readonly property bool islandsEnabled: Config.options.bar.islands !== false
    // Are the capsules actually painted? All three islands are visible only
    // when the islands skin AND the bar background are on, so with the
    // classic single slab there is nothing to measure: the gap pass-through
    // in Bar.qml keys off this and leaves the strip whole, which is the
    // behaviour that skin has always had.
    readonly property bool islandsPainted: islandsEnabled && Config.options.bar.showBackground
    // The three capsules' horizontal extent, as plain numbers, for the input
    // region in Bar.qml: it subtracts the GAPS between them from the bar's
    // strip, so a press in the spacing lands on the app underneath instead of
    // being swallowed (the fullscreen case -- see `gapPassthrough` there).
    // Measured here because this is where the islands are declared and where
    // their x and width live.
    //
    // SIX REALS, not a list of pairs, and the reason is a Qt bug in this
    // build: a `var` property holding a JS array came back out of its binding
    // as "should be coerced to void because the function called is
    // insufficiently annotated", once per island edge per frame, on both a
    // Region and a PanelWindow. Numbers do not do that, and the whole point of
    // the array was arithmetic that reads just as well spelled out.
    //
    // HORIZONTAL ONLY, and that is not a shortcut. The mask cuts full height
    // (it never used an island's y), and a y read through `mapToItem` would
    // have been a lie anyway: mapping registers no dependency on the item's
    // transform, so the slide translate left the binding holding the pre-slide
    // value -- measured, not guessed: the diagnostic reported the islands at
    // y = -45, off the top of the screen where they sit while slid out, for as
    // long as the bar stayed down. x and width are plain property reads, so
    // these do re-evaluate when an inline pocket grows an island.
    //
    // An island that is not painted contributes a ZERO-LENGTH run at the end
    // of the one before it, not a run at x = 0 -- which is what lets the
    // consumer treat the three of them as a sorted left-to-right sequence
    // without knowing which ones exist.
    readonly property real leftRunX: root.islandsPainted && leftIsland.visible
        ? leftIsland.x : 0
    readonly property real leftRunEnd: root.islandsPainted && leftIsland.visible
        ? leftIsland.x + leftIsland.width : 0
    readonly property real centerRunX: root.islandsPainted && centerIsland.visible
        ? centerIsland.x : leftRunEnd
    readonly property real centerRunEnd: root.islandsPainted && centerIsland.visible
        ? centerIsland.x + centerIsland.width : leftRunEnd
    readonly property real rightRunX: root.islandsPainted && rightIsland.visible
        ? rightIsland.x : centerRunEnd
    readonly property real rightRunEnd: root.islandsPainted && rightIsland.visible
        ? rightIsland.x + rightIsland.width : centerRunEnd

    // The islands' shadow: one instance per island, self-anchored to its
    // target (StyledRectangularShadow fills the target itself). Skipped when
    // the classic skin is on -- that one keeps its own loader below.
    component IslandShadow: StyledRectangularShadow {
        required property Item island
        target: island
        visible: root.islandsEnabled && Config.options.bar.showBackground && Config.options.bar.floatStyleShadow
    }
    IslandShadow { island: leftIsland }
    IslandShadow { island: centerIsland }
    IslandShadow { island: rightIsland }

    // ── The open tell ───────────────────────────────────────────────────
    // While the now bar's card floats over the screen (three-finger swipe
    // down), the centre island visibly "holds" it: the capsule grows a hair
    // and takes the accent as its border -- a quiet, legible link between
    // card and island. The old hovering glow slab washed out to a pale
    // white pill behind the card and has not been kept: the emphasis now
    // lives ON the capsule itself (see centerIsland below), where it
    // belongs and where it costs the middleSection Row nothing.

    Rectangle {
        id: leftIsland
        visible: root.islandsEnabled && Config.options.bar.showBackground
        readonly property real gap: Appearance.sizes.hyprlandGapsOut
        x: barLeftSideMouseArea.x + gap
        y: gap
        // Cover the row's REAL content extent -- now just the clock, since the
        // desktops moved out of the bar -- not the MouseArea's implicit width:
        // the MouseArea stretches all the way to the centre island (its click
        // zone), but the painted content ends at the clock. Measured off the
        // live widget so verbose-mode changes keep the capsule fitted.
        width: Math.max(24, clockWidget.x + clockWidget.width
            + Appearance.rounding.screenRounding + 12 - x)
        height: Appearance.sizes.barHeight - gap * 2
        radius: Appearance.rounding.windowRounding
        color: Appearance.colors.colBarBackground
        // Fill-only, like the other two capsules. See `centerIsland`.
        border.width: 0
        border.color: "transparent"
    }
    Rectangle {
        id: centerIsland
        // Always visible.
        //
        // It was hidden unless the now-bar card was open, on the reading that a
        // stage with no performance should not be drawn. That was wrong: with it
        // hidden the middle of the bar had NO capsule at all, so the bar's middle
        // was bare wallpaper between two light lozenges -- a black gap running the
        // width of the screen, which read as a broken bar rather than as a clean one.
        //
        // The `open` state still does its real job below: the capsule grows by
        // `openGrow` when the card comes out, so the card reads as THIS island
        // enlarged. That is the whole reason this island exists.
        visible: root.islandsEnabled && Config.options.bar.showBackground
        readonly property real gap: Appearance.sizes.hyprlandGapsOut
        // ── Open-state emphasis (the card is out) ──────────────────────
        // The island grows by the padding it gains and takes the accent as
        // its border: the card overhead reads as THIS island, enlarged --
        // not as a floating rectangle that happens to hover nearby. Both
        // properties ride the shell's fast curve so the grow resolves
        // together with the card's bloom.
        readonly property bool open: GlobalStates.nowBarPanelOpen
        readonly property real openGrow: 5
        // Symmetric around the row, never independent of it: middleSection is
        // anchored to the screen's horizontal centre, so the capsule rides
        // that same anchor -- `gap` of padding on EACH side -- and stays dead
        // centre whatever the now bar measures (mode swaps re-measure live).
        // The old maths (x: row.x + gap, width: row.width + gap) inset the
        // left edge and overhung the right by 2·gap: a capsule sitting right
        // of centre with the content's first pixels outside its own island.
        x: middleSection.x - gap - (open ? openGrow : 0)
        y: gap - (open ? openGrow : 0)
        width: middleSection.width + gap * 2 + (open ? openGrow * 2 : 0)
        height: Appearance.sizes.barHeight - gap * 2 + (open ? openGrow * 2 : 0)
        radius: Appearance.rounding.windowRounding
        color: Appearance.colors.colBarBackground
        // No border while closed, and the ACCENT border when the card is out.
        //
        // The border used to be 1px all the time, which in the light theme was
        // either invisible against the fill or, where it did read, a hard line
        // around a shape meant to sit quietly on the bar. So it went to zero --
        // and took the one place it was carrying meaning with it: the card
        // overhead is supposed to read as THIS island, enlarged, and in the
        // dark theme that link is the accent outline. Without it the card
        // floated free of the bar it is attached to.
        //
        // So the border is now conditional rather than deleted: nothing at
        // rest, the accent only while the card is open.
        border.width: open ? 1.5 : 0
        border.color: open ? Appearance.colors.colPrimary : "transparent"
        Behavior on x { animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this) }
        Behavior on y { animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this) }
        Behavior on width { animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this) }
        Behavior on height { animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this) }
        Behavior on border.color { animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this) }
    }
    Rectangle {
        id: rightIsland
        visible: root.islandsEnabled && Config.options.bar.showBackground
        readonly property real gap: Appearance.sizes.hyprlandGapsOut
        // The widest this island may ever be: its own closed width plus every
        // pixel the run to the centre island offers, less `inlineMinGap`.
        //
        // This is the "max width" the bar is held to, and it is stated as a
        // bound rather than left to the growth to arrive at by itself -- a
        // pocket can no longer widen the island into the centre one even if
        // the cap that normally prevents it is raised or mismeasured.
        //
        // `iconsW` is hoisted out because it is used by both the cap and the
        // width below, and because the width binding used to read `visible`
        // -- a property bound on THIS item. The `visible ? gap : 0` term it
        // replaced only ever subtracted the inset from an island nobody could
        // see, so nothing on screen changes by dropping it.
        //
        // The REAL bug, and the reason the right side of the bar had no
        // background at all with nothing in the log: the width below read
        // `root.rightIslandMaxW`. That property is declared on THIS island,
        // not on the root, so the lookup returned `undefined`,
        // `Math.min(undefined, n)` returned `NaN`, `Math.max(24, NaN)` stayed
        // `NaN`, and QML laid the Rectangle out at width 0 -- an island that
        // was visible, correctly positioned, and painted nothing. The cap is
        // referenced unqualified from here on purpose, for that reason.
        readonly property real iconsW: barRightSideMouseArea.implicitWidth
        readonly property real rightIslandMaxW: Math.max(24,
            iconsW + gap * 2 + root.inlineSpace)
        // At rest the icons' CELLS come out 14px inside the right edge and 18px
        // inside the left one. Not a bug in this line: `iconsW` is the row's
        // implicit width, which carries ~22px of invisible margins (the
        // battery's screen-edge inset above all), and this island grows
        // LEFTWARD with its right edge pinned -- so that invisible surplus
        // lands on the left. Measured: padLeft=18 padRight=14. It used to be
        // 20/1, i.e. the icons ran into the pill's right wall while the left
        // had a finger's width of nothing; that is the "compressed" look. The
        // remaining 4px is invisible next to the 22 the row itself carries and
        // is not worth a second padding number.
        x: barRightSideMouseArea.x + barRightSideMouseArea.width - width - gap
        y: gap
        // Grows LEFT to hold an inline pocket. The row is anchored to the
        // screen's right edge, so extra width appears on the left and the icons
        // never move -- the island gets wider, the controls keep their place.
        // The gap is the island's own inset, so the content sits inside the
        // painted pill rather than against its edge.
        //
        // Inline, the extra width is measured from the ICONS' INK (iconsInkX)
        // rather than from the row's implicit width: the implicit width
        // carries ~22px of invisible margins (the battery's screen-edge inset
        // chief among them), and adding the pocket's width on top of those put
        // the extended text 43px inside the island's left edge against the 14
        // the island's own padding is at rest -- the "spacing on the left of
        // the extend text is too big" report. Measured from the ink, the text
        // lands exactly `contentStartPad` inside the island in both states.
        width: Math.max(24, Math.min(rightIslandMaxW,
            root.inlineMode
                ? (barRightSideMouseArea.x + barRightSideMouseArea.width - gap)
                    - root.iconsInkX + root.inlineRuleGap + root.inlineNeededW
                : iconsW + gap * 2 + root.inlineNeededW))
        height: Appearance.sizes.barHeight - gap * 2
        radius: Appearance.rounding.windowRounding
        color: Appearance.colors.colBarBackground
        // Fill-only, like the other two capsules. See `centerIsland`.
        border.width: 0
        border.color: "transparent"
        // ── The grow ────────────────────────────────────────────────────
        // The island grows LEFTWARD (right edge is pinned to the icons'
        // right), so animating width moves only the left edge and the icons
        // never travel. Shares `inlineOpenMs` with the row inside so the pill
        // and its contents arrive as one motion.
        Behavior on width {
            NumberAnimation {
                duration: root.inlineOpenMs
                easing.type: Easing.OutCubic
            }
        }
    }

    // The inline pocket's home: INSIDE the right island, immediately left of
    // the icons. A plain Item, not a row item, so the RowLayout cannot fight it
    // for sizing -- the island is grown to match it explicitly just above.
    //
    // It is wrapped in `inlineCloak`, which is the real fix for the text
    // painting over the icons. The host TRANSLATES +140px on the way in (see
    // the swipe below), and a transform moves a clipped item's contents along
    // with it -- so for the length of that animation the whole row, separator
    // and all, was travelling straight across the wifi glyph. Measuring the
    // resting layout correctly cannot help: the overlap only exists while
    // something is moving. The cloak is a separate, never-moving box whose
    // right edge is the icons' edge, so the clip happens in a frame the
    // animation cannot escape.
    Item {
        id: inlineCloak
        z: 4
        // The island's vertical band; only the horizontal clip matters here.
        y: rightIsland.y
        height: rightIsland.height
        // Left edge pinned to the bar's own origin and the width measured from
        // the icons, so this box always ends exactly where the icons begin no
        // matter where the host has been translated to.
        x: 0
        width: root.iconsInkX
        clip: true
        // Invisible by construction: it exists only to cut its children off.
        // Nothing is painted here, so nothing shows where the cut falls.
        Item {
            id: inlineHost
            // Kept alive through the close: the island shrinks AROUND a
            // dissolving row instead of the row blinking out first.
            visible: root.inlineMode || swipeK > 0.01 || opacity > 0.01
            y: rightIsland.y
            height: rightIsland.height
            width: root.inlineHostW
            // No clip; the text may reach the icons precisely, so a hairline
            // separating the two never has to be invented to hide a cropped word.
            // Clip on the RIGHT (towards the icons), not on the left: the
            // status row slides in from +96px, and the slide may end with a
            // still-wide host whose last words have not been given their
            // width yet. A left clip would cut the LABEL ("Opening") -- the
            // word the eye reads first -- so the left is always clear; the right
            // was only ever a soft guard against transient overflow, and the
            // new layout makes that guard unnecessary: the host stops exactly at
            // the icons by construction.
            clip: false
            // Nothing more to clip: the host is complete, the rule is its right
            // edge, and the icons sit to its right with only the hairline gap
            // between. The row is now clipped on the LEFT only (see above) when
            // it slides in: that is the transient the clip is for (the label,
            // which the eye reads first). The right is now open for the full line.
            // The host's RIGHT edge is the hairline, and it stops exactly one
            // `inlineRuleGap` short of where the icons' own content begins.
            x: root.iconsInkX - root.inlineRuleGap - width
            // ── The swipe: text created out of thin air ──────────────────
            // The host translates from +140px and the OPACITY is slaved to the
            // same progress, so the leading edge of the text materialises as it
            // travels: at k=0 nothing exists, mid-travel the head of the line is
            // visible while the tail is still nothing, at k=1 everything has
            // arrived. The text is literally being written in as it moves --
            // which is what "start from nothing" means, rather than a slide of
            // an already-complete row.
            //
            // Opacity is a FUNCTION of swipeK, not an independent animation: two
            // independent curves drift apart (that drift was the old "fade ON
            // TOP of a slide", which read as appear-then-move). One property,
            // everything derived from it, nothing can desynchronise.
            property real swipeK: root.inlineMode ? 1 : 0
            Behavior on swipeK {
                NumberAnimation {
                    duration: root.inlineOpenMs
                    easing.type: Easing.OutCubic
                }
            }
            transform: Translate {
                x: (1 - inlineHost.swipeK) * root.inlineSwipePx
            }
            // Materialise: nothing at k=0, fully there by k=0.45 -- so the tail
            // of the line is still appearing while the head has already landed,
            // and the row is legible well before the motion ends.
            opacity: Math.max(0.0, Math.min(1.0, (inlineHost.swipeK - 0.05) / 0.4))
            // (the old `opacity: inlineMode ? 1 : 0` is REPLACED by the line
            // above: one property drives both travel and materialisation)
            Behavior on width {
                NumberAnimation {
                    duration: root.inlineOpenMs
                    easing.type: Easing.OutCubic
                }
            }
            // NO `Behavior on x` here, and its absence is the optimisation.
            //
            // `x` is a pure binding of `width` (the icons' edge, less the gap,
            // less this item's own width). As `width` animates, the binding
            // re-evaluates every frame and `x` already moves smoothly with it.
            // A second Behavior on top did not smooth anything -- it ran its own
            // 260ms curve toward a target that was itself moving, so `x` chased
            // `width` with a permanent quarter-second lag. That lag is what
            // made the text look like it was sliding relative to its own island.
            // One animation, one clock, no lag.
            // How blurred the row is right now: full blur when closed, clear when
            // open, animated between. The layer is switched OFF at zero, so a
            // resting bar pays nothing for the effect -- a live MultiEffect on
            // every frame of a shell that is always drawing is not free.
            // NOT readonly: a Behavior is sugar for an assignment to the property
            // it animates, and Qt rejects that outright on a readonly one.
            property real blurAmount: root.inlineMode ? 0 : 1
            Behavior on blurAmount {
                NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
            }
            layer.enabled: blurAmount > 0.02
            layer.effect: MultiEffect {
                blur: inlineHost.blurAmount
                blurMax: 4
            }
            // The hairline dividing the info from the icons. The island's outline
            // is the only border the eye has to follow, so this is drawn at the
            // outline's own colour at reduced alpha -- a division, not a second
            // outline, which is what made the old drop read as a separate object.
            //
            // Inset from the host's right edge by `inlineRuleInset` -- the value
            // that puts exactly `inlineRuleGap` between the rule and the ICONS,
            // the same gap the text gets on the other side. The host is grown by
            // the same amounts above, so the space comes out of the island rather
            // than pushing the line into the controls.
            //
            // The rule is now hard rather than a hairline: when the info has
            // reached the icons, this line is what separates them, so the
            // word is not hidden and the icons do not overlap.
            Rectangle {
                id: inlineRule
                anchors.right: parent.right
                anchors.rightMargin: root.inlineRuleInset
                width: 1
                // The hairline spans the island's own height band, and rides on
                // the same optical centre as the text beside it -- the icons'
                // ink, not the host's middle. Centred on the host it sat 5.5px
                // below the words it was dividing, which is the one alignment
                // in the row the eye checks first and forgives least.
                //
                // It was also cut to the font's cap band (9px) to sit tight
                // against the text, and at that size it read as a speck the eye
                // had to hunt for. 42% of the host is where it started.
                height: parent.height * 0.42
                y: (parent.height - height) / 2 - root.inlineTextLift
                // The bar's own edge colour, not `colOutlineVariant`.
                //
                // `colOutlineVariant` is the light palette's INTERNAL hairline
                // tone (#C6C6C6) -- correct for a divider between two panels
                // that are the same white, invisible for a divider that has to
                // be read against a surface behind it. Faded to 35% on top of
                // that, on the light bar this line simply disappeared: 1.0:1,
                // a divider with no contrast at all. The line this bar draws
                // is the same kind of object as the bar's own outline, so it
                // takes the same colour.
                color: Appearance.colors.colBarBackgroundBorder
            }
        }
    }

    // The classic single-slab skin, kept for bar.islands: false.
    Rectangle {
        id: barBackground
        visible: !root.islandsEnabled
        anchors {
            fill: parent
            margins: Config.options.bar.cornerStyle === 1 ? (Appearance.sizes.hyprlandGapsOut) : 0 // idk why but +1 is needed
        }
        color: Config.options.bar.showBackground ? Appearance.colors.colBarBackground : "transparent"
        radius: Config.options.bar.cornerStyle === 1 ? Appearance.rounding.windowRounding : 0
        border.width: Config.options.bar.cornerStyle === 1 ? 1 : 0
        border.color: Appearance.colors.colBarBackgroundBorder
    }

    // ── Where the cursor is, across the WHOLE bar ─────────────────────────
    // Nothing in this shell can answer "has the cursor moved?" -- Hyprland's
    // IPC carries no pointer position on this build, and there is no cursor
    // source anywhere in the config. One item the full width of the bar, with
    // nothing painted on it, is the cheapest way to have one.
    //
    // A HoverHandler and not a MouseArea, which is the whole reason this is
    // safe to put under everything: pointer handlers do not block one
    // another or the MouseAreas already covering the bar, so this one sees
    // the cursor across the islands without touching a single click, panel
    // open/close or scroll handler. A MouseArea here would have taken the
    // hover from all of them.
    Item {
        id: cursorTrack
        anchors.fill: parent
        HoverHandler { id: cursorTrackHover }
        // In the same coordinates the gap hints measure themselves in: this
        // item fills the content root, and so do they.
        readonly property real hoverX: cursorTrackHover.point.position.x
        readonly property real hoverY: cursorTrackHover.point.position.y
        readonly property bool inside: cursorTrackHover.hovered
    }
    readonly property real cursorX: cursorTrack.hoverX
    readonly property real cursorY: cursorTrack.hoverY
    // Is the cursor over the bar's MIDDLE -- the clock / now bar?
    //
    // Read once here and given to both gap hints, so the two lines can never
    // disagree about it. 2px of slack: the island's width is fractional and
    // reflows land a hair either way, and the point of this is to stop a line
    // being lit over the middle, so erring towards "on the middle" is the
    // right way to be wrong.
    readonly property bool cursorOnCenterIsland: cursorInBar
        && centerIsland.visible
        && cursorX > centerIsland.x - 2
        && cursorX < centerIsland.x + centerIsland.width + 2
    // Whether the cursor is over the bar AT ALL. Without this a cursor that
    // left the bar downward would freeze at its last x and read as "still
    // hovering" forever, since the track only updates while it is over us.
    readonly property bool cursorInBar: cursorTrack.inside

    // ── The bar's indication line ────────────────────────────────────────────
    // A launch in flight was the original face; the line is now the desktop's
    // general status channel (services/StatusSignal.qml) with three faces:
    //
    //   * charge (app opening): the line fills from the left until the window
    //     arrives, then fades. GlobalStates owns this lifecycle.
    //   * failure: the WHOLE line blinks -- full-width red on the on beat,
    //     gone on the off beat, with no easing into position (the old face
    //     LOADED UP to full width and drained, twice, then ended -- removed
    //     on request 2026-10-18: that read as a progress meter dying, not as
    //     an alarm). The corner card still carries the sentence and the
    //     screen-border flare says it beyond the bar.
    //   * blink (general status -- charger connected, screenshot, ...): one
    //     soft full-width pulse in the signal's colour. Over a fullscreen app
    //     the bar is hidden, so the same pulse also renders as a tiny tell in
    //     the top-right corner (modules/ii/bar/StatusTell.qml).
    //
    // A grace period keeps the charge off instant launches (see
    // GlobalStates.loadingLineGraceMs), and the line is visible whichever
    // skin is on -- the islands are laid out even when the classic slab
    // draws. The channel lives in StatusSignal; this item only draws.
    Item {
        id: loadingLine
        readonly property bool chargeLive: StatusSignal.loadingLine && !StatusSignal.loadingFailFlash
        readonly property bool failLive: StatusSignal.loadingFailFlash
        // The failure face blinks (StatusSignal owns the clock). Without this
        // the fill was one flat red bar held for its whole life, which is a
        // thing you have to already be looking at to notice.
        readonly property bool failOn: StatusSignal.loadingFailOn
        readonly property bool blinkLive: StatusSignal.hasPulse && StatusSignal.pulse.kind === "blink"
        readonly property color blinkColor: StatusSignal.pulse?.color ?? Appearance.colors.colPrimary
        // The blink's text, for the extended island: charger in/out carries a
        // sentence ("Battery charging"). Empty for colour-only blinks.
        readonly property string blinkText: StatusSignal.pulse?.text ?? ""
        // A download's fill uses the primary accent and the real fraction
        readonly property bool downloadLive: GlobalStates.downloadProgress >= 0 && StatusSignal.loadingLine

        // No update face here. The progression lives in the island's own
        // activity TAB (see NowBar's progressView) -- a bar inside the tab it
        // belongs to, rather than one drawn edge to edge under the whole bar
        // while the island was saying the same thing again.

        // ── The meter face (brightness / volume) ──────────────────────────
        // The line shows a VALUE while this is live: it fills to the actual
        // brightness or volume, edge to edge, and a label chip beside the
        // middle island names which of the two. StatusSignal owns the
        // lifecycle -- every change re-arms its clock, so a continuous swipe
        // keeps the line up for the whole gesture.
        //
        // It OUTRANKS the charge, deliberately. A launch in flight is progress;
        // a value under a moving finger is the thing being SET, and the charge
        // used to win -- so a swipe made while an app was opening drew the
        // launch's own fill instead (100%, once the charge had run long enough
        // to reach the end) and then, when the window arrived, slid down to the
        // value the fingers had already set. The volume it changed was never in
        // doubt; the bar was simply reporting the wrong face. The failure and
        // alert faces stay above this one because they are WARNINGS, and a
        // warning outranks a readout; progress does not.
        readonly property bool meterLive: StatusSignal.meterLive
            && !failLive && !blinkLive && !StatusSignal.hasBatteryAlert
        readonly property bool meterIsBrightness: StatusSignal.meterKind === "brightness"
        readonly property color meterColor: meterIsBrightness
            ? Appearance.colors.colTertiary
            : Appearance.colors.colPrimary
        // -- The battery-alert face (low battery) -------------------------
        // The line blinks the error colour for the alert's `blinks` count.
        // Sits above the meter (a battery warning outranks a volume change)
        // but below the launch failure.
        readonly property bool alertLive: StatusSignal.hasBatteryAlert
            && !chargeLive && !failLive && !blinkLive

        // -- Which face the line fades out WITH ----------------------------
        //
        // The meter is the line's face while it is live, and it STAYS the
        // face while its own exit fades. Both fills below read this, because
        // the alternative was reported and read as a deliberate signal: the
        // instant the meter stopped, `chargeFill` -- gated only on "the meter
        // is not live" -- appeared at the width a COMPLETED launch leaves
        // behind (`fillProgress` is 1 from then on, until a fresh launch
        // zeroes it), so the whole strip flashed one bright full-width bar
        // and then faded out. The volume the fingers had just set was nowhere
        // in that picture. With this, the meter's own fill keeps drawing at
        // its last value for the length of the fade, which is what "the bar
        // at the level it is, fading out" has to mean.
        //
        // A fresh meter clears the hold, and so does every OTHER face taking
        // the line over: a launch's own fade must draw its own fill, not
        // whatever volume was last set. Clearing on all four faces is what
        // keeps this state from outliving the exit it belongs to, and the
        // visible test retires it with the line itself.
        property bool meterExit: false
        readonly property bool meterFace: loadingLine.meterLive
            || (loadingLine.meterExit && !loadingLine.chargeLive && !loadingLine.failLive
                && !loadingLine.blinkLive && !loadingLine.alertLive)
        onChargeLiveChanged: if (chargeLive) loadingLine.meterExit = false
        onFailLiveChanged: if (failLive) loadingLine.meterExit = false
        onBlinkLiveChanged: if (blinkLive) loadingLine.meterExit = false
        onAlertLiveChanged: if (alertLive) loadingLine.meterExit = false
        onVisibleChanged: if (!visible) loadingLine.meterExit = false
        Connections {
            target: StatusSignal
            function onMeterLiveChanged() {
                // A hand on the bar (volume, brightness) clears whatever state
                // the line was left in: the sweep latch, a half-finished
                // charge, and the meter's own exit hold. So the reading being
                // changed is what shows -- and when it ends, nothing is left
                // behind to paint a solid bar at the level of some earlier
                // event.
                if (StatusSignal.meterLive) {
                    loadingLine.finishing = false;
                    loadingLine.wasCharging = false;
                    loadingLine.meterExit = false;
                    if (!loadingLine.chargeLive) {
                        loadingLine.restarting = true;
                        loadingLine.fillProgress = 0;
                        Qt.callLater(() => { loadingLine.restarting = false; });
                    }
                    return;
                }
                // Only a meter that was actually on screen earns the hold.
                loadingLine.meterExit = loadingLine.visible;
            }
        }

        // Edge to edge under all three islands, with the bar's own side gap
        // as breathing room on each end.
        readonly property real edgePad: Appearance.sizes.hyprlandGapsOut
        x: edgePad
        width: root.width - edgePad * 2
        // In the hairline of space between the content row and the strip's
        // bottom edge -- the same slot the old pill used, so it sits in the
        // gap the islands already leave and covers all of them.
        y: parent.height - height - 2
        height: 2
        visible: opacity > 0.01
        opacity: ((loadingLine.chargeLive && !loadingLine.chargeOverstayed) || loadingLine.failLive
            || loadingLine.blinkLive
            || loadingLine.meterLive || loadingLine.alertLive || loadingLine.finishing)
            // The failure face blinks the WHOLE line: off beat = gone, on
            // beat = the full width in red (the fill is pinned to full while
            // failLive -- see chargeWidth). This is the request of
            // 2026-10-18: blink the full bar, do not load it up twice.
            ? (loadingLine.failLive && !StatusSignal.loadingFailOn ? 0 : 1)
            : 0
        Behavior on opacity {
            // Hard cuts while the failure blinks (an eased blink reads as a
            // wobble, not a flag); every other face keeps its fade.
            enabled: !loadingLine.failLive
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }

        // 0..1 how far the charge has travelled. A new launch restarts it
        // from zero; while the line is down the value is simply invisible.
        //
        // NO implicit Behavior on this property, and that is load-bearing
        // rather than tidiness. The fill's own `Behavior on width` already
        // eases the growth, so this one only ever added a second easing on
        // top of it -- EXCEPT on the restart, where it did the opposite of
        // what it was for: a fresh launch assigns 0 here, and because the
        // previous launch had run its finish sweep to 1, the Behavior
        // animated the way DOWN. Every launch after the first therefore
        // opened with the bar at full, draining itself to empty, and only
        // then starting to fill. `restarting` below is the escape hatch that
        // makes the reset instant instead.
        property real fillProgress: 0
        // True only for the instant a fresh launch zeroes the charge. Set
        // BEFORE the assignment and cleared a tick later, so the fill's
        // width binding is guaranteed to re-evaluate while the behaviour is
        // switched off -- the ordering is this file's, not Qt's.
        property bool restarting: false

        // True between "the app arrived" and "the charge has finished
        // sweeping". The charge crawls 2% every 100ms, so a launch that took
        // two seconds was still only at 40% when its window appeared -- and
        // the line used to simply fade out from there. That reads as the bar
        // being cut off mid-way rather than finishing, which is the whole
        // point of drawing a progress charge: it should arrive, not stop.
        // A failed launch is deliberately NOT swept (it keeps its red fill and
        // fades out as an error, not a success), which is what the
        // `!loadingFailFlash` test below decides.
        property bool finishing: false
        // A charge that never resolves is not still loading -- it is a wait
        // whose ending went missing (a window the launch watcher never saw, a
        // program that died on startup). The crawl tops out at full five
        // seconds in, and from there an unresolved charge sat as a solid
        // full-width bar for as long as the wait's own half-minute ceiling
        // kept it alive. That is the one thing the charge face must never do:
        // a still bar reads as a stuck desktop, not as patience. This latch
        // caps the face instead -- after seven seconds the charge stops
        // counting as a face and the line fades out, so the most a stuck
        // launch can leave behind is a fade.
        property bool chargeOverstayed: false
        // Whether the line was mid-charge a moment ago. `chargeLive` is
        // already false by the time the change handler runs -- it is derived
        // from the very signal that changed -- so without this the handler
        // could not tell a completed wait from a cancelled one.
        property bool wasCharging: false

        // The charge's own ceiling. Bound to the face rather than started by
        // hand, so it re-arms with every fresh wait and cannot outlive one;
        // the latch above is what keeps it from firing twice. A download is
        // exempt: it is the one wait that may legitimately run for minutes
        // (GlobalStates' ceiling exempts it too), and cutting its real
        // percentage short would be worse than a long line.
        Timer {
            id: chargeCap
            interval: 7000
            repeat: false
            running: loadingLine.chargeLive && !loadingLine.chargeOverstayed
                && GlobalStates.downloadProgress < 0
            onTriggered: loadingLine.chargeOverstayed = true
        }


        NumberAnimation {
            id: finishSweep
            target: loadingLine
            property: "fillProgress"
            to: 1
            // Long enough to read as a deliberate run to the end, short
            // enough that the app does not feel like it is holding the
            // desktop hostage while a bar catches up.
            duration: 220
            easing.type: Easing.OutCubic
            onStarted: loadingLine.finishing = true
            onFinished: loadingLine.finishing = false
        }

        Connections {
            target: StatusSignal
            function onLoadingLineChanged() {
                // Only a FRESH wait restarts the charge (and only the wait
                // face -- a failure keeps its red fill until the fade).
                if (StatusSignal.loadingLine && !StatusSignal.loadingFailFlash) {
                    finishSweep.stop();
                    loadingLine.finishing = false;
                    loadingLine.chargeOverstayed = false;
                    loadingLine.restarting = true;
                    loadingLine.fillProgress = 0;
                    Qt.callLater(() => { loadingLine.restarting = false; });
                    loadingLine.wasCharging = true;
                } else if (loadingLine.wasCharging && !StatusSignal.loadingFailFlash) {
                    // The wait ended the good way -- the window we were
                    // waiting for is here. Run the charge out to the end and
                    // only then let the line go.
                    loadingLine.wasCharging = false;
                    // An arrival AFTER the cap does not re-light the line: it
                    // has already faded, and a 220ms sweep out of nothing
                    // would read as a new event rather than the end of an old
                    // one.
                    if (!loadingLine.chargeOverstayed)
                        finishSweep.restart();
                    loadingLine.chargeOverstayed = false;
                } else {
                    loadingLine.wasCharging = false;
                    loadingLine.chargeOverstayed = false;
                }

    }
}

        // While the line is up as a WAIT, advance the charge one tick at a
        // time -- a steady crawl toward full, not a loop, so it reads as
        // progress being made rather than motion for its own sake.
        // A real download overrides the crawl: the fill then shows the
        // actual fraction from the downloader.
        Timer {
            id: chargeCrawl
            interval: 100
            running: loadingLine.visible && loadingLine.chargeLive
                && !loadingLine.chargeOverstayed && GlobalStates.downloadProgress < 0
            repeat: true
            onTriggered: loadingLine.fillProgress = Math.min(1, loadingLine.fillProgress + 0.02)
        }
        Connections {
            target: GlobalStates
            function onDownloadProgressChanged() {
                if (GlobalStates.downloadProgress >= 0)
                    loadingLine.fillProgress = GlobalStates.downloadProgress;
            }
        }

        // The blink's one-shot clock lives in StatusSignal now (pulseExpiry).
        // It used to live here, and that is exactly how a pulse could be
        // stranded: anything that stopped this timer from firing -- a reload
        // mid-blink, a restart every time the pulse changed -- left the pulse
        // set, and a set pulse paints a solid full-width line AND outranks the
        // meter. The service owns its own expiry so no consumer can strand it.

        // The other latch that can outlive its animation: `finishing` keeps a
        // completed launch's fill on screen while it sweeps to the end. The
        // sweep is 220ms, so a latch still held after 450ms belongs to no
        // animation at all -- typically one stopped mid-flight -- and it left
        // the strip painted SOLID at 100% for the rest of the session, which
        // is the report this answers. Dropping the latch hands the line back
        // to its opacity binding, so it goes away normally.
        Timer {
            interval: 450
            repeat: true
            running: loadingLine.finishing
            onTriggered: {
                finishSweep.stop();
                loadingLine.finishing = false;
                if (!loadingLine.chargeLive)
                    loadingLine.fillProgress = 0;
            }
        }

        // The track: the full span, faint -- error colour on failure, the
        // signal's colour on a blink, the meter's accent on a meter. On the
        // failure face it stays red through the OFF beat too, so the two
        // flashes read as one line blinking rather than as two separate
        // events appearing and disappearing.
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: loadingLine.failLive
                ? ColorUtils.transparentize(Appearance.colors.colError, 0.72)
                : loadingLine.blinkLive
                    ? ColorUtils.transparentize(loadingLine.blinkColor, 0.72)
                    : loadingLine.alertLive
                        ? ColorUtils.transparentize(Appearance.colors.colError, 0.78)
                        : loadingLine.meterFace
                            ? ColorUtils.transparentize(loadingLine.meterColor, 0.78)
                            : ColorUtils.transparentize(Appearance.colors.colPrimary, 0.78)
            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
        }

        // The charge's fill: the launch's progress, or one of the blink faces.
        // The METER has its own item, right below: the two faces carry
        // unrelated widths (a launch's charge sits at 100% once it has run to
        // the end and stays there until the next launch) and sharing one item
        // let the value inherit the charge's width -- the "the bar jumps from
        // 100 to the actual value" report.
        Rectangle {
            id: chargeFill
            anchors {
                left: parent.left
                top: parent.top
                bottom: parent.bottom
            }
            // What the charge says. Split out from `width` so the restart can
            // bypass the ease: a new launch has to appear EMPTY, and an
            // animated width would show the last launch's 100% running back
            // out of the bar first.
            //
            // The meter is deliberately NOT a branch here any more: what it
            // draws has nothing to do with a charge's progress, and being one
            // is what left a completed charge's 1.0 on the item the meter then
            // appeared in (the meter's own fill below owns that value).
            // The failure face is FULL width. Its blink deliberately does NOT
            // come from a width toggle (that would read as a wobble, not a flag);
            // the blink lives in the line's opacity instead, on/off with no
            // animation. chargeWidth is pinned to 1 while failLive so the line
            // stays fully lit in red during the failure blink.
            readonly property real chargeWidth: parent.width
                * (loadingLine.blinkLive ? 1
                    : loadingLine.failLive ? 1
                    : loadingLine.alertLive ? (StatusSignal.batteryAlertOn ? 1 : 0.04)
                    : loadingLine.fillProgress)
            // Both branches are 0 while restarting -- fillProgress has
            // already been zeroed -- so switching the behaviour back on a
            // tick later cannot start an animation from nothing.
            width: loadingLine.restarting ? 0 : chargeWidth
            // Hidden, not merely overdrawn: while the meter is the line's face
            // this fill's number is not what the bar says -- and that now
            // covers the meter's own fade-out, where this fill used to
            // reappear at a finished launch's 100% (see `meterFace`).
            // The failure blink uses hard on/off in chargeWidth (set to 1 above),
            // and the line's opacity flickers (see failLive / loadingFailOn in
            // StatusSignal). This gives a clean flag without the wobble.
            visible: !loadingLine.meterFace
            radius: height / 2
            color: loadingLine.failLive
                ? Appearance.colors.colError
                : loadingLine.blinkLive
                    ? loadingLine.blinkColor
                    : loadingLine.alertLive
                        ? Appearance.colors.colError
                        : Appearance.colors.colPrimary
            Behavior on width {
                enabled: !loadingLine.restarting
                NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
            }
            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
        }

        // The meter's fill: brightness or volume, and nothing else.
        //
        // A separate item for two reasons. The first is TRUTH: this width is
        // `StatusSignal.meterValue` and can never be anything else, so the bar
        // shows the value the frame the face appears -- where the shared fill
        // eased down from whatever the previous face had left on it, which for
        // a swipe made around a launch was the charge's 100%. The second is
        // that the width is genuinely two things: the charge's progress and the
        // value being set were never the same number, and one item made them
        // fight over one.
        //
        // The ease stays, for the reason the shared fill had one -- a single
        // key-press step should glide rather than teleport -- but it is now
        // confined to a live face. Zero WHILE THE LINE IS DOWN (keyed on the
        // line, not on the face): a face that appears with the line already
        // down grows from nothing as the line fades in, which is invisible,
        // and one that takes over a line already up (a launch resolving mid-
        // swipe) is untouched and so appears at the value outright.
        Rectangle {
            id: meterFill
            anchors {
                left: parent.left
                top: parent.top
                bottom: parent.bottom
            }
            visible: loadingLine.meterFace
            width: loadingLine.visible ? parent.width * StatusSignal.meterValue : 0
            radius: height / 2
            color: loadingLine.meterColor
            Behavior on width {
                NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
            }
        }
    }



    // ── The download caption ─────────────────────────────────────────────
    // A download rides the indication line above as its fill -- but the line
    // carries no words. So while the downloader reports a
    // file, this small caption names it: "(downloading Discord)" in a mini
    // island parked in the free strip just left of the right island, level
    // with the row and directly above the line's right end. Same lifecycle
    // as the line's download face: up with the first progress report, gone
    // when the download completes or clears.
    Rectangle {
        id: downloadCaption
        readonly property bool downloadLive: GlobalStates.downloadProgress >= 0
            && GlobalStates.downloadName !== ""
        visible: opacity > 0.01
        opacity: downloadCaption.downloadLive ? 1 : 0
        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        // The right island's own left edge minus the island gap: the caption
        // can never sit on the battery cluster, and anything it needs grows
        // leftward into the empty strip toward the middle island.
        anchors {
            right: barRightSideMouseArea.left
            rightMargin: Appearance.sizes.hyprlandGapsOut + 8
            verticalCenter: parent.verticalCenter
        }
        height: 22
        width: captionText.implicitWidth + 20
        radius: height / 2
        color: Appearance.colors.colBarBackground
        // Fill-only, like every capsule on the bar: the label inside carries
        // what this is, and an outline would be a second border on a bar whose
        // only permitted one is the centre island's open tell.
        border.width: 0
        Text {
            id: captionText
            anchors.centerIn: parent
            text: `(downloading ${GlobalStates.downloadName})`
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            font.family: Appearance.font.family.main
        }
    }

    FocusedScrollMouseArea { // Left side | scroll to change brightness
        id: barLeftSideMouseArea

        anchors {
            top: parent.top
            bottom: parent.bottom
            left: parent.left
            right: middleSection.left
        }
        implicitWidth: leftSectionRowLayout.implicitWidth
        implicitHeight: Appearance.sizes.baseBarHeight

        onScrollDown: if (!root.padScrollBlocked) Brightness.decreaseBrightness()
        onScrollUp: if (!root.padScrollBlocked) Brightness.increaseBrightness()
        onMovedAway: GlobalStates.osdBrightnessOpen = false
        onPressed: event => {
            if (event.button === Qt.LeftButton) {
                // The empty stretch of the bar used to toggle the left
                // sidebar. It opens the desktop overview now (design A in
                // design/desktop-view/index.html) -- the same surface SUPER+Tab
                // and SUPER+Z open. (It used to be named as the SUPER +
                // four-finger swipe down's surface as well; that gesture is
                // removed, 2026-10-16.) The sidebar still has
                // its own explicit entry points (its own button, SUPER+A), so
                // nothing became unreachable; what changed is that a tap on
                // bare bar no longer summons a panel you did not ask for.
                // Bare bar only: the clock's island is a control surface too,
                // and a press in the padding around the clock is not a press on
                // the empty bar. See `pressedOnBareBar`.
                if (root.pressedOnBareBar(event, barLeftSideMouseArea, leftIsland))
                    GlobalStates.desktopOverviewOpen = !GlobalStates.desktopOverviewOpen;
            }
        }

        // Visual content
        // The scroll hint icon (a little moon/sun that slid in while hovering the
        // left end of the bar) was removed on request, so the corner stays clean
        // next to the clock. Scrolling the left bar still changes the brightness.

        RowLayout {
            id: leftSectionRowLayout
            anchors.fill: parent
            spacing: 0

            // The top-left icon button was removed on request. The left sidebar
            // is opened by its own button (LeftSidebarButton, further right in
            // this strip) or SUPER+A -- the bar's empty stretch, which used to
            // toggle it, opens the desktop overview now.

            // Clock lives on the left now (was: ActiveWindow title widget, and the
            // clock was in the middle section).
            ClockWidget {
                id: clockWidget
                Layout.leftMargin: Appearance.rounding.screenRounding + 8
                Layout.rightMargin: Appearance.rounding.screenRounding
                Layout.alignment: Qt.AlignVCenter | Qt.AlignLeft
                Layout.fillHeight: true
                showDate: (Config.options.bar.verbose && root.useShortenedForm < 2)
            }

            // (The focused-app icon lived here; removed on request -- the
            // bar shows the clock, nothing else on the left.)
            //
            // (The desktops lived here too, and are gone from the bar as well:
            // a row of dots that only ever changed when you switched desktop
            // was paying bar space -- the scarcest room on the screen -- for a
            // status. They now live in a small pill at the bottom of the
            // screen, out of the bar entirely: see modules/ii/desktopIndicator.
            // The widget is untouched, so click-to-switch, the desktop grid on
            // right-click, the wheel and the "+" slot all still work there.)
        }
    }

    Row { // Middle section -- the NOW island
        // The centre island is one dynamic view: the now bar (pomodoro >
        // media > AI usage, auto-swapping on audio, 2-finger swipe to flip).
        // The desktops it carried live in the left island now, and the
        // utility buttons and the old now-playing group retired with the
        // slab (the utility buttons' homes are one right-click away in the
        // sidebars).
        id: middleSection
        // (No implicitWidth here: this is a Row, whose implicitWidth is
        // read-only. Assigning the old `root.centerSideModuleWidth` to it is
        // exactly what had been dropped -- the capsule below measured that
        // dead property and fell to its 24px floor, a hairline of background
        // behind a full island's worth of content.)
        anchors {
            top: parent.top
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
        }

        NowBar {
            id: nowBar
            anchors.verticalCenter: parent.verticalCenter
        }

        // The island's frame, published for the popped-out panel: only this
        // file can map the island into the bar's coordinate system, and the
        // panel grows out of exactly that box (see NowBarPanel).
        Binding {
            target: GlobalStates
            property: "nowBarCenterX"
            value: root.centerXFor(nowBar)
        }
        Binding { target: GlobalStates; property: "nowBarWidth"; value: nowBar.width }
        Binding { target: GlobalStates; property: "nowBarHeight"; value: nowBar.height }

        // The island popped out (three-finger swipe down). A Scope, not an
        // item: it belongs to this section visually but takes no layout space.
        NowBarPanel {
            id: nowBarPanel
            anchorItem: nowBar
        }

        // The launch-argument settings, on their own fullscreen surface.
        //
        // Mounted HERE rather than inside NowBarPanel because a PanelWindow
        // has to be somewhere in the loaded tree to exist at all, and the
        // popup is a Scope for the island -- a window parented to it would
        // die with the island's geometry rather than outliving it.
        LlamaSettingsWindow { }

        // The island's hover extends the pocket. The CENTER comes from
        // centerXFor(nowBar) -- the same mapping the battery and sound drops
        // use -- because the pocket positions itself in bar coordinates and
        // the island cannot know that frame from inside itself.
        Connections {
            target: GlobalStates
            function onNowBarExpandedChanged() {
                if (GlobalStates.nowBarExpanded)
                    root.armPocket("nowbar", root.centerXFor(nowBar),
                        root.centerIslandLeft, root.centerIslandRight);
                else if (LiquidBar.pocketId === "nowbar")
                    LiquidBar.setPocket("");
            }
        }

        // The popped-out card and the pocket never show at once: the pocket
        // only ever opens from the retired hover trigger now, but a pocket
        // already on screen when the three-finger swipe lands must go -- the
        // card blooms over a pale pill otherwise, which is the washed-out
        // look the open tell above replaced.
        Connections {
            target: GlobalStates
            function onNowBarPanelOpenChanged() {
                if (GlobalStates.nowBarPanelOpen) {
                    if (GlobalStates.nowBarExpanded)
                        GlobalStates.nowBarExpanded = false;
                    else if (LiquidBar.pocketId === "nowbar")
                        LiquidBar.setPocket("");        }

    }
}

    }

    FocusedScrollMouseArea { // Right side | scroll to change volume
        id: barRightSideMouseArea

        anchors {
            top: parent.top
            bottom: parent.bottom
            left: middleSection.right
            right: parent.right
        }
        implicitWidth: rightSectionRowLayout.implicitWidth
        implicitHeight: Appearance.sizes.baseBarHeight

        // Volume is NOT here any more. Scrolling the right end of the bar used to
        // change the volume and this area showed a "scroll to change volume" hint,
        // which made the whole right section feel like a volume control. The volume
        // slider now lives in the right sidebar, between the system buttons and the
        // media player.
        onPressed: event => {
            if (event.button === Qt.LeftButton) {
                // Symmetric with the left stretch above: the desktop overview,
                // not the right sidebar. See the note there for why the
                // sidebars kept their own explicit buttons.
                //
                // BUT ONLY ON BARE BAR -- see `pressedOnBareBar`. This area
                // covers the whole right stretch, island and all, and every
                // pixel of the island that no icon's own MouseArea claims
                // (the padding around the pins, the gaps between two icons)
                // used to land here and open the overview. Clicking the island
                // is not clicking the bar.
                if (root.pressedOnBareBar(event, barRightSideMouseArea, rightIsland))
                    GlobalStates.desktopOverviewOpen = !GlobalStates.desktopOverviewOpen;
            }
        }

        RowLayout {
            id: rightSectionRowLayout
            anchors.fill: parent
            // NO spacing of its own, and NO per-item margins either: every
            // icon carries `root.iconInset` on BOTH sides, so the gap between
            // any two neighbours is exactly `2 * root.iconInset`. A strip
            // `spacing` here would be a SECOND number meeting those insets and
            // adding to them -- the exact clutter that produced the unevenness
            // this replaces. One number, applied per icon, is the whole of it.
            spacing: 0
            layoutDirection: Qt.RightToLeft
            // ── The strip's own inset from the bar's right edge ────────────
            //
            // The island paints its padding as `gap` on both sides of the
            // icons' box (see `rightIsland`'s width), so the box has to stop
            // `gap` short of the island's edge -- and the island's own edge is
            // already `gap` inside the bar. `2 * gap` here puts the last icon
            // exactly where the island's padding expects it: the icons then sit
            // centred in the capsule instead of jammed against its right end
            // (measured before this: 20px of air on the left of the leftmost
            // icon, 1px on the right of the rightmost).
            //
            // A margin on the ROW, not on an icon: a per-icon margin is the
            // second number this strip spent its history fighting.
            anchors.rightMargin: Appearance.sizes.hyprlandGapsOut * 2

            // Fullscreen pin: only exists while the bar was summoned over a
            // fullscreen window. One click and the bar STAYS (hover-dwell
            // summons transiently; the pin keeps). Click again to release --
            // or just leave fullscreen, which unpins automatically.
            RippleButton {
                id: fsPinButton
                // No swell; the hover fill is the cue.
                visible: barContent.fsPinned || barContent.overFullscreen
                Layout.alignment: Qt.AlignVCenter
                // The same inset as every other icon, on both sides, so this
                // pin sits exactly as far from its neighbours as they do from
                // each other. See `iconInset`.
                Layout.leftMargin: root.iconInset
                Layout.rightMargin: root.iconInset
                implicitWidth: 22
                implicitHeight: 22
                // Same oval removal as the pill: the default hover fill is a
                // plate this flat icon never asked for.
                colBackgroundHover: ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)
                colRipple: Appearance.colors.colLayer1Hover
                onClicked: barContent.togglePin()
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "push_pin"
                    iconSize: 15
                    fill: barContent.fsPinned ? 1 : 0
                    color: barContent.fsPinned ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
                }
            }

            BatteryIndicator {
                id: batteryIndicator
                // Removable from the sidebar's edit mode (or Settings › Bar):
                // `bar.indicators.battery`. `!== false` because a config written
                // before this switch existed has no value for it, and the bar has
                // always shown the charge.
                visible: (root.useShortenedForm < 2 && Battery.available
                    && Config.options.bar.indicators.battery !== false)
                // Both sides of the battery carry the SAME inset as every other
                // icon in the strip, and the bolt sits flush against the pill
                // between them: the pill and the bolt are ONE mark ("this
                // battery, charging"), so there is no gap between them to keep
                // even. `boltGap: 0` is not a spacing this change strips -- it
                // is the bolt belonging to its own pill, not a neighbour of it.
                //
                // The `7` on the left and the `16` on the right that used to
                // live here were the whole of the unevenness this bar kept being
                // reported for: the battery alone carried extra margins, so the
                // air on its left ran wider than the air on its right, and the
                // strip's single spacing could never compensate for a per-icon
                // margin it did not know about. Both are `root.iconInset` now,
                // the one number every icon in the run is inset by -- see it for
                // the whole story.
                boltGap: 0
                // ...and the air AFTER the bolt, which together with this
                // item's own `iconInset` right margin below is the bar's
                // RIGHT END spacing. It mirrors the clock's leading air: the
                // clock opens the bar `Appearance.rounding.screenRounding + 8`
                // from the left edge (see leftSectionRowLayout), so the bolt
                // ends `screenRounding + 8` from the right edge -- `iconInset`
                // of that paid by the margin, the rest by this trail. Both
                // ends of the bar are then even by construction, whatever
                // rounding the theme carries. The old plain-`iconInset` trail
                // (the 2026-10-06 fix for "no spacing to the right") booked
                // only `2 * iconInset` in total, which read visibly tighter
                // than the left end. The middle is untouched: neighbour gaps
                // stay exactly `2 * iconInset`, and pill and bolt remain one
                // mark.
                // ...and it is spent only while the battery really is the bar's
                // right end. With the fullscreen PIN out, it is not: the pin
                // sits to its right carrying its own `iconInset` margins, so
                // keeping the end-air here added a second, invisible neighbour
                // -- measured, the bolt-to-pin gap was 36px against the 26px
                // every other pair in the strip runs at (the report: "too much
                // spacing between the 2 icons", the two being the battery's
                // charging bolt and the pin). With the trail at 0 the same
                // margins that space the wifi from the sound space these two,
                // and the gap comes out at 27.
                boltTrail: fsPinButton.visible
                    ? 0
                    : Appearance.rounding.screenRounding + 8 - root.iconInset
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                Layout.leftMargin: root.iconInset
                Layout.rightMargin: root.iconInset
                // The battery's click card stays the fast path; resting the
                // pointer on the indicator pulls the liquid pocket out of the
                // bar instead (see hoverPocket: a dwell, not a brush-by).
                onContainsMouseChanged: root.hoverPocket(containsMouse, "battery", root.centerXFor(batteryIndicator),
                    // The right island's own left edge: barRightSideMouseArea
                    // is that island, so its bar-space left bound is the floor
                    // the drop may not cross.
                    root.rightIslandLeft,
                    root.rightIslandRight)
            }

            // User-chosen quick toggles, pinned from the sidebar's edit mode
            // (Config.options.bar.topBarWidgets). Each entry is a live model
            // instance; click opens the right sidebar (the way every bar
            // control opens its panel), right click runs the toggle's main
            // action.
            //
            // No Wi-Fi and no Bluetooth entry: the connectivity pill right here
            // already shows both, and its own switches
            // (`bar.indicators.network` / `.bluetooth`) add or remove them -- a
            // pinned copy would be the same control twice on one bar. The pill,
            // the sound icon and the battery are removable from the sidebar's
            // edit mode too; these entries are the toggles that have no bar
            // widget of their own yet.
            Repeater {
                // NOT a layout participant -- the whole point of this line.
                //
                // `Repeater` derives from `Item`, and an `Item` that is a child
                // of a `RowLayout` is a layout item whether it wants to be or
                // not. A layout charges `spacing` on BOTH sides of every VISIBLE
                // child, so this one was silently adding 2 x 12 = 24px of air
                // to the strip: the delegates it makes are parented to the
                // Repeater's PARENT (this row) rather than to the Repeater, so
                // they lay out perfectly well without it, and with no widget
                // pinned it had nothing to show at all.
                //
                // Measured on the live bar with no top-bar widget pinned: the
                // gap between the connectivity pill and everything to its left
                // was 24 while every other gap was 12. The layout skips
                // invisible children, and hiding the Repeater hides nothing
                // real -- the delegates are its siblings, each with its own
                // `visible` binding, so a pinned widget still appears and
                // still takes exactly one `spacing`.
                visible: false
                model: [
                    // "table_lamp", never a moon: "nightlight" may be named for a
                    // lamp but its glyph is a crescent, so beside Dark mode below
                    // ("dark_mode") the bar showed the same icon twice.
                    { key: "nightLight", icon: "table_lamp", model: nightLightModel },
                    { key: "darkMode", icon: "dark_mode", model: darkModeModel },
                    { key: "mic", icon: "mic", model: micModel },
                    { key: "idleInhibitor", icon: "local_cafe", model: idleInhibitorModel },
                    { key: "gameMode", icon: "sports_esports", model: gameModeModel },
                    { key: "performance", icon: "speed", model: performanceModel },
                    { key: "powerProfiles", icon: "battery_saver", model: powerProfilesModel },
                    { key: "screenSnip", icon: "screenshot_region", model: screenSnipModel },
                    { key: "colorPicker", icon: "colorize", model: colorPickerModel },
                ]

                HoverIconButton {
                    id: topBarWidgetButton
                    required property var modelData
                    visible: Config.options.bar.topBarWidgets[modelData.key] === true
                    Layout.alignment: Qt.AlignVCenter
                    // The same inset as every other icon, on both sides. See
                    // `iconInset`.
                    Layout.leftMargin: root.iconInset
                    Layout.rightMargin: root.iconInset
                    hovered: topBarWidgetHover.hovered
                    // The LIVE icon, not the one this row was written with.
                    // The power profile's glyph is `energy` / `airwave` /
                    // `local_fire_department` depending on the profile, and it
                    // was pinned to "battery_saver" for ever -- the icon could
                    // never show which mode the machine was actually in.
                    tooltipText: `${modelData.model?.name ?? ""} · ${modelData.model?.statusText ?? ""} · ${Translation.tr("tap: toggle")} · ${Translation.tr("two-finger tap: sidebar")}`
                    symbol.text: modelData.model?.icon || modelData.icon
                    // The same drawn size as its neighbours, whatever glyph the
                    // toggle happens to use. See `pinGlyphEm`.
                    symbol.iconSize: Math.round(Appearance.font.pixelSize.larger
                        * (root.pinGlyphEm[modelData.model?.icon || modelData.icon] ?? 1))
                    // Which pin this is, for the two-finger tap below.
                    readonly property bool isPowerProfile: modelData.key === "powerProfiles"
                    // The glyph carries the colour, and there is no disc behind
                    // it: the strip is a run of outline icons on the bar's own
                    // surface, so a filled circle on one of them reads as a
                    // different kind of control.
                    //
                    // `tint` exists only on the power profile (green eco,
                    // fire-orange performance, transparent for balanced -- which
                    // has no colour to say and whose accent is a wallpaper grey).
                    // Everything else falls through to the shared logic inside
                    // `HoverIconButton`.
                    symbolColor: modelData.model?.tint ?? "transparent"
                    activateAction: () => {
                        // A toggle with no action of its own still has to do
                        // something: fall back to the sidebar, which is where
                        // its controls are.
                        if (modelData.model?.mainAction)
                            modelData.model.mainAction();
                        else
                            GlobalStates.sidebarRightOpen = true;
                    }
                    // Two fingers on the POWER pin opens the mode menu -- the
                    // three modes, with the one you are on marked, and a pick
                    // raises the same notice the popup's buttons do. Every other
                    // pin keeps the sidebar: that is where its full controls
                    // live, and a pin is a shortcut to a toggle, not a page.
                    altAction: () => {
                        if (topBarWidgetButton.isPowerProfile)
                            root.pinPopupOpen = !root.pinPopupOpen;
                        else
                            GlobalStates.sidebarRightOpen = true;
                    }
                    HoverHandler {
                        id: topBarWidgetHover
                        cursorShape: Qt.PointingHandCursor
                        // The bar's own hover line, the same one Wi-Fi and
                        // Bluetooth answer with -- for WHICHEVER pin this is,
                        // which is why the text comes off the model at hover
                        // time instead of being written per toggle.
                        onHoveredChanged: {
                            if (hovered) {
                                // The power pin answers with the MODE, because
                                // that is what a tap on it changes -- "Power
                                // mode · Eco", not the internal profile name.
                                // Held as the model so the line keeps up while
                                // the pointer rests on the icon.
                                root.hoveredPinModel = topBarWidgetButton.modelData.model ?? null;
                                root.hoveredPinIsPower = topBarWidgetButton.isPowerProfile;
                            }
                            root.hoverPocket(hovered, "pin",
                                root.centerXFor(topBarWidgetButton),
                                root.rightIslandLeft, root.rightIslandRight);
                        }
                    }
                }
            }

            // Sound, in the order professional OSs use: battery at the very
            // edge, then sound, then the connectivity pill. Left click opens
            // the right sidebar -- where the volume slider lives -- like the
            // Windows quick-settings tap; right click toggles mute, the fast
            // path; scrolling on the icon steps the volume, the same
            // "scroll to change volume" the bar itself used to do, now scoped
            // to the icon it belongs to.
            HoverIconButton {
                id: soundButton
                // `bar.indicators.sound` -- removable like the rest (see the
                // battery above for why the test is against false).
                visible: Audio.sink != null && Config.options.bar.indicators.sound !== false
                Layout.alignment: Qt.AlignVCenter
                // The same inset as every other icon, on both sides. See
                // `iconInset`.
                Layout.leftMargin: root.iconInset
                Layout.rightMargin: root.iconInset
                hovered: soundHover.hovered
                // The guard needs the bar's cursor position, which only the
                // bar itself can see.
                cursorX: root.cursorX
                cursorInBar: root.cursorInBar
                readonly property bool muted: Audio.sink?.audio?.muted ?? false
                readonly property int volumePct: Math.round(Audio.currentVolume() * 100)
                // The hover line in the bar is the level and the output device
                // (see soundPocket); the tooltip would only repeat the level, so
                // it carries what the bar cannot: what a click and a right click
                // do, and that the wheel still moves the volume.
                tooltipText: `${Translation.tr("Click: mute or unmute")} · ${Translation.tr("Two-finger tap: sound devices")} · ${Translation.tr("Scroll: change volume")}`
                symbol.text: muted ? "volume_off" : "volume_up"
                // ── Which gesture does which (2026-10-20, final) ──────────
                //
                // On this desktop a 1-finger tap IS a left click and a
                // 2-finger tap IS a right click (`tap_button_map = "1,2,3"`
                // with `clickfinger_behavior`, custom/general.lua), so the two
                // gestures this icon answers are simply the two buttons it can
                // see:
                //
                //   one finger    mute, and unmute (toggleSoundMute);
                //   two fingers   the SUPER + G overlay (toggleOverlayFromTap).
                //
                // A two-finger tap arrives TWICE -- as the right click below and
                // as the tracker's `onTapTriggered(2)` -- so exactly one of them
                // is allowed to act. See the note under `altAction`.
                activateAction: () => {
                    console.log(`[tap] 1-finger tap on the sound icon: ${root.toggleSoundMute()}`);
                }
                // The right click is the ONLY thing that acts on a two-finger
                // tap: a toggle has to be driven exactly once per gesture.
                //
                // Both paths used to call it and a time-based latch tried to
                // collapse them. Measured in the log, that cannot work: the
                // compositor's click lands immediately, while the tracker's
                // report only arrives after its python process has spawned
                // `qs ipc call` -- hundreds of milliseconds later, and variable.
                // A latch wide enough to cover that would also swallow a
                // deliberate second tap. So the split is not by time but by
                // role: this click toggles, and `onTapTriggered` below only
                // reports. Nothing to race.
                // Where the SoundPanel lives. Same flag-and-Connections
                // arrangement as the Wi-Fi, Bluetooth and VPN icons: the tap
                // raises this flag, the panel follows it, and the panel's own
                // close (Escape, the backdrop, its close button) clears it
                // again -- otherwise the next tap would "open" a card that is
                // already shut and read as a press that did nothing.
                //
                // NEW DESTINATION 2026-11-01 (user request): a two-finger tap
                // used to flip the SUPER + G overlay. The overlay already has
                // its key; the output and microphone lists had no door at all
                // in the bar, which is what this gesture is worth.
                property bool popupOpen: false
                altAction: () => {
                    soundButton.popupOpen = !soundButton.popupOpen;
                    console.log(`[tap] 2-finger tap on the sound icon: sound panel ${soundButton.popupOpen ? "open" : "closed"}`);
                }
                WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: event => {
                        if (!Audio.sink?.audio) return;
                        if (root.padScrollBlocked) { event.accepted = true; return; }
                        const step = event.angleDelta.y > 0 ? 0.05 : -0.05;
                        Audio.setSinkVolume(Audio.currentVolume() + step);
                        if (Audio.sink.audio.muted && step > 0) Audio.sink.audio.muted = false;
                        event.accepted = true;
                    }
                }
                HoverHandler {
                    id: soundHover
                    cursorShape: Qt.PointingHandCursor
                    // Same island floor as the battery pocket: a wide drop
                    // (a long track title) slides LEFT when clamped, and
                    // without the floor it crossed the island's left edge
                    // onto the middle island -- "positions show off from
                    // the bar's length".
                    // The FRESH handler value, not soundButton.reallyHovered:
                    // that derived property's binding to this handler can lag
                    // its own change notification, and reading it here handed
                    // hoverPocket an inverted truth -- the pocket armed on
                    // LEAVE and disarmed on ENTER (the user's exact report).
                    // The stuck-hover guard is applied live instead: fresh
                    // hover AND a stationary-cursor/layout-shift check, both
                    // evaluated at this instant rather than inherited stale.
                    onHoveredChanged: root.hoverPocket(soundHover.hovered && !soundButton.movedUnderCursor, "sound",
                        root.centerXFor(soundButton),
                        root.rightIslandLeft, root.rightIslandRight)
                }
            }

            RippleButton { // Right sidebar button
                id: rightSidebarButton
                // No swell, no hover fill. Both of those are set further down,
                // next to the pill this button contains: `colBackground` and
                // `colBackgroundHover` are single properties on ONE object
                // here, and declaring them up here as well is a hard
                // "Property value set multiple times" that takes the entire
                // bar down with it.

                // The pill is the Wi-Fi and Bluetooth indications plus the live
                // chips (muted sink, muted mic, unread notifications). Both
                // indications can be removed from the sidebar's edit mode, and
                // then this must not linger as an empty pill -- but it must not
                // take the chips down with it either, so it shows exactly while
                // it has something in it. The bar's right section opens the
                // sidebar on click no matter what, so nothing becomes
                // unreachable when the pill is gone.
                readonly property bool hasIndicators:
                    (Config.options.bar.indicators.network !== false)
                    || (Config.options.bar.indicators.bluetooth !== false && BluetoothStatus.available)
                    || (Tailscale.installed && Config.options.bar.indicators.vpn !== false)
                    || (Audio.source?.audio?.muted ?? false)
                    || Notifications.silent || Notifications.unread > 0
                visible: hasIndicators

                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                Layout.fillWidth: false
                // The same inset as every other icon, on both sides -- the pill
                // is one icon in the strip like the rest, so it sits exactly as
                // far from the tray on one side as from the sound icon on the
                // other. See `iconInset`.
                Layout.leftMargin: root.iconInset - root.pillPad
                Layout.rightMargin: root.iconInset - root.pillPad

                // The pill's box: the glyph row plus its own air on both sides.
                // See `pillPad` for why the margins above give that air back.
                implicitWidth: indicatorsRowLayout.implicitWidth + 2 * root.pillPad
                implicitHeight: indicatorsRowLayout.implicitHeight + 5 * 2

                // NO ripple, and this is the fix for the oval.
                //
                // `colBackground` and `colBackgroundHover` were already
                // transparent, which is why the resting and hover states were
                // clean -- but the RIPPLE was left on, and a ripple is a filled
                // radial gradient masked to `buttonRadius`. With the radius
                // still at `rounding.full` that mask is a capsule, so pressing
                // anywhere on the strip painted a solid pill-shaped blob that
                // outlived the press (the fade runs 2x `rippleDuration`, 2.4s
                // by default) and read as a stray oval behind the icons.
                //
                // The two transparent colours were never going to cover it: they
                // silence the button's own fill, and the ripple is a separate
                // child that ignores them. Switching the effect off is the fix
                // at its source; zeroing the colour as well is deliberate belt
                // and braces, so a later edit that re-enables the ripple cannot
                // bring the oval back.
                //
                // This is now the ONLY `colRipple` on this button. It used to
                // be set a second time further down with the live colour, and
                // QML treats a repeated property assignment as a hard load
                // error ("Property value set multiple times") that takes the
                // whole bar -- and with it the shell -- down. The duplicate is
                // gone, not merged, so there is one site to reason about.
                rippleEnabled: false
                colRipple: ColorUtils.transparentize(Appearance.colors.colLayer1Active, 1)
                buttonRadius: Appearance.rounding.full
                // NO fill here at all now -- pointer or state. The old fill
                // tracked hovering anywhere over the bar's right section, so
                // hovering the extended info lit a box behind the icons: the
                // stray "hover box under it". The pill is now silent unless
                // RippleButton's own default hover cue fires on the pill itself.
                colBackground: ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)
                // Transparent on hover too. RippleButton's default hover fill is
                // a full capsule of `colLayer1Hover` -- leaving it set here is the
                // "oval for a background" on hover: a pill-sized plate behind
                // icons that are themselves flat on the island. The hover cue is
                // the glyphs (accent + fill), as everywhere else on the bar.
                colBackgroundHover: ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)
                // No toggled background. This row is the wifi and bluetooth
                // indications, and it used to paint a secondary-container pill behind
                // them for as long as the sidebar was open -- which read as a button
                // being held down. The text colour no longer tracks that state either.
                toggled: false
                property color colText: Appearance.colors.colOnLayer0

                Behavior on colText {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }

                // Wifi and bluetooth here are indications, not a button: pressing
                // them must not open the sidebar. The highlight still tracks the
                // sidebar's state, and the sidebar itself opens from the screen
                // edge or with SUPER+N.

                RowLayout {
                    id: indicatorsRowLayout
                    anchors.centerIn: parent
                    // The strip's own number, not a second one. A row inside a
                    // pill that is itself in a strip must not invent its own
                    // gap, or the two meet and add: that is the 24px that made
                    // the bluetooth-to-volume gap double its neighbours.
                    //
                    // SPACING-BASED, not margin-based: `spacing` puts the same
                    // gap between every pair of VISIBLE children, so any
                    // combination of visible chips comes out even by
                    // construction. A margin on the first visible item (whichever
                    // chip or icon that happens to be) would stack with the pill's
                    // edge instead, which is the "first icon has a big spacing
                    // to the left" report.
                    //
                    // TWICE the inset, which is what a gap between two strip
                    // icons actually measures: each one carries `iconInset` on
                    // both sides, so a neighbour gap is 18 -- this row can only
                    // put 9 between its own children, so it has to ask for 18.
                    //
                    // This used to be the bare inset on the theory that the
                    // pill's glyphs were one control and should read tighter
                    // than the strip around them. That was true when the pill
                    // was two indications; it holds three separate buttons now
                    // (network, bluetooth, VPN) plus the mic and bell chips, so
                    // the tighter number stopped grouping anything and started
                    // looking like a mistake next to the icons beside it.
                    //
                    // Measured on the live bar before this, right run, glyph
                    // centre to glyph centre, logical px: 47, 34.3, 36, 44, 44,
                    // 44.7 -- the two short ones are the wifi-to-bluetooth and
                    // bluetooth-to-VPN gaps, i.e. this row. With the pill's
                    // inner gap at 2 * iconInset every one of those reads 44,
                    // because 26 (the icon box) + 18 (the gap) is the whole
                    // arithmetic of the run.
                    spacing: root.iconInset * 2
                    // NO muted-sink chip here: the sound button to the left
                    // already swaps its own glyph to volume_off when muted,
                    // so this chip was a SECOND crossed speaker appearing next
                    // to the first on every mute. The sink's mute state has
                    // exactly one drawing (the button); the mic keeps its chip
                    // because the bar has no mic button to carry it.
                    Revealer {
                        // Removable via the picker's "Muted mic chip" switch
                        // (bar.indicators.mic). The sink twin follows `sound`.
                        reveal: (Config.options.bar.indicators.mic !== false)
                            && (Audio.source?.audio?.muted ?? false)
                        Layout.fillHeight: true
                        MaterialSymbol {
                            text: "mic_off"
                            iconSize: Appearance.font.pixelSize.larger
                            color: rightSidebarButton.colText
                        }
                    }
                    Revealer {
                        // Removable via the picker's "Notification bell chip"
                        // switch (bar.indicators.notifications.show). The
                        // unread ping INSIDE the bell follows the bell.
                        reveal: (Config.options.bar.indicators.notifications?.show !== false)
                            && (Notifications.silent || Notifications.unread > 0)
                        Layout.fillHeight: true
                        implicitHeight: reveal ? notificationUnreadCount.implicitHeight : 0
                        implicitWidth: reveal ? notificationUnreadCount.implicitWidth : 0
                        NotificationUnreadCount {
                            id: notificationUnreadCount
                        }
                        // The bell's own click target.
                        //
                        // It is a TapHandler and not a MouseArea for the reason
                        // the wifi and bluetooth icons give: a MouseArea is a
                        // layout item here and would fight the RowLayout over
                        // the strip's sizing. A handler is not in the layout at
                        // all, so it can only ever take the press.
                        //
                        // OPEN, never toggle, for the same reason the sound icon
                        // does not toggle (see `soundButton`): the sidebar is
                        // also reachable from the screen edge and the keyboard,
                        // and a control that closes the panel you just asked for
                        // by pressing it twice is a trap. Asking again is a
                        // no-op; the highlight below still re-fires.
                        TapHandler {
                            acceptedButtons: Qt.LeftButton
                            onTapped: {
                                GlobalStates.sidebarRightOpen = true;
                                Notifications.requestHighlight();
                            }
                        }
                        // Hovering the chip previews the LAST notification in
                        // the liquid droplet ("notifications" pocket), clamped
                        // inside the right island like the battery's. Click
                        // still falls through to the pill button, which opens
                        // the sidebar's notification list.
                        HoverHandler {
                            id: notificationChipHover
                            cursorShape: Qt.PointingHandCursor
                            onHoveredChanged: root.hoverPocket(hovered, "notifications",
                                root.centerXFor(notificationUnreadCount),
                                // Same floor as the battery pocket: the drop
                                // may not cross the right island's left edge.
                                root.rightIslandLeft,
                                root.rightIslandRight)
                        }
                    }
                    // Wifi. Pressing it opens the Wi-Fi menu; hover makes it
                    // look pressable. Handlers rather than a nested MouseArea: they
                    // are not layout items, so they cannot fight the RowLayout over
                    // sizing, and they grab the press before the pill-button behind
                    // them can take it and open the sidebar instead.
                    HoverIconButton {
                        id: networkButton
                        visible: Config.options.bar.indicators.network !== false
                        Layout.alignment: Qt.AlignVCenter
                        // No margin: the row's own `spacing` puts the gap, and
                        // the pill's pad is the single inset from the pill's
                        // edge. Margins here were what doubled the air left of
                        // the first icon.
                        hovered: networkHover.hovered
                        // The first line answers "what am I connected to", and
                        // the two links want DIFFERENT answers (requested
                        // 2026-09-29).
                        //
                        // Wired: the IPv4 address. A wired connection's NAME is
                        // no use at all -- every one of them is called "Wired
                        // connection 1" -- so quoting it told the reader
                        // nothing they could not already guess, and the one
                        // fact about a wired link that is not obvious from
                        // the icon is which address the machine is holding.
                        //
                        // Wi-Fi: the SSID, as before. The address is the wrong
                        // way round here: the network you are joined to is the
                        // thing you hover an icon to find out, and the address
                        // is four numbers you already know.
                        //
                        // Either way the ADDRESS is the fallback when the
                        // name is missing, not the other way round: a wired
                        // link with no address yet (DHCP still running) must
                        // not fall back to "Wired connection 1".
                        tooltipText: `${root.networkIdentity}\n${Translation.tr("Click: turn Wi-Fi on or off")} · ${Translation.tr("Two-finger tap: Wi-Fi menu")}`
                        symbol.text: Network.materialSymbol
                        // The panel, not the settings app (requested again
                        // 2026-10-12). A click gives you the adapter switch, the
                        // networks in range and the password field -- the three
                        // things a Wi-Fi icon is pressed for -- as a card over
                        // the bar, the way the VPN icon already worked. Settings
                        // keeps the pairing management, the saved-profile edits
                        // and the 802.1X cases; the header's tune button is that
                        // door, one click away.
                        property bool popupOpen: false
                        // SWAPPED 2026-10-20: one finger is the fastest path
                        // now -- toggle the radio without opening anything --
                        // and two fingers opens the card.
                        activateAction: () => Network.toggleWifi()
                        altAction: () => networkButton.popupOpen = !networkButton.popupOpen
                        HoverHandler {
                            id: networkHover
                            cursorShape: Qt.PointingHandCursor
                            onHoveredChanged: root.hoverPocket(hovered, "network", root.centerXFor(networkButton),
                                root.rightIslandLeft, root.rightIslandRight)
                        }
                    }

                    // Bluetooth, same thing, its own settings panel.
                    HoverIconButton {
                        id: bluetoothButton
                        visible: BluetoothStatus.available
                            && Config.options.bar.indicators.bluetooth !== false
                        Layout.alignment: Qt.AlignVCenter
                        hovered: bluetoothHover.hovered
                        tooltipText: {
                            const device = BluetoothStatus.firstActiveDevice?.name ?? Translation.tr("No device connected");
                            return `${device} · ${BluetoothStatus.enabled ? Translation.tr("Enabled") : Translation.tr("Disabled")}\n${Translation.tr("Click: turn Bluetooth on or off")} · ${Translation.tr("Two-finger tap: Bluetooth menu")}`;
                        }
                        symbol.text: BluetoothStatus.connected ? "bluetooth_connected" : BluetoothStatus.enabled ? "bluetooth" : "bluetooth_disabled"
                        // The panel, on the same reasoning as the Wi-Fi icon
                        // above.
                        property bool popupOpen: false
                        // SWAPPED 2026-10-20, same as Wi-Fi: one finger flips
                        // the adapter, two fingers opens the card.
                        activateAction: () => {
                            if (!Bluetooth.defaultAdapter) return;
                            Bluetooth.defaultAdapter.enabled = !BluetoothStatus.enabled;
                            Bluetooth.defaultAdapter.discovering = BluetoothStatus.enabled ? false : true;
                        }
                        altAction: () => bluetoothButton.popupOpen = !bluetoothButton.popupOpen
                        HoverHandler {
                            id: bluetoothHover
                            cursorShape: Qt.PointingHandCursor
                            onHoveredChanged: root.hoverPocket(hovered, "bluetooth", root.centerXFor(bluetoothButton),
                                root.rightIslandLeft,
                                root.rightIslandRight)
                        }
                    }

                    // VPN. The one indicator on the bar that says whether the
                    // tailnet is up -- and the one that can bring it up
                    // without a detour: press flips the tailnet where it
                    // stands, right click opens the connection list.
                    //
                    // Shown only when there is something to switch. Wi-Fi and
                    // Bluetooth are radios that always exist; the VPN is a
                    // piece of software that may simply not be installed, and
                    // a permanent icon that can never light up is furniture.
                    HoverIconButton {
                        id: vpnButton
                        // Removable like Wi-Fi and Bluetooth, from the same
                        // editor: `bar.indicators.vpn`. Both halves are real
                        // conditions -- the CLI has to be installed for there to
                        // be anything to say, and the switch has to be on for
                        // the user to want it said.
                        visible: Tailscale.installed
                            && Config.options.bar.indicators.vpn !== false
                        Layout.alignment: Qt.AlignVCenter
                        // No pocket, unlike the two icons before it. Their
                        // droplets carry an SSID or a device name -- a fact
                        // you hover to find out. This one's whole state is
                        // already legible from the glyph, which fills and
                        // takes the accent when the tunnel is up.
                        hovered: vpnHover.hovered
                        tooltipText: `${Tailscale.connected ? Translation.tr("VPN on") : Translation.tr("VPN off")} · Home-VPN\n${Translation.tr("Click: turn the VPN on or off")} · ${Translation.tr("Two-finger tap: connections")}`
                        symbol.text: Tailscale.connected ? "vpn_lock" : "vpn_key_off"
                        // The panel is driven by this flag, not by
                        // HoverIconButton's own lazy `panelComponent` loader:
                        // nothing else in this shell uses that loader, while
                        // the flag-and-Connections arrangement below is the one
                        // the clock's calendar popup already runs on.
                        property bool popupOpen: false
                        // SWAPPED 2026-10-20: one finger flips the tailnet, two
                        // fingers opens the connection list.
                        activateAction: () => Tailscale.toggle()
                        altAction: () => vpnButton.popupOpen = !vpnButton.popupOpen
                        HoverHandler {
                            id: vpnHover
                            cursorShape: Qt.PointingHandCursor
                            // The one indicator that had no bar line: the glyph
                            // says up or down, the line says which.
                            onHoveredChanged: root.hoverPocket(vpnHover.hovered, "vpn",
                                root.centerXFor(vpnButton),
                                root.rightIslandLeft, root.rightIslandRight)
                        }
                    }
                }

            }

            // NOTE: this close belongs to `rightSidebarButton` (the pill) and the
            // one above it to its inner `indicatorsRowLayout`. They were missing
            // here -- the pill was left open, so SysTray and the whole run after
            // it parsed as the pill's own children and the file never balanced,
            // which took the entire bar down with it. The strip's icons are all
            // siblings of the pill, at this indent.

            // The power-mode menu, on the same flag-and-Connections
            // arrangement as the connectivity menus below. `anchorItem` is the
            // sound icon: the pin that opens it is a Repeater delegate, so it
            // cannot be named from out here, and the panel uses the anchor only
            // to pick the screen -- which is this bar's screen either way.
            PowerModePanel {
                id: powerModePanel
                anchorItem: soundButton
                Connections {
                    target: root
                    function onPinPopupOpenChanged() {
                        powerModePanel.open = root.pinPopupOpen;
                    }
                }
                // The panel closes itself (Escape, backdrop, its close button),
                // so the flag follows it back -- otherwise the next two-finger
                // tap would "open" a panel that is already shut and read as a
                // press that did nothing.
                Connections {
                    target: powerModePanel
                    function onOpenChanged() {
                        if (!powerModePanel.open && root.pinPopupOpen)
                            root.pinPopupOpen = false;
                    }
                }
            }

            // The VPN popup. A sibling of the pill rather than a child of it,
            // and non-visual (a Scope holding a layer-shell window), so it
            // takes no room in the strip's row either way.
            VpnPanel {
                id: vpnPanel
                Connections {
                    target: vpnButton
                    function onPopupOpenChanged() {
                        vpnPanel.anchorItem = vpnButton;
                        vpnPanel.open = vpnButton.popupOpen;
                    }
                }
                // The panel closes itself too -- Escape, the backdrop, its own
                // close button. Without this the flag would stay true, and the
                // next press would "open" a panel that is already shut instead
                // of opening it, which reads as the first click being ignored.
                Connections {
                    target: vpnPanel
                    function onOpenChanged() {
                        if (!vpnPanel.open && vpnButton.popupOpen)
                            vpnButton.popupOpen = false;
                    }
                }
            }

            // The other two connectivity menus, on the same flag-and-
            // Connections arrangement as the VPN panel above it: all three
            // open from their icon, close on Escape, on the backdrop or on
            // their own close button, and reset their icon's flag when they
            // do -- without that, the next press would "open" a panel that is
            // already shut and read as the first click being ignored.
            WifiPanel {
                id: wifiPanel
                Connections {
                    target: networkButton
                    function onPopupOpenChanged() {
                        wifiPanel.anchorItem = networkButton;
                        wifiPanel.open = networkButton.popupOpen;
                    }
                }
                Connections {
                    target: wifiPanel
                    function onOpenChanged() {
                        if (!wifiPanel.open && networkButton.popupOpen)
                            networkButton.popupOpen = false;
                    }
                }
            }

            BluetoothPanel {
                id: bluetoothPanel
                Connections {
                    target: bluetoothButton
                    function onPopupOpenChanged() {
                        bluetoothPanel.anchorItem = bluetoothButton;
                        bluetoothPanel.open = bluetoothButton.popupOpen;
                    }
                }
                Connections {
                    target: bluetoothPanel
                    function onOpenChanged() {
                        if (!bluetoothPanel.open && bluetoothButton.popupOpen)
                            bluetoothButton.popupOpen = false;
                    }
                }
            }

            // The sound popup: what a two-finger tap on the sound icon opens.
            // Same flag-and-Connections arrangement as the three above, and a
            // sibling of them for the same reason -- a panel is a Scope holding
            // a layer-shell window, so it takes no room in the strip's row.
            SoundPanel {
                id: soundPanel
                Connections {
                    target: soundButton
                    function onPopupOpenChanged() {
                        soundPanel.anchorItem = soundButton;
                        soundPanel.open = soundButton.popupOpen;
                    }
                }
                Connections {
                    target: soundPanel
                    function onOpenChanged() {
                        if (!soundPanel.open && soundButton.popupOpen)
                            soundButton.popupOpen = false;
                    }
                }
            }

            SysTray {
                id: barSysTray
                // NOT gated on whether anything is in the tray. The chevron
                // is the tray's permanent entry point -- the one control
                // that means "the tray" -- and gating it on the item count
                // (as this did, and as the old SysTray did internally) made
                // it appear and vanish with the apps, so the bar re-laid-out
                // every time one started or quit and there was nothing on
                // screen to aim at before that happened.
                //
                // It is a real, fixed-width cell now rather than a
                // zero-width one, so it costs its own `spacing` and no dead
                // air: 26px, the same as the sound button beside it.
                visible: root.useShortenedForm === 0
                Layout.fillWidth: false
                Layout.fillHeight: true
                // The same inset as every other icon, on both sides. See
                // `iconInset`.
                Layout.leftMargin: root.iconInset
                Layout.rightMargin: root.iconInset
                invertSide: Config?.options.bar.bottom
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
            }

            // Weather
            Loader {
                Layout.leftMargin: 4
                active: Config.options.bar.weather.enable

                sourceComponent: BarGroup {
                    backgroundVisible: false
                    WeatherBar {}        }

    }
}

    }

    // ═══ Two-finger swipe on the bar: brightness left, volume right ═════
    //
    // The two scroll MouseAreas above already divide the bar the way this
    // gesture wants -- `barLeftSideMouseArea` owns the stretch up to the
    // middle section and says "scroll changes brightness",
    // `barRightSideMouseArea` owns everything past it. The wheel and the
    // fingers are answering the same question about the same place, so the
    // zones are read off those two anchors rather than re-invented as
    // fractions of the screen: whatever the bar's layout does to its middle
    // section, the swipe follows it.
    //
    // Why the tracker and not Hyprland's own gesture binding: a compositor
    // gesture fires once, when the swipe is already over, and carries no
    // distance -- only a direction. One direction means one fixed step, and
    // it cannot say WHERE the fingers were, which is the entire difference
    // between the left island and the right one. The touchpad is an absolute
    // device, so reading it directly gives both the position and the travel.

    // Where the bar splits for the gesture. The middle section is the honest
    // landmark -- the two scroll MouseAreas divide the bar around it, so the
    // wheel and the fingers answer the same question about the same place --
    // but its RIGHT edge is a bad place to split, and the reason is the
    // touchpad. Measured on this bar: the island runs x 620..980 of 1600, so
    // splitting at its right edge asks the fingers to be past 61% of the
    // pad's WIDTH -- and a hand rests in the middle of a touchpad, which maps
    // to the middle of the screen, which is inside the dead band between the
    // two edges. That is why the right side read as "does nothing": the zone
    // was real, just somewhere a thumb does not go. The island's CENTRE
    // always leaves two halves of the bar and the split falls exactly where
    // the hand already is.

    // What one full sweep of the pad is worth. The tracker reports a whole
    // sweep as 1.0, so these are fractions of each control's whole range.
    //
    // These were 1.0 and 0.7, on the reasoning that a gain of 1.0 is "the
    // height of the pad = the whole range" and a comfortable wrist sweep
    // should therefore move the control a lot. That reasoning is wrong about
    // what the fingers actually deliver. Driving the gesture synthetically
    // through the IPC hook and watching the travel the tracker reports for a
    // realistic swipe: it accumulates to roughly 0.02-0.16 of a pad, nowhere
    // near the 0.5-1.0 the old numbers assumed.
    //
    // At gain 1.0 that made a whole swipe worth 2-16% of the range, and the
    // two halves then failed in opposite ways from the same cause. A 2% step
    // of brightness is just about visible, so the left read as "it only moves
    // 2 at a time". 2% of volume is inaudible, so the right half read as
    // "it does not work at all" -- it was moving, just by an amount nobody
    // can perceive. Nothing was broken on the right; it was under-scaled
    // past the threshold of noticing.
    //
    // 3.0 and 2.2 were a second wrong guess, made while the gesture was still
    // dead and I was calibrating against synthetic numbers. The recording of
    // a REAL swipe settles it: the tracker's own totals for actual swipes run
    // 0.22-0.57 of a pad, not the 0.02-0.16 assumed here. At 3.0 a single
    // ordinary swipe would have been 120% of the range and pinned the control
    // at its limit.
    //
    // 1.5 and 1.1 put a real swipe where a scroll lives, but the first
    // hands-on test (2026-09-30) called brightness "too sensible" -- the
    // control moved, just not enough to feel connected to the fingers. 2.2
    // keeps a comfortable ~0.4 swipe at ~88% of the range: the gesture spans
    // the rail without pinning, and a short flick still lands somewhere you
    // can fine-tune. Volume stays at 1.1, because there is an upper end worth
    // respecting (and the rail users know goes to 200%).
    //
    // What each gain scales is a FRACTION of that control's own range, so the
    // ceiling is applied per zone at the target, not here: brightness ends at
    // the panel's maximum (1.0 of `max_brightness`) and volume at
    // `Audio.hardMaxValue` (200%, the rail's end and PipeWire's).
    readonly property real swipeGainBrightness: 2.2
    readonly property real swipeGainVolume: 1.1

    // ── The pad also speaks WHEEL ────────────────────────────────────────
    // `emulate_discrete_scroll = 0` in hypr/custom/general.lua passes the
    // touchpad's motion through as a CONTINUOUS stream of axis events, so a
    // two-finger movement over the bar arrives at the scroll handlers below
    // as dozens of wheel events per gesture -- each one a 5% step. The
    // diagnostic proved it: one swipe ended at 100% brightness and the next
    // anchored at 1%, with no swipe of ours in between.
    //
    // A mouse wheel never touches TouchpadSwipe, so gesture liveness is an
    // exact test for "this wheel event came from fingers". The timer releases
    // the block a beat after the fingers lift, because the axis stream keeps
    // arriving slightly after the last touch frame.
    property bool padScrollBlocked: false
    Timer {
        id: padScrollRelease
        interval: 400
        onTriggered: root.padScrollBlocked = false
    }
    function blockPadScroll() {
        root.padScrollBlocked = true;
        padScrollRelease.restart();
    }

    // How close to the top of the SCREEN the fingers have to be. The bar is
    // ~35 logical px of 1000, which on a touchpad is a target you cannot hit
    // on purpose -- the pad's top edge is a hard mechanical stop and the
    // first centimetre of travel is coarse. 9% is a band you can land in
    // deliberately while still being nowhere near the bar if you swipe from
    // the middle of the desk.
    //
    // DEAD, and deliberately kept only as a record of what it was. It
    // compared the touchpad's own y against a screen fraction, which nothing
    // can satisfy; see the gate in `handleBarSwipe`. The equivalent question
    // is now asked of the cursor, which is a real screen position.
    readonly property real swipeBand: 0.09

    // ── Where the CURSOR is on the bar ───────────────────────────────────
    //
    // Diagnostic only. The gate's decision deliberately does NOT come from
    // here -- see `pointerX` below for why asking the tracker "is the pointer
    // over the bar right now" was the single change that kept every swipe
    // from ever working.
    //
    // What happened before, for the record: this used to fork `hyprctl
    // cursorpos -j` once per gesture as the ONLY cursor source, on the belief
    // that a HoverHandler could not report a position on this build. `hyprctl`
    // was answering "Couldn't connect" at the time, the probe fed that error
    // text to `JSON.parse`, the `catch` declined the gesture, and every
    // two-finger swipe did nothing. The tracker was brought in to replace it --
    // and then the gate began demanding the pointer be INSIDE the bar, which
    // is a question a touchpad swipe cannot answer, so the gesture stayed
    // dead by a different route. `hyprctl` answers again now, but on a poll
    // and never on the gesture's critical path.
    //
    // Whether the pointer was over the bar when the last gesture was gated,
    // and where it was. Nothing reads these to make a decision, which is the
    // point: the decision used to be made from exactly this, and it is what
    // killed the gesture.
    property bool cursorOnBar: false
    property real cursorBarX: 0

    // ── Where the POINTER is, for the gesture's zone and its gate ────────
    //
    // The gesture belongs to the BAR: it works when the pointer is parked on
    // the top bar's empty stretches, the left one for brightness and the
    // right one for volume, and nowhere else. A swipe anywhere on the
    // desktop is not this gesture, and a version that answered everywhere
    // made the two controls unreachable in practice -- the pointer sits
    // right of centre almost everywhere, so "brightness" became a zone you
    // had to go hunting for.
    //
    // WHY NOT THE HOVER HANDLER, which is right there and free: the bar's
    // window has an input region with the gaps CUT OUT of it, so a pointer
    // over an empty stretch is never delivered to the bar at all and the
    // hover simply reads false -- `gapState`'s own comment says so. That is
    // not a bug to work around, it is the design (clicks have to reach the
    // windows under the bar), and it is why the two gates could never both
    // be true: "pointer over the bar" was false exactly where "pointer in a
    // gap" was true. 91 gate decisions, 0 acceptances.
    //
    // So the pointer is read from `hyprctl cursorpos` on a slow poll, which
    // reports it wherever it is. BOTH coordinates are needed: x picks the
    // spacing, y decides whether the pointer is on the bar at all. The bar's
    // window spans the screen from (0, 0), so a screen position IS a
    // bar-content position and nothing has to be converted.
    property real pointerX: -1
    property real pointerY: -1
    property bool pointerKnown: false

    function rememberLiveCursor() {
        // The hover is preferred whenever it exists, because it is exact and
        // immediate. It is only trusted while it is actually reporting: a
        // HoverHandler that has never been entered reads (0, 0), which is a
        // real number and would otherwise be taken for a pointer parked at
        // the top-left corner of the screen.
        if (root.cursorInBar && root.cursorX > 0 && isFinite(root.cursorX)) {
            root.pointerX = root.cursorX;
            root.pointerY = root.cursorY;
            root.pointerKnown = true;
        }
    }
    onCursorInBarChanged: root.rememberLiveCursor()
    onCursorXChanged: root.rememberLiveCursor()

    // A poll, not a per-gesture fork. The gate is on the path of the first
    // frame of every swipe, and a fork there is latency in exactly the place
    // that cannot afford it -- which is how an earlier version of this ended
    // up declining gestures whose answer arrived after they were over.
    // Background instead: it has no deadline, and it costs one tiny process
    // every two seconds, the same profile as the brightness device poll
    // beside it.
    //
    // It is NOT the gate's answer, though -- it is only the fallback and the
    // diagnostic. At two seconds it is up to two seconds stale, and the gate
    // acts on the FIRST frame of a gesture, so a user who moves the pointer
    // onto the bar and swipes immediately was refused by a reading from
    // before the move: `GATE offbar y=483` and friends, while the bar is
    // y 0..190. Because a refusal latches for the whole gesture, that is
    // exactly "I have to swipe twice". The gate fetches its own reading when
    // a gesture starts, below.
    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: pointerPoll.running = false, pointerPoll.running = true
    }

    // "1234, 567" -> pointerX/pointerY. Shared by both readers so the parse
    // cannot drift between them. Returns whether the text was usable, so the
    // gate can tell "the probe failed" from "the pointer is somewhere else".
    function applyPointerReading(t) {
        const m = String(t).trim().match(/^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)/);
        if (!m)
            return false;
        const x = parseFloat(m[1]);
        const y = parseFloat(m[2]);
        if (!isFinite(x) || x < 0 || !isFinite(y) || y < 0)
            return false;
        root.pointerX = x;
        root.pointerY = y;
        root.pointerKnown = true;
        return true;
    }

    // ── THE GATE'S OWN READING ───────────────────────────────────────────
    //
    // Taken because a gesture started, not on a timer, so it cannot be stale
    // by construction. The cost is one fork per gesture and the gate waits
    // for it -- the only thing that makes waiting safe is that the latch
    // anchors the travel at whatever `TouchpadSwipe.total` is WHEN IT RUNS,
    // so the frames spent waiting are not lost travel, they are simply the
    // frames before tracking began. A swipe is a few hundred milliseconds;
    // `hyprctl` is a few.
    //
    // The generation is captured with the request, so an answer that arrives
    // after the gesture ended is dropped instead of being applied to the NEXT
    // one -- which is the stale-answer latch this file was bitten by before.
    property bool gatePending: false
    property int gateProbeGen: -1

    Process {
        id: gatePointerProbe
        command: ["bash", "-c", "hyprctl cursorpos 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const ok = root.applyPointerReading(text);
                if (!root.gatePending)
                    return;
                root.gatePending = false;
                // The gesture this was asked for is over, or something else
                // already decided it.
            if (root.gateProbeGen !== root.swipeGeneration
                || root.swipeZone !== "" || root.swipeDeclined) {
                root.dgGateStale += 1;
                root.dgGateLast = "stale gen=" + root.gateProbeGen + "/" + root.swipeGeneration;
                return;
            }
                if (!ok) {
                    // The probe failed. Fall back to whatever the background
                    // poll last saw rather than refusing the gesture: a stale
                    // position is a much better answer than none, and this is
                    // the only path on which the old lag can still bite.
                    root.slog("GATE probe-failed");
                }
                root.gateSwipe();
            }
        }
    }

    Process {
        id: pointerPoll
        // `bash -c` rather than the bare binary: the shell's PATH is not
        // guaranteed to contain hyprctl, and a command that cannot be found
        // would leave the pointer unknown forever, which is the silent
        // no-gesture failure this whole mechanism exists to avoid.
        command: ["bash", "-c", "hyprctl cursorpos 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: root.applyPointerReading(text)
        }
    }
    // Set when the gate answered "the cursor is not over the bar" (or not in
    // a gap), so the rest of this gesture stops asking instead of re-deciding
    // per event. Cleared with the rest of the latch.
    property bool swipeDeclined: false

    // ── GENERATION ────────────────────────────────────────────────────────
    // The zone decision used to be asynchronous (a forked `hyprctl` probe),
    // so a quick gesture could end before its own answer landed and a FAST
    // follow-up could begin before it did -- which latched a stale answer
    // into the NEW gesture: travelBase reset mid-swipe, anchor from the old
    // probe's world.
    //
    // The gate is asynchronous AGAIN, and has to be: the only pointer reading
    // that is not stale is one taken when the gesture starts. The generation
    // is what makes that safe -- a request carries the generation it was made
    // in, and an answer arriving after the gesture ended, or after another
    // began, is dropped instead of applied to it.
    property int swipeGeneration: 0

    // ── Dead zone ─────────────────────────────────────────────────────────
    // Resting fingers are not still: the tracker reports tiny dy noise, and
    // the first movement is ignored until travel clears this much of a pad.
    // Compared (not subtracted), so tracking takes over from exactly where
    // the fingers landed -- no jump at the boundary.
    // Compared, never subtracted (see handleBarSwipe). 0.012 meant the hint
    // sat dead for the first 1.2% of tracker travel before anything moved
    // at all, on top of a full rail that was itself too long; halved to
    // 0.008 so the content starts to slide almost as soon as the fingers
    // do. Still comfortably above the few ten-thousandths of resting hand
    // drift, which is the only thing it exists to reject.
    readonly property real swipeDeadzone: 0.003
    property bool swipeArmed: false

    // ── How far ONE frame of a gesture may move the control ─────────────
    // The gesture is absolute: `swipeTravel = base - total`, which is only
    // meaningful while `total` is still the same gesture's accumulator. When
    // the tracker restarts (or its `end` never arrives) that accumulator goes
    // back to 0 and the whole previous travel lands in a single frame -- the
    // control slams into a limit and walks back over the next second, which
    // is the "sound/brightness jumps to 100% at random" report.
    //
    // A real pad frame cannot do that. Measured worst case on this touchpad is
    // a flick of ~0.09 of the pad over ~130 ms, i.e. ~0.007 per frame at the
    // tracker's rate; 0.03 is four times that, and still far below the 0.05+
    // a reset produces. Anything beyond it is a discontinuity, not a swipe.
    readonly property real swipeJumpLimit: 0.03

    // The gesture's gate, asked of the in-process tracker. Synchronous by
    // construction now: no fork, no pipe, no generation to race, and the
    // first event of a gesture is already gated -- which is what the async
    // probe could never promise.
    function gateSwipe() {
        // ── THE GATE: the pointer must be ON the bar ─────────────────
        //
        // The gesture belongs to the bar: the pointer is parked on one of its
        // empty stretches and the fingers are free to be anywhere on the pad.
        // That is the whole interaction, and it is why the vertical test is
        // back after being removed: with no vertical test the swipe answered
        // everywhere on the desktop, which made the bar's two controls
        // unreachable in practice rather than merely unused.
        //
        // It is asked of `pointerY` (from `hyprctl cursorpos`) and NOT of
        // `cursorInBar`, because the bar's input region cuts its gaps out --
        // a pointer over a gap is never delivered to the bar, so the hover
        // reads false exactly where this gesture is supposed to work. The two
        // tests could never both be true, which is how 91 gate decisions
        // produced 0 acceptances.
        if (!root.pointerKnown
            || !isFinite(root.pointerX) || root.pointerX < 0
            || !isFinite(root.pointerY) || root.pointerY < 0) {
            root.slog("GATE nopos");
            root.swipeDeclined = true;
            root.dgGateNopos += 1;
            root.dgGateLast = "nopos";
            return;
        }
        const x = root.pointerX;
        const y = root.pointerY;
        root.cursorOnBar = true;
        root.cursorBarX = x;
        // The bar's own window is the top strip of the screen and starts at
        // y=0, so "on the bar" is "inside the first `height` logical pixels".
        // 2px of slack so a pointer resting on the very bottom edge of the
        // bar is not refused for being a rounding away from inside it.
        if (y > root.height + 2) {
            root.slog(`GATE offbar y=${y.toFixed(0)}`);
            root.swipeDeclined = true;
            root.dgGateOffbar += 1;
            root.dgGateLast = "offbar y=" + Math.round(y) + ">" + Math.round(root.height);
            return;
        }
        // HORIZONTAL: which empty stretch the pointer is in. One function, so
        // the diagnostic and the gate cannot disagree about what counts.
        const spacing = root.pointerSpacing();
        if (spacing === "") {
            // On the bar, but not in one of its EMPTY stretches -- over the
            // clock, the tray, the now bar, the middle section.
            //
            // This DECLINES, and there is no fallback. A fallback was tried:
            // splitting on the centre island whenever the pointer was not in a
            // gap, which made the swipe work from anywhere on the desktop and
            // therefore made "brightness" almost unreachable -- the pointer
            // sits right of centre nearly everywhere, so almost every swipe
            // asked for volume and the left half of the bar stopped being a
            // control at all. The point of the gesture is that the two
            // stretches MEAN the two controls; anywhere else there is nothing
            // to mean.
            root.slog(`GATE nogap x=${x.toFixed(0)} y=${y.toFixed(0)}`);
            root.swipeDeclined = true;
            root.dgDeclines += 1;
            root.dgGateLast = "nogap x=" + Math.round(x);
            return;
        }
        const zone = spacing === "left" ? "brightness" : "volume";
        root.slog(`GATE gap x=${x.toFixed(0)} y=${y.toFixed(0)} -> ${zone}`);
        root.dgGateLast = "gap->" + zone + " x=" + Math.round(x);
        root.latchSwipe(zone, root.swipeGeneration, TouchpadSwipe.total);
    }

    // Which of the bar's two EMPTY stretches the pointer is in: "left",
    // "right", or "" for neither -- including when the pointer is not on the
    // bar at all, which is the common case and must read as "".
    //
    // It is a function rather than inline arithmetic in the gate because the
    // diagnostic reports the same answer, and a diagnostic that recomputes
    // the rule by hand is a diagnostic that lies the moment the rule moves.
    function pointerSpacing() {
        if (!root.pointerKnown
            || !isFinite(root.pointerX) || root.pointerX < 0
            || !isFinite(root.pointerY) || root.pointerY < 0)
            return "";
        // Off the bar entirely. The bar's window is the top strip of the
        // screen and starts at y=0; 2px of slack so a pointer resting on its
        // bottom edge is not refused for being a rounding away from inside.
        if (root.pointerY > root.height + 2)
            return "";
        const x = root.pointerX;
        // 6 logical px of slack keeps the boundary from feeling razor-thin.
        const gapSlack = 6;
        const leftIslRight = leftIsland.visible
            ? leftIsland.x + leftIsland.width - islandRadius : 0;
        const rightIslLeft = rightIsland.visible
            ? rightIsland.x + islandRadius : root.width;
        // THE REMEMBERED EXTENTS. This is the same bug the gap hints just
        // had, one layer down: an island that extends -- the volume slider
        // does exactly this -- shrinks its gap out from under a cursor that
        // never moved, and the gate then declines a swipe the user is making
        // in precisely the place they are pointing. The hint disappearing was
        // the visible half; this was the functional half, and it is the one
        // that actually cost the user their gesture.
        //
        // Both gaps test their WHOLE remembered interval rather than one
        // remembered edge, because the two gaps shrink from opposite ends:
        // the right gap loses its right edge when the right island grows
        // leftward, the left gap loses its left edge when the left island
        // grows rightward. A single remembered edge would have fixed one and
        // left the other.
        //
        // The hints remember each gap's extent from while the cursor was
        // genuinely inside it, and only then, so a swipe is accepted in the
        // gap as it is NOW or as it WAS when the cursor was last on it --
        // never in a place the user was never pointing at. The pointer's x
        // and the hints' x are one axis: both are bar-content coordinates,
        // and the bar's window spans the screen from 0.
        if ((x > leftIslRight + gapSlack && x < root.centerIslandLeft - gapSlack)
            || (gapHintLeft.hasAnchor
                && x > gapHintLeft.anchorGeomX + gapSlack
                && x < gapHintLeft.anchorGeomX
                    + gapHintLeft.anchorGeomW - gapSlack))
            return "left";
        if ((x > root.centerIslandRight + gapSlack && x < rightIslLeft - gapSlack)
            || (gapHintRight.hasAnchor
                && x > gapHintRight.anchorGeomX + gapSlack
                && x < gapHintRight.anchorGeomX
                    + gapHintRight.anchorGeomW - gapSlack))
            return "right";
        return "";
    }

    // ── Anchor truth, in the background ───────────────────────────────────
    // The idle screensaver writes the backlight directly, so the shell's
    // mirror can drift from the panel. Reading the device inline used to
    // cost the gate enough latency to miss the first slice of every swipe;
    // a 2s poll keeps a fresh device reading on hand, and the latch
    // uses it without waiting for anything.
    property real deviceBrightness: -1
    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: bgBrightnessRead.running = false, bgBrightnessRead.running = true
    }
    Process {
        id: bgBrightnessRead
        command: ["bash", Quickshell.shellPath("scripts/system/brightness-device.sh"), "read"]
        stdout: StdioCollector {
            onStreamFinished: {
                // A reading forked BEFORE a swipe can land DURING it; adopting
                // it would overwrite the fresher truth the gesture itself
                // wrote. Mid-gesture readings are discarded -- the next poll
                // after the gesture confirms. Two more windows are just as
                // poisoned: while the pipe's last write is still in flight
                // (the device has not received that value yet), and for a
                // beat after ANY device write -- a poll forked before it can
                // carry a pre-write number past every other guard. That last
                // case is the slow-swipe jump: slow fingers re-latch constantly
                // (micro-lifts, pauses), and one stale anchor per re-latch is
                // a jump onto a random value.
                if (root.swipeZone !== "" || root.swipeWritesPending > 0
                    || Date.now() - root.lastDeviceWriteAt < 1500)
                    return;
                const parts = text.trim().split(/\s+/);
                if (parts.length >= 5) {
                    const cur = parseFloat(parts[3]);
                    const max = parseFloat(parts[4]);
                    if (max > 0 && !isNaN(cur))
                        root.deviceBrightness = cur / max;        }

    }
}

    }

    // Between gestures the poll above re-syncs the anchor on its own 2s
    // schedule; no extra timer is needed because the optimistic mirror write
    // (deviceBrightness = v/100 in flushSwipeWrite) already holds the best
    // known truth the instant each write is forked.

    // ── TEMPORARY SWIPE TELEMETRY ────────────────────────────────────────
    // DISABLED. This was a temporary harness for debugging the two-finger
    // swipe, kept as a no-op rather than deleted because ~19 call sites
    // around the gesture still name `slog`.
    //
    // What it used to do, and why none of it is left running: it pushed a
    // formatted line into a buffer on EVERY tracker frame and forked a `bash`
    // to append that buffer to /tmp/ii_swipe.log every 250ms. The tracker
    // streams at 100-1000 frames per second while fingers are on the pad, so
    // that was a string built per frame plus a process fork four times a
    // second -- on the main thread, during exactly the gesture whose
    // responsiveness it was measuring. It had already written 6.8 MB.
    //
    // If the swipe ever needs instrumenting again, put it back DELIBERATELY
    // and behind a flag that is off by default: a permanently running debug
    // harness on the hot path costs more than it can ever find.
    function slog(tag) {
        // no-op: see above. Call sites intentionally left in place.
    }

    // ── Where the frames actually go: always-on swipe diagnostics ───────
    // Two independent clocks, because they answer two different questions:
    //
    //   frames   the gap between successive tracker frames AS THE SHELL SEES
    //            them, recorded where they arrive (`swipeFrame` below). A
    //            stall here is either the reader stuttering or the shell being
    //            slow to come back to the pipe.
    //   tick     a 25 ms timer's own lateness, recorded continuously. It says
    //            whether the EVENT LOOP was blocked: a frame gap WITH a late
    //            tick is the shell itself -- bindings, layout, rendering --
    //            holding the UI thread; a frame gap with the tick on time is
    //            upstream of QML (the python reader or the pipe).
    //
    // That distinction is the whole reason this exists: "the swipe freezes"
    // has at least those two causes and they do not share a fix.
    //
    // Aggregates only. No string is built per frame and nothing forks -- the
    // previous telemetry did exactly both of those on every frame and had to
    // be switched off (see `slog` above). This is the version that is cheap
    // enough to leave on, which is the only way a real hand ever gets
    // measured: the gesture cannot be scripted from outside the shell.
    property int dgFrames: 0
    property real dgGapMax: 0
    property real dgGapSum: 0
    property int dgGapBig: 0
    property real dgCostSum: 0
    property real dgCostMax: 0
    property real dgPrevAt: 0
    property real dgTickMax: 0
    property real dgTickPrev: 0
    property int dgTickLate: 0
    property real dgT0: 0
    // Stalls split by whether a gesture frame had arrived in the last 1.2s.
    // "It freezes while I swipe" and "the shell is janky anyway" are the
    // same measurement with different answers, and this is the line between
    // them: a stall counted under `gesture` happened while fingers were on
    // the pad, one under `idle` happened with nobody touching anything.
    property int dgLateGesture: 0
    property int dgLateIdle: 0
    property real dgStallGestureMax: 0
    property real dgStallIdleMax: 0
    // The worst few stalls as {ms since reset, lateness, during gesture}, so
    // a cluster can be told apart from a steady drip.
    property var dgWorst: []
    // The gesture's own plumbing: how many times the zone was decided, how
    // many times the latch was torn down, and how long the first frame waited
    // for the pointer probe. A gesture that re-latches repeatedly spends
    // those stretches doing nothing at all -- which is "freezing" with no
    // stall anywhere in the event loop, so it needs its own counters.
    property int dgLatches: 0
    property int dgResets: 0
    property int dgGates: 0
    property int dgDeclines: 0
    property real dgGateWaitMax: 0
    property real dgGateWaitSum: 0
    property int dgGateWaits: 0
    property real dgFirstFrameAt: 0
    // The verdict of the last gate, so "the gesture did nothing" can be told
    // apart from "the gesture was never allowed to start".
    property string dgGateLast: "-"
    property int dgGateOffbar: 0
    property int dgGateNopos: 0
    property int dgGateStale: 0

    Timer {
        interval: 25
        repeat: true
        running: true
        onTriggered: {
            const now = Date.now();
            if (root.dgTickPrev > 0) {
                // Coarse Qt timers may fire a hair early (~5%); only a LATE
                // tick says anything, so a negative lateness is dropped.
                const late = now - root.dgTickPrev - 25;
                if (late > root.dgTickMax)
                    root.dgTickMax = late;
                if (late > 50) {
                    root.dgTickLate += 1;
                    const live = (now - root.lastSwipeFrameAt) < 1200;
                    if (live) {
                        root.dgLateGesture += 1;
                        if (late > root.dgStallGestureMax)
                            root.dgStallGestureMax = late;
                    } else {
                        root.dgLateIdle += 1;
                        if (late > root.dgStallIdleMax)
                            root.dgStallIdleMax = late;
                    }
                    if (late > 100) {
                        const rec = [now - (root.dgT0 || now), late, live ? 1 : 0];
                        const arr = root.dgWorst.slice();
                        arr.push(rec);
                        arr.sort((a, b) => b[1] - a[1]);
                        root.dgWorst = arr.slice(0, 6);
                        // Said out loud -- but only while fingers are on the
                        // pad. The shell-wide stalls are counted (not logged)
                        // by `status perf`'s tick line; printing every idle
                        // stall would add ~30 lines a minute to a log nobody
                        // reads, which is exactly the harness this file was
                        // burned by before (see `slog`). What matters here is
                        // a stall the user FEELS: one that lands mid-gesture.
                        if (live)
                            console.log(`[stall] ${late}ms live=1`
                                + ` zone=${root.swipeZone === "" ? "-" : root.swipeZone}`
                                + ` ev=${root.evCount}`);
                    }
                }
            }
            root.dgTickPrev = now;
        }
    }

    // The two model sizes a stall line reports, guarded so a missing service
    // cannot turn a diagnostic into a TypeError.
    function mixerLen(): int {
        try { return Audio.mixerApps.length; } catch (e) { return -1; }
    }
    function windowLen(): int {
        try { return HyprlandData.windowList.length; } catch (e) { return -1; }
    }

    function swipeDiagReset(): void {
        root.dgFrames = 0;
        root.dgGapMax = 0;
        root.dgGapSum = 0;
        root.dgGapBig = 0;
        root.dgCostSum = 0;
        root.dgCostMax = 0;
        root.dgPrevAt = 0;
        root.dgTickMax = 0;
        root.dgTickPrev = Date.now();
        root.dgTickLate = 0;
        root.dgLateGesture = 0;
        root.dgLateIdle = 0;
        root.dgStallGestureMax = 0;
        root.dgStallIdleMax = 0;
        root.dgWorst = [];
        root.dgT0 = Date.now();
        root.dgLatches = 0;
        root.dgResets = 0;
        root.dgGates = 0;
        root.dgDeclines = 0;
        root.dgGateWaitMax = 0;
        root.dgGateWaitSum = 0;
        root.dgGateWaits = 0;
        root.dgFirstFrameAt = 0;
        root.dgGateLast = "-";
        root.dgGateOffbar = 0;
        root.dgGateNopos = 0;
        root.dgGateStale = 0;
        root.evCount = 0;
    }

    function swipeDiag(): string {
        const n = root.dgFrames;
        // `t0` is the reset instant in epoch ms, so a stall list can be lined
        // up against an external sampler of the same process.
        return "t0=" + root.dgT0 + " frames=" + n
            + " gapAvg=" + (n > 0 ? (root.dgGapSum / n).toFixed(1) : "-") + "ms"
            + " gapMax=" + root.dgGapMax + "ms"
            + " gap>40ms=" + root.dgGapBig
            + " costAvg=" + (n > 0 ? (root.dgCostSum / n).toFixed(2) : "-") + "ms"
            + " costMax=" + root.dgCostMax + "ms"
            + " tickMax=" + root.dgTickMax + "ms"
            + " tickLate>50ms=" + root.dgTickLate
            + " stalls[g=" + root.dgLateGesture + "/" + root.dgStallGestureMax
            + "ms i=" + root.dgLateIdle + "/" + root.dgStallIdleMax + "ms]"
            + " worst=" + JSON.stringify(root.dgWorst)
            + " ev=" + root.evCount
            + " latch=" + root.dgLatches + "/" + root.dgGates
            + " reset=" + root.dgResets + " decl=" + root.dgDeclines
            + " gateWait avg=" + (root.dgGateWaits > 0
                ? (root.dgGateWaitSum / root.dgGateWaits).toFixed(0) : "-")
            + "ms max=" + root.dgGateWaitMax + "ms"
            + " lastGate=" + root.dgGateLast
            + " offbar=" + root.dgGateOffbar + " nopos=" + root.dgGateNopos
            + " stale=" + root.dgGateStale
            + " zone=" + (root.swipeZone === "" ? "-" : root.swipeZone)
            + " armed=" + root.swipeArmed
            + " trav=" + root.swipeTravel.toFixed(4)
            + " bench[" + root.benchOut + "]";
    }

    // One tracker frame, from arrival to handler. The live gesture AND the
    // bench below both go through here, so the bench measures the same path a
    // hand does: frame gap, scroll block, counter, handler, cost.
    function swipeFrame(dy, nx, ny, fingers, start): void {
        const now = Date.now();
        if (root.dgPrevAt > 0) {
            const gap = now - root.dgPrevAt;
            root.dgFrames += 1;
            root.dgGapSum += gap;
            if (gap > root.dgGapMax)
                root.dgGapMax = gap;
            if (gap > 40)
                root.dgGapBig += 1;
        }
        root.dgPrevAt = now;
        // Every frame is proof the gesture is still happening, whatever
        // `active` says (see `lastSwipeFrameAt`).
        root.lastSwipeFrameAt = now;
        // Bisect switch (see `swipeBypassEnabled`). Deliberately AFTER the
        // arrival bookkeeping, so the freshness test and the frame counters
        // still say the gesture happened while nothing else runs.
        if (root.swipeBypassEnabled)
            return;
        if (start === 2)
            root.blockPadScroll();
        if (start === 2)
            root.evCount += 1;
        const t0 = now;
        root.handleBarSwipe(dy, nx, ny, fingers, start);
        const cost = Date.now() - t0;
        root.dgCostSum += cost;
        if (cost > root.dgCostMax)
            root.dgCostMax = cost;
    }

    // ── A synthetic gesture, on the real path ────────────────────────────
    // Fingers cannot be scripted from outside the shell, but everything
    // AFTER the tracker can be: the bench latches a zone exactly the way
    // `latchSwipe` does and then feeds frames through `swipeFrame` on the
    // shell's own 8 ms clock. The handler, the mirror writes, the island
    // reflows, the gap hint's rail and the rendering all run as they do under
    // a hand -- at a frame rate we chose, which is what makes a stall here
    // attributable to the shell instead of to the reader.
    //
    // The sweep is a triangle out to 0.03 of pad travel and back: big enough
    // to cross several whole percents (so the islands really do reflow and the
    // device pipe really does run), small enough that the control never strays
    // far from where it started, and the finish puts it back there.
    property int benchLeft: 0
    property int benchRan: 0
    property real benchTotal: 0
    property real benchPrev: 0
    property real benchGapMax: 0
    property real benchGapSum: 0
    property int benchN: 0
    property real benchCostSum: 0
    property real benchCostMax: 0
    property real benchTickMax: 0
    property real benchTickPrev: 0
    property real benchAnchor: 0
    property int benchFrames: 0
    property string benchZone: ""
    property string benchOut: "idle"

    Timer {
        id: benchTimer
        interval: 8
        repeat: true
        onTriggered: {
            if (root.benchLeft <= 0) {
                benchTimer.stop();
                root.benchDone();
                return;
            }
            const now = Date.now();
            if (root.benchPrev > 0) {
                const gap = now - root.benchPrev;
                root.benchN += 1;
                root.benchGapSum += gap;
                if (gap > root.benchGapMax)
                    root.benchGapMax = gap;
            }
            if (root.benchTickPrev > 0) {
                const late = now - root.benchTickPrev - 8;
                if (late > root.benchTickMax)
                    root.benchTickMax = late;
            }
            root.benchTickPrev = now;
            root.benchPrev = now;
            root.benchTotal -= 0.0015;
            if (root.benchTotal < -0.03) {
                // The sweep wraps, and a wrap is TWO gestures, not one
                // impossible frame: snapping the accumulator back to 0 while
                // a latch is held is precisely the discontinuity
                // `swipeJumpLimit` exists to reject, and the bench would then
                // spend its time tripping the guard instead of measuring the
                // path a hand takes. Re-latch exactly as a new gesture does.
                root.benchTotal = 0;
                root.resetSwipe();
                root.latchSwipe(root.benchZone, root.swipeGeneration, 0);
            }
            TouchpadSwipe.total = root.benchTotal;
            root.benchLeft -= 1;
            root.benchRan += 1;
            const t0 = now;
            root.swipeFrame(0, 0.5, 0.05, 2, 2);
            const cost = Date.now() - t0;
            root.benchCostSum += cost;
            if (cost > root.benchCostMax)
                root.benchCostMax = cost;
        }
    }

    function benchDone(): void {
        const n = root.benchRan;
        const avgGap = root.benchN > 0 ? root.benchGapSum / root.benchN : 0;
        root.benchOut = "n=" + n
            + " gapAvg=" + avgGap.toFixed(1) + "ms"
            + " gapMax=" + root.benchGapMax + "ms"
            + " costAvg=" + (n > 0 ? (root.benchCostSum / n).toFixed(2) : "-") + "ms"
            + " costMax=" + root.benchCostMax + "ms"
            + " tickMax=" + root.benchTickMax + "ms"
            + " (interval 8ms)";
        const zone = root.benchZone;
        root.resetSwipe();
        TouchpadSwipe.active = false;
        TouchpadSwipe.total = 0;
        // Put the control back where the bench found it.
        if (zone === "volume")
            Audio.setSinkVolume(root.benchAnchor);
        if (zone === "brightness") {
            Brightness.setInstantWrites(false);
            Brightness.setBrightnessFraction(root.benchAnchor);
        }
        root.benchZone = "";
        root.benchLeft = 0;
    }

    // Flip one bisect switch. `name` is "writes" or "push".
    // ── One-finger tap on the sound icon: mute, and unmute ────────────────
    //
    // A plain mute flag, deliberately NOT the volume.
    //
    // The previous version wrote `setSinkVolume(0)` and restored the remembered
    // level on the next tap. Two extra volume writes per press, on the one icon
    // that also owns a scroll handler writing the same property: the level
    // jumped back and forth, the OSD fired twice, and a tap during a swipe
    // fought it. That was the "glitchy" sound icon. Muting is a single flag,
    // nothing to remember, and nothing for the swipe to race against.
    // A one-finger tap is a single left click, so this is called once per tap.
    // The 120ms guard is not about the tracker (it never routes a one-finger
    // tap here) but about a click arriving twice from a stacking bug: two mute
    // writes in a row look exactly like "the tap did nothing", which is how the
    // glitchy icon was described. No human taps the same icon twice in 120ms.
    property real lastMuteAt: 0

    function toggleSoundMute(): string {
        const now = Date.now();
        if (now - root.lastMuteAt < 120)
            return "repeat click ignored";
        root.lastMuteAt = now;
        if (!Audio.sink?.audio)
            return "no sink";
        const muted = !(Audio.sink.audio.muted ?? false);
        Audio.sink.audio.muted = muted;
        return muted ? "muted" : "unmuted";
    }

    // ── The SUPER + G overlay, reachable from here ─────────────────────────
    //
    // SUPER + G is a global shortcut (`overlayToggle` in Overlay.qml) that
    // flips `GlobalStates.overlayOpen`, so that is exactly what this flips. The
    // gesture and the key mean the same thing, with no second implementation to
    // drift away from the first.
    //
    // NO LONGER WIRED TO THE ICON (2026-11-01, user request). The two-finger tap
    // on the sound icon opens the sound panel instead, so nothing calls this
    // any more; it stays as the one-call way to the overlay for anything that
    // wants it later, and because the key itself is the overlay's real door.
    // The old note still holds for whoever re-wires it: the right click is what
    // acts, and the tracker's `onTapTriggered(2)` only reports -- two toggles
    // for one tap is open-then-instantly-close, which is what made the overlay
    // flash for a second and vanish, and the tracker's report is hundreds of
    // milliseconds late, so no time-based latch can collapse the two.
    function toggleOverlayFromTap(): string {
        GlobalStates.overlayOpen = !GlobalStates.overlayOpen;
        return GlobalStates.overlayOpen ? "overlay open" : "overlay closed";
    }

    // The mute toggle, reachable from outside the shell: the 1-finger tap's
    // action, probeable without a touchpad. "The tap did nothing" has three
    // different causes -- no click reached the icon, no sink, or the toggle
    // itself -- which one call separates. It reports the hover the way the
    // gesture path gates on it:
    //   qs -c ii ipc call bar soundTap
    function soundTapProbe(): string {
        if (!soundButton.hovered)
            return "pointer not on the sound icon (hover=false)";
        return root.toggleSoundMute();
    }

    function swipeOpt(name: string, on: string): string {
        const want = on === "on" || on === "true" || on === "1";
        if (name === "writes")
            root.swipeWritesEnabled = want;
        else if (name === "push")
            root.swipePushEnabled = want;
        else if (name === "bypass")
            root.swipeBypassEnabled = want;
        else
            return "unknown opt: " + name;
        return name + "=" + (want ? "on" : "off");
    }

    function swipeBench(zone: string, frames: int): string {
        if (benchTimer.running)
            return "busy: " + root.benchOut;
        root.resetSwipe();
        root.benchZone = zone === "brightness" ? "brightness" : "volume";
        root.benchAnchor = root.benchZone === "volume"
            ? Audio.currentVolume() : Brightness.brightnessFraction();
        root.benchFrames = frames > 0 ? frames : 300;
        root.benchLeft = root.benchFrames;
        root.benchRan = 0;
        root.benchTotal = 0;
        root.benchPrev = 0;
        root.benchGapMax = 0;
        root.benchGapSum = 0;
        root.benchN = 0;
        root.benchCostSum = 0;
        root.benchCostMax = 0;
        root.benchTickMax = 0;
        root.benchTickPrev = 0;
        root.benchOut = "running";
        TouchpadSwipe.total = 0;
        TouchpadSwipe.active = true;
        root.swipeDeclined = false;
        root.gatePending = false;
        // The zone decision the gate would have made, taken directly: the
        // cursor cannot be moved to the gap from out here, and the gate's
        // answer is not what is under test -- everything after it is.
        root.latchSwipe(root.benchZone, root.swipeGeneration, 0);
        benchTimer.start();
        return "started " + root.benchZone + " frames=" + root.benchFrames
            + " interval=8ms anchor=" + root.benchAnchor.toFixed(3);
    }

    // Which half this gesture belongs to, latched for its whole life.
    property string swipeZone: ""
    // ── Bisect switches for the gesture's downstream cost ───────────────
    // The event loop measurably stalls ~200-260ms during a gesture while the
    // handler itself costs only ~0.5ms, so the work is downstream. These two
    // switches let each half be taken out of the picture independently, from
    // outside the shell, without editing code between measurements:
    //   writes  the mirror/device writes (volume + brightness + the pipe)
    //   push    the gap hint's rail displacement (swipePush -> the hints)
    // Flipped by `qs -c ii ipc call bar swipeOpt <name> <on|off>`.
    property bool swipeWritesEnabled: true
    property bool swipePushEnabled: true
    //   bypass  a frame only records its arrival: no scroll block, no
    //           handler, no writes, no rail. A stall that survives THIS is
    //           not in the gesture's work at all.
    property bool swipeBypassEnabled: false
    // The value the control had when the fingers landed, and how far they
    // have travelled since. Together they ARE the value now:
    //     anchor + travel * gain
    property real swipeAnchor: 0
    property real swipeTravel: 0
    // The tracker's cumulative total at the moment the zone latched.
    property real swipeTravelBase: 0
    // The last whole percent handed to the device.
    property int swipeWritten: -1
    // LIVE direction, for the hint: "up"/"down" while armed fingers are
    // moving, held between events (noise below the threshold changes
    // nothing), cleared with the latch. swipeTravelPrev is the travel one
    // event ago -- the delta's sign is the direction.
    property string swipeDirection: ""
    property real swipeTravelPrev: 0
    // When a gesture frame last arrived.
    //
    // `TouchpadSwipe.active` is NOT trustworthy on its own as "the gesture is
    // happening right now". It is set on the tracker's `begin` and cleared on
    // `end`/`cancel`, and those end frames are demonstrably lost: the swipe
    // telemetry shows 2- and 3-finger gestures that begin and are never
    // followed by an end -- one ran for 31 seconds, the last one in the log
    // has nothing after its `BEGIN` at all. A lost end leaves `active` true
    // forever, and since `swipeLiveZone` fed the BAR's "a gesture owns the
    // bar" hold, that is a bar that comes down over a fullscreen window and
    // never goes away again -- with the pointer nowhere near it.
    //
    // So freshness is checked directly, against frames rather than against a
    // flag. Gesture frames only arrive while the fingers MOVE, which is why
    // the window is generous (1.2s): it has to outlast a deliberate pause to
    // read the value, and it does not have to outlast a stuck flag, because
    // a stuck flag was never going to end on its own.
    //
    // Note this changes the BAR's hold only. The zone latch, the travel, the
    // written value and the tracker's own state are all untouched, so a
    // gesture that pauses and carries on simply brings the bar back with the
    // next frame -- no value is lost and nothing is cancelled.
    property real lastSwipeFrameAt: 0
    // A clock to re-evaluate the freshness test. `Date.now()` is not a
    // property, so nothing would re-read it when time passes and without this
    // the whole thing would only be sampled when some other property changed.
    property int swipeClock: 0
    Timer {
        interval: 150
        repeat: true
        running: true
        onTriggered: root.swipeClock++
    }
    readonly property bool swipeFresh:
        // `swipeClock` is read for its tracking side effect only.
        root.swipeClock >= 0
        && (Date.now() - root.lastSwipeFrameAt) < 1200
    readonly property string swipeLiveZone: (TouchpadSwipe.active
        && root.swipeFresh
        && root.swipeZone !== "" && root.swipeArmed) ? root.swipeZone : ""

    // ── Fingers on the pad, right now ────────────────────────────────────
    //
    // A DIAGNOSTIC since the gap fix landed (`bar ipc gapState` reports it as
    // `padLive`); it drives nothing. It was written to shut the bar's
    // input-region gaps for the duration of a gesture, so the scroll the
    // COMPOSITOR hands to whoever owns the pointer's pixel would land on the
    // bar instead of the window under it -- the "swiping for the volume also
    // switched Brave's tabs" report, whose mechanism is worth keeping in mind
    // here: the brightness/volume swipe only works with the pointer in one of
    // the bar's empty stretches (`pointerSpacing`, see `gateSwipe`), and those
    // stretches were exactly the parts of the strip cut out of the input
    // region, so the two-finger motion arrived at the app underneath as well.
    //
    // That route is OFF, for two reasons measured rather than guessed: the
    // compositor has already delivered the first notch before any signal
    // reaches QML (a race the region can only lose), and toggling the region
    // makes the bar's hover BOUNCE -- the pointer is delivered during the
    // gesture and not before it -- which is the enter/leave pair the "pointer
    // never left" hold exists to survive, and the bar visibly dropped during
    // the swipe. `gapPassthrough` in Bar.qml now keeps the strip whole instead.
    //
    // TIMED FROM TOUCH-DOWN, which is what makes it useful as a diagnostic:
    // the tracker's `begin` phase is emitted the moment the finger count
    // settles (touchpad-swipe.py reports a count the instant its slots report
    // coordinates -- no travel is required), so `TouchpadSwipe.active` is
    // already true while the hand is still, before the motion that produces
    // any axis event. The four-second bound is the guard rail for `active`
    // being left true by lost end frames (see `swipeFresh`): a gesture that is
    // really happening keeps producing frames, and one that has stopped falls
    // out of the window either way.
    property double padGestureAt: 0
    Connections {
        target: TouchpadSwipe
        function onActiveChanged() {
            if (TouchpadSwipe.active)
                root.padGestureAt = Date.now();
        }
    }
    readonly property bool padGestureLive: TouchpadSwipe.active
        // `swipeClock` is read for its tracking side effect only (see
        // `swipeFresh`): `Date.now()` is not a property, so without it nothing
        // would re-evaluate as time passes and a stuck flag would never be
        // noticed.
        && root.swipeClock >= 0
        && (root.swipeFresh || (Date.now() - root.padGestureAt) < 4000)

    // ── How far the gesture has pushed the content ──────────────────────
    // -1 (down) .. +1 (up), 0 at rest. This is the joystick's whole input,
    // and it is the FINGERS' TRAVEL, not the value: a line that rose with the
    // brightness was a gauge, and the user is holding a spring-centred
    // control. `swipeTravel` is already signed with up as positive ("on THIS
    // pad an upward swipe arrives as NEGATIVE travel, so travel is base -
    // total", see handleBarSwipe) and it rebases to zero at arming, so the
    // content leaves the middle only once the fingers have actually moved --
    // resting fingers and hand drift never touch it.
    //
    // Full rail at `swipePushFullRail` of tracker travel, which is a property
    // of the DISPLAY, not of the control: brightness moves at gain 2.2 and
    // volume at 1.1, so normalising by either gain would make the same
    // physical swipe throw the content a different distance in the two gaps.
    // This way both gaps behave identically.
    //
    // It is also the SENSITIVITY knob, and it is deliberately small: at
    // 0.22 the content only started visibly moving after a swipe had already
    // covered a sizeable fraction of the control, which read as "nothing
    // happens, then suddenly it is at the end". 0.09 puts the content a
    // third of the way out after a light nudge, and at the end of the throw
    // well before the value has moved much -- the gesture acknowledges the
    // fingers immediately, which is the whole job of a mirror.
    readonly property real swipePushFullRail: 0.09
    readonly property real swipePush: (swipeLiveZone === "" || !root.swipePushEnabled)
        ? 0
        : Math.max(-1, Math.min(1, swipeTravel / swipePushFullRail))

    // The two gap hints, positioned over the bar's own empty stretches —
    // the exact regions the spacing gate accepts, read off the SAME island
    // edges the gate reads (islandRadius inset, not the raw rect), so the
    // hint can never cover a place the gesture does not work, nor miss one
    // that it does.
    //
    // Each spans its WHOLE gap now, edge to edge, rather than a 40px box
    // parked in the middle: the cursor finds the hint anywhere in the
    // spacing, which is what was asked for and what a gap is for. The artwork
    // is centred inside the item, so this widened the hit area and nothing
    // else -- the line and the chevrons sit exactly where they always did.
    SwipeGapHint {
        id: gapHintLeft
        accent: Appearance.colors.colTertiary
        upOnLeft: true
        // Zeroed for the gap the gesture is not in, so a brightness swipe
        // cannot twitch the volume line (and the idle volume line does not
        // sit wherever the last gesture left it -- it is always centred).
        push: root.swipeLiveZone === "brightness" ? root.swipePush : 0
        live: root.swipeLiveZone === "brightness"
        cursorX: root.cursorX
        cursorInBar: root.cursorInBar
        overCenterIsland: root.cursorOnCenterIsland
        fullscreen: barContent.overFullscreen
        height: root.height
        x: leftIsland.visible
            ? leftIsland.x + leftIsland.width - islandRadius : 0
        width: Math.max(0, root.centerIslandLeft - x)
        y: 0
    }
    SwipeGapHint {
        id: gapHintRight
        accent: Appearance.colors.colPrimary
        upOnLeft: false
        push: root.swipeLiveZone === "volume" ? root.swipePush : 0
        live: root.swipeLiveZone === "volume"
        cursorX: root.cursorX
        cursorInBar: root.cursorInBar
        overCenterIsland: root.cursorOnCenterIsland
        fullscreen: barContent.overFullscreen
        height: root.height
        x: root.centerIslandRight
        width: Math.max(0, (rightIsland.visible
            ? rightIsland.x + islandRadius : root.width) - x)
        y: 0
    }

    // Diagnostic: both hints' geometry as numbers. The line lives on a layer
    // surface, which cannot be screenshotted from a script and cannot be
    // hovered by one either, so this is the only way to check that the rest
    // position, the travel and the two arrow fades are where they belong.
    // Formatted inline rather than through a helper function on purpose: a
    // block-bodied `var` binding that CALLS a QML function is what this build
    // answers with "should be coerced to void because the function called is
    // insufficiently annotated" (see the notes on the click-through runs).
    readonly property string gapHintState:
        "L {x=" + Math.round(gapHintLeft.x) + " w=" + Math.round(gapHintLeft.width)
        + " mid=" + gapHintLeft.railMid.toFixed(1) + " half=" + gapHintLeft.railHalf
        + " push=" + gapHintLeft.displacement.toFixed(3)
        + " lineY=" + gapHintLeft.railMid.toFixed(1)
        + " contentY=" + gapHintLeft.contentY.toFixed(1)
        + " top=" + gapHintLeft.topFade.toFixed(2) + " bot=" + gapHintLeft.bottomFade.toFixed(2)
        + " live=" + gapHintLeft.live + "}"
        + " R {x=" + Math.round(gapHintRight.x) + " w=" + Math.round(gapHintRight.width)
        + " push=" + gapHintRight.displacement.toFixed(3)
        + " lineY=" + gapHintRight.railMid.toFixed(1)
        + " contentY=" + gapHintRight.contentY.toFixed(1)
        + " top=" + gapHintRight.topFade.toFixed(2) + " bot=" + gapHintRight.bottomFade.toFixed(2)
        + " live=" + gapHintRight.live + "}"
        + " gesture{z=" + root.swipeLiveZone + " travel="
        + root.swipeTravel.toFixed(4) + " push=" + root.swipePush.toFixed(3) + "}"
        // The hover latch, so "the gap moved out from under a cursor that
        // never moved" can be told apart from a real departure without
        // having to watch the bar: `cur` is the tracked cursor, `in` whether
        // it is over the bar, `aL/aR` the remembered anchors, and `hL/hR`
        // whether each hint is currently showing.
        + " cur{x=" + root.cursorX.toFixed(0) + " in=" + root.cursorInBar
        + " aL=" + gapHintLeft.anchorCursorX.toFixed(0)
        + " aR=" + gapHintRight.anchorCursorX.toFixed(0)
        + " dL=" + gapHintLeft.displaced
        + " dR=" + gapHintRight.displaced
        + " hL=" + gapHintLeft.hovering
        + " hR=" + gapHintRight.hovering
        // `showing` is the decision the eye actually sees, and the hover latch
        // above is only what it is decided FROM -- over a fullscreen window the
        // two part company, which is the question this diagnostic gets asked:
        // "the line is missing over a fullscreen app". `o` is that decision
        // after the fade, which is what "did it ever appear" really means.
        + " sL=" + gapHintLeft.showing
        + " sR=" + gapHintRight.showing
        + " oL=" + gapHintLeft.opacity.toFixed(2)
        + " oR=" + gapHintRight.opacity.toFixed(2) + "}"

    // ── The write pipe ────────────────────────────────────────────────────
    // Volume writes are one cheap atomic call, so per-event writing works.
    // Brightness writes fork brightnessctl, which goes through logind's DBus
    // and costs ~26ms -- and the previous mechanism (flush timer at 45ms +
    // kill-and-restart) TERMINATED most writes mid-flight, so whole ranges of
    // steps never reached the panel at all: worse than the race it replaced.
    //
    // Volume's SEMANTICS, on brightness's pipe: never kill a write; keep the
    // newest requested value in `swipePendingPercent`; when the in-flight
    // write completes, immediately start the next with that newest value.
    // Writes are strictly ordered, nothing is lost but superseded
    // intermediates (exactly like PipeWire dropping intermediate volumes),
    // and the pipeline self-paces at the device's real throughput -- in-flight
    // + pending means at most ~2 writes of lag (~50ms), which the panel's
    // easing renders as a continuous glide.
    property int swipePendingPercent: -1
    // Device writes forked by the pipe that have not come back yet. While it
    // is non-zero the kernel's value is OLDER than what the fingers asked
    // for, so no one may read the device and call it truth.
    property int swipeWritesPending: 0
    // When the pipe last forked a device write. Device reads are refused for
    // a beat after this (see the poll's guard): the read cannot tell a value
    // it fetched from one the device had before our write landed.
    property real lastDeviceWriteAt: 0
    readonly property Process swipeBrightnessWriter: Process {
        // DIAGNOSTIC: the writer's stderr and exit code. The mirror moved but
        // the backlight did not, and the only difference between those two
        // outcomes is what this process returned -- which was invisible.
        stderr: StdioCollector {
            onStreamFinished: {
                const t = text.trim();
                if (t.length > 0)
                    root.slog(`WRITER-ERR ${t.slice(0, 160)}`);
            }
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0)
                root.slog(`WRITER-RC ${exitCode}/${exitStatus} cmd=${swipeBrightnessWriter.command.join(" ")}`);
            root.pumpSwipeWrite();
        }
    }
    property real queuedAt: 0
    property int evCount: 0
    function flushSwipeWrite() {
        if (root.swipeBrightnessWriter.running) {
            root.slog(`FLUSH-BUSY pend=${root.swipePendingPercent}`);
            return; // in flight: it will pump the pending value on exit
        }
        if (root.swipePendingPercent < 0)
            return;
        root.slog(`FLUSH zone=${root.swipeZone} v=${root.swipePendingPercent} age=${Date.now() - root.queuedAt}ms`);
        const v = root.swipePendingPercent;
        root.swipePendingPercent = -1;
        // Both zones already wrote CONTINUOUSLY, per event, above -- volume
        // through its own cheap call, brightness through the mirror. There is
        // nothing left for the pipe to do except move the DEVICE, which only
        // accepts whole percent. Re-writing either value from `v` here would
        // snap the panel backwards to an integer on every write: the exact
        // jump the continuous mirror exists to remove.
        if (root.swipeZone === "volume")
            return;
        swipeBrightnessWriter.command = ["bash",
            Quickshell.shellPath("scripts/system/brightness-device.sh"),
            "set", String(v)];
        root.swipeWritesPending += 1;
        root.lastDeviceWriteAt = Date.now();
        swipeBrightnessWriter.running = true;
    }
    function pumpSwipeWrite() {
        // A write finished: if a newer value is queued, start it at once.
        // (Called after every completion, including the gesture's last write
        // -- a pending final value always lands, even post-reset.)
        root.swipeWritesPending = Math.max(0, root.swipeWritesPending - 1);
        root.slog(`PUMP pend=${root.swipePendingPercent}`);
        if (root.swipePendingPercent >= 0)
            root.flushSwipeWrite();
    }

    function cancelSwipePipe() {
        // Kill the in-flight brightness write and discard any queued value.
        // Called when the swipe direction reverses, so the device does not land
        // a stale value from the old direction after the user has already moved
        // the other way (which reads as a random jump).
        root.swipeBrightnessWriter.running = false;
        root.swipeWritesPending = 0;
        root.swipePendingPercent = -1;
    }

    function resetSwipe() {
        root.dgResets += 1;
        root.slog(`RESET zone=${root.swipeZone} w=${root.swipeWritten} pend=${root.swipePendingPercent} tr=${root.swipeTravel.toFixed(4)}`);
        // Land any pending write FIRST, while the zone is still known: the
        // last position the fingers held must reach the device.
        root.flushSwipeWrite();
        if (root.swipeZone === "brightness")
            Brightness.setInstantWrites(false);
        // No ease-back write: the mirror was updated per write and equals the
        // final value already; the pipe lands the device's final step.
        root.swipeZone = "";
        root.swipeAnchor = 0;
        root.swipeTravel = 0;
        root.swipeWritten = -1;
        root.swipeTravelBase = 0;
        root.swipeDeclined = false;
        root.swipeArmed = false;
        root.swipeDirection = "";
        // Any reading still in flight belongs to the gesture that just ended.
        // The generation bump below would already make its answer stale, but
        // clearing the flag here means the NEXT gesture asks for its own
        // immediately instead of waiting on this one's corpse.
        root.gatePending = false;
        // A new generation invalidates any probe in flight -- its answer AND
        // its slot (the start guard is "if not running").
        root.swipeGeneration += 1;
    }

    // Latch the control: zone from the cursor, anchor from the device
    // reading, travel base from the tracker's total AT THAT MOMENT. The
    // tracker's re-join grace (150ms, in touchpad-swipe.py) already keeps
    // its accumulator across a finger micro-lift, so this anchor stays true
    // for the whole physical gesture without any QML-side machinery.
    function latchSwipe(zone, gen, totalAtProbe) {
        if (gen !== root.swipeGeneration)
            return;
        if (!TouchpadSwipe.active) {
            root.resetSwipe();
            return;
        }
        // How long the gesture's first frames waited for this decision: the
        // time between the first frame of the gesture and its latch is dead
        // air the fingers feel as "nothing is happening".
        root.dgLatches += 1;
        root.dgGateLast = "latched:" + zone;
        if (root.dgFirstFrameAt > 0) {
            const wait = Date.now() - root.dgFirstFrameAt;
            root.dgGateWaitSum += wait;
            root.dgGateWaits += 1;
            if (wait > root.dgGateWaitMax)
                root.dgGateWaitMax = wait;
            root.dgFirstFrameAt = 0;
        }
        root.swipeZone = zone;
        root.swipeWritten = -1;
        root.swipeArmed = false;
        root.swipeTravelPrev = 0;
        root.swipeDirection = "";
        root.swipeTravelBase = (totalAtProbe !== undefined
            && totalAtProbe !== null && isFinite(totalAtProbe))
            ? totalAtProbe : TouchpadSwipe.total;
        root.swipeAnchor = zone === "brightness"
            ? (root.deviceBrightness >= 0 ? root.deviceBrightness
                                          : Brightness.brightnessFraction())
            : Audio.currentVolume();
        root.slog(`LATCH ${zone} gen=${gen} base=${totalAtProbe !== null && isFinite(totalAtProbe) ? totalAtProbe.toFixed(4) : "null"} anchor=${root.swipeAnchor.toFixed(3)}`);
        if (zone === "brightness") {
            // SINGLE-WRITER MODE. The service updates its mirror only (no
            // Behaviour, no forks); the ordered pipe below owns every device
            // write. Without this, each pipe write ALSO drove the service's
            // eased Behaviour, whose intermediate values each forked their
            // own unordered brightnessctl -- two competing write streams per
            // swipe, which is the jitter no input tuning could remove.
            Brightness.setInstantWrites(true);
        }
    }

    function handleBarSwipe(dy, nx, ny, fingers, start) {
        // This is the two-finger gesture only.
        if (start !== 2)
            return;
        if (root.swipeDeclined)
            return;

        // Not latched yet: decide once, from a FRESH pointer reading.
        if (root.swipeZone === "") {
            // Horizontal intent is judged ONLY here, before the zone is
            // decided, and only on real travel: once the gesture is latched
            // it IS vertical (the user established that), and rejecting
            // events mid-gesture because slow-swipe totals are both tiny
            // froze the value on hand drift and made it jump later.
            if (Math.abs(TouchpadSwipe.htotal) > Math.abs(TouchpadSwipe.total) * 3
                && Math.abs(TouchpadSwipe.htotal) > 0.01) {
                root.swipeDeclined = true;
                return;
            }
            // A reading is already on its way; the frames arriving until it
            // lands are exactly the frames the OLD synchronous gate spent
            // reading a position from before the pointer got there.
            if (root.gatePending)
                return;
            // Nothing has been latched yet, so no travel has been consumed
            // and the answer can still arrive in time to matter. Asking is
            // cheap and happens once per gesture.
            root.gatePending = true;
            root.gateProbeGen = root.swipeGeneration;
            root.dgGates += 1;
            if (root.dgFirstFrameAt === 0)
                root.dgFirstFrameAt = Date.now();
            gatePointerProbe.running = false;
            gatePointerProbe.running = true;
            return;
        }

        // THE SIGN, measured against real fingers: on THIS pad an upward
        // swipe arrives as NEGATIVE travel, so travel is `base - total` --
        // up is more, down is less, and the value settles where it is left.
        root.swipeTravel = root.swipeTravelBase - TouchpadSwipe.total;

        // Dead zone, compared not subtracted: silence below, tracking above,
        // no jump at the boundary.
        if (!root.swipeArmed) {
            if (Math.abs(root.swipeTravel) < root.swipeDeadzone) {
                root.slog(`DEADZONE tr=${root.swipeTravel.toFixed(4)}`);
                return;
            }
            root.swipeArmed = true;
            // REBASE AT ARMING. The deadzone is COMPARED, never subtracted,
            // so the travel that accumulated while the fingers were inside it
            // was still sitting in `swipeTravel` -- and the first target
            // computed after arming applied all of it at once. At gain 2.2
            // that is 0.0124 * 2.2 = 2.7% of the rail appearing in a single
            // frame, which is exactly the "random jump" a slow swipe shows
            // when a hand drift finally crosses the threshold. Moving the
            // base to the total AT THIS MOMENT makes the control start from
            // zero travel and follow the fingers from there.
            root.swipeTravelBase = TouchpadSwipe.total;
            root.swipeTravel = 0;
            root.swipeTravelPrev = 0;
            root.slog(`ARM rebased tr=0 total=${TouchpadSwipe.total.toFixed(4)}`);
        }
        // ── Continuity: no single frame may jump ─────────────────────────
        // See `swipeJumpLimit`. `swipeTravelBase` belongs to the gesture that
        // latched it; if the accumulator behind it was reset, the next frame
        // expresses months of old travel as one enormous step. Re-base on the
        // CURRENT total and leave the control exactly where it is: the ghost
        // travel is discarded, and the fingers carry on from this frame.
        const step = root.swipeTravel - root.swipeTravelPrev;
        if (Math.abs(step) > root.swipeJumpLimit) {
            root.slog(`JUMP tr=${root.swipeTravel.toFixed(4)} prev=${root.swipeTravelPrev.toFixed(4)} step=${step.toFixed(4)} -- rebased to total=${TouchpadSwipe.total.toFixed(4)}`);
            root.swipeTravelBase = TouchpadSwipe.total;
            root.swipeTravel = 0;
            root.swipeTravelPrev = 0;
            return;
        }

        // Direction for the hint. Deadzone on the DELTA (not on travel):
        // resting fingers wobble a few ten-thousandths and must not flip
        // the chevrons, while any real stroke crosses this instantly.
        const dTravel = step;
        root.swipeTravelPrev = root.swipeTravel;
        const newDir = dTravel > 0.0015 ? "up" : (dTravel < -0.0015 ? "down" : "");
        // When the fingers reverse direction, the pipe may still be flushing
        // values from the OLD direction. Those values are now wrong -- the user
        // is moving the other way and the device must not land them. Cancel the
        // in-flight write and flush the current target immediately so the device
        // tracks the reversal without a delay that reads as a random jump.
        if (newDir && newDir !== root.swipeDirection && root.swipeZone === "brightness")
            root.cancelSwipePipe();
        if (newDir)
            root.swipeDirection = newDir;

        const gain = root.swipeZone === "brightness"
            ? root.swipeGainBrightness : root.swipeGainVolume;
        // The ceiling is PER ZONE, and that is the whole of "maximum means
        // maximum".
        //
        // Brightness tops out at 1.0 because 1.0 IS the panel's maximum: the
        // helper writes N% of `max_brightness` (400 on this machine's
        // `intel_backlight`), so 100% is the hardware limit and there is
        // nothing above it to reach for.
        //
        // Volume now tops out at 1.0 like brightness, because 1.0 IS the
        // ceiling on both scales: the shell's 100% is `Audio.hardMaxValue`
        // (2.0) and `Audio.setSinkVolume` applies that ratio. It used to read
        // `Audio.hardMaxValue` here, back when the anchor was the sink's own
        // value and "100%" meant 1.0 -- and before that it was clamped to 1.0
        // here, so the swipe stopped at 100% while the rail beside it went to
        // 200%.
        const ceiling = 1.0;
        // Volume may reach ZERO; brightness may not.
        //
        // The floor used to be 0.01 for both zones, and that is why a swipe all
        // the way down stopped on 1% and still made noise. Measured on this
        // sink: the shell's 1% is raw 0.02, which lands the hardware on ALSA
        // Master 14 steps / -56.5 dB against its own floor of 0 steps /
        // -63.5 dB -- an audible level, not silence.
        //
        // Brightness KEEPS the floor, for its own reason: 0% there is a black
        // panel, and nothing on the rail warns that the last millimetre of
        // travel switches the display off.
        //
        // Volume drops it, because 0 is the one number that means exactly what
        // it says -- PipeWire scales the stream by the sink volume, so 0.0 is
        // digital silence -- and the old floor was the only thing holding the
        // gesture off it.
        //
        // The SNAP is what makes 0 REACHABLE. This sink quantises upward:
        // `wpctl set-volume ... 0.005` reads back as 0.01, so a target merely
        // near zero -- 0.002, 0.004 -- comes back as 1% however far the fingers
        // travel, and the rail never shows the zero being asked for. Below one
        // shell percent the volume gesture therefore takes 0 outright; 1% and
        // above are left exactly as they were.
        const floor = root.swipeZone === "brightness" ? 0.01 : 0;
        const wanted = root.swipeAnchor + root.swipeTravel * gain;
        const snapped = root.swipeZone === "volume" && wanted < 0.01 ? 0 : wanted;
        const target = Math.max(floor, Math.min(ceiling, snapped));

        // One write per whole percent, WITH a band: a target still within
        // 0.4% of the last written value changes nothing. Without it, a
        // target hovering on a rounding boundary flaps 44 -> 43 -> 44 -- each
        // write an uneased backlight step, which is the flicker. The band
        // costs nothing perceptible: the value still updates on every net
        // move bigger than the band, and the panel's easing does the rest.
        // CONTINUOUS FEEDBACK. The device only takes whole percent, so gating
        // the MIRROR on the same integer made a slow swipe look frozen and
        // then make it jump: at gain 2.2 one percent of travel needs ~0.0045,
        // while a slow swipe delivers ~0.0009 per event every half to two
        // seconds -- so five events, seconds of finger movement, produced no
        // visible change at all, and then a 1% step landed at once.
        //
        // The mirror (panel, OSD, next gesture's anchor) now follows the
        // FRACTIONAL target on every event, so the control tracks the fingers
        // continuously; only the DEVICE write below stays integer-quantised,
        // because the hardware is what takes integers. Under instantWrites
        // this call is mirror-only -- no fork, no competing write stream.
        // Bisect switch (see `swipeWritesEnabled`): with the writes off the
        // gesture still travels, still arms, still computes `target` and still
        // moves the hint rail -- only the control is left alone. Whatever
        // still stalls with this off is not the device path.
        if (!root.swipeWritesEnabled) {
            root.swipeWritten = Math.round(target * 100);
            return;
        }

        if (root.swipeZone === "volume")
            Audio.setSinkVolume(target);
        else {
            Brightness.setBrightnessFraction(target);
            root.deviceBrightness = target;
        }

        const percentF = target * 100;
        if (root.swipeWritten >= 0 && Math.abs(percentF - root.swipeWritten) < 0.4) {
            root.slog(`BAND tgt=${percentF.toFixed(2)} w=${root.swipeWritten}`);
            return;
        }
        const percent = Math.round(percentF);
        if (percent === root.swipeWritten) {
            root.slog(`SAME ${percent}`);
            return;
        }
        root.slog(`QUEUE tgt=${percentF.toFixed(2)} was=${root.swipeWritten}`);
        root.swipeWritten = percent;
        root.queuedAt = Date.now();

        root.swipePendingPercent = percent;
        // Start the pipe if idle; if a write is in flight it pumps the
        // newest queued value the moment it completes. Either way the
        // newest target reaches the device in order.
        root.flushSwipeWrite();
    }

    Connections {
        target: TouchpadSwipe
        // Two fingers over the sound icon. Deliberately DOES NOT act: the right
        // click that the same gesture synthesises already opened (or closed)
        // the overlay, and a second toggle here is what closed it again a moment
        // later. Reported only, so the log still shows the tracker saw the tap.
        // Guarded as before: this must never be confusable with the three-finger
        // play/pause or the four-finger desktop that shell.qml owns.
        function onTapTriggered(fingers) {
            if (fingers !== 2)
                return;
            if (!soundButton.hovered) {
                // Logged, because the two failure modes look identical from the
                // outside: a tap the tracker never sent, and one it sent while
                // the pointer was resting somewhere else.
                console.log("[tap] 2-finger tap ignored: pointer not on the sound icon");
                return;
            }
            console.log("[tap] 2-finger tap on the sound icon: overlay left to the right click");
        }
        function onMoved(dy, x, y, fingers, start) {
            // Arrivals, frame gaps, the scroll block, the counter and the
            // handler all live in `swipeFrame` now, so this path and the
            // synthetic bench below are measured identically.
            root.swipeFrame(dy, x, y, fingers, start);
        }
        function onGestureEnded(start) {
            // The gesture is over: drop the latch so the next swipe anchors
            // on whatever the control is at then. The tracker's OWN re-join
            // grace handles the micro-lift case inside one gesture; the QML
            // side deliberately holds nothing across gestures -- that held
            // state was the source of the inversion, the 5%-steps and the
            // dead volume, each in its own round.
            if (start === 2)
                root.resetSwipe();
        }
        function onGestureStarted(f) {
            root.lastSwipeFrameAt = Date.now();
            root.slog(`BEGIN f=${f}`);
        }
        // The tracker went away: its process exited (seen as 25 kills in one
        // session, back when its keepalive was starved and the shell mistook a
        // resting hand for a dead reader) and is being restarted after a beat.
        //
        // A latch must not outlive the counter it is anchored to. The restarted
        // tracker begins its accumulator at 0 again, so a held latch would read
        // the next gesture's first frame as one giant swipe -- and the zone it
        // would apply that to was chosen for the pointer position at the START
        // of a gesture that is now over.
        function onAvailableChanged() {
            if (!TouchpadSwipe.available && root.swipeZone !== "") {
                root.slog("TRACKER LOST -- dropping the latch");
                root.resetSwipe();
            }
        }
    }
}
