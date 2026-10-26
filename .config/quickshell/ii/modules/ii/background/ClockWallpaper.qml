pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.modules.common
import qs.modules.common.widgets
import "clockQuotes.js" as Quotes

// ── The OLED clock wallpaper ───────────────────────────────────────────
//
// THE CLOCK IS THE PEN'S, not an imitation of it. sam_garcia2 / RwaydpP is a
// 350px CSS clock: a #282828 circle, `border: 4px solid #191919`, four
// box-shadows, the dial artwork at `background-size: cover`, three hands
// (8x80 #ffb510, 4x90 #8b8b8b, 2x150 #e5e5e5), and a 15px #747474 centre dot.
// Every one of those numbers is reproduced here, scaled by dialSize/350, so the
// proportions are the pen's rather than approximated.
//
// The dial ARTWORK is the pen's own file (assets/clock/clock-sam.png): the
// yellow 12/3/6/9 and the grey hour ticks, transparent everywhere else, which
// is why the grey face shows through it exactly as it does on the site. The
// original URL is dead (plain http, now a redirect, and 404 over https); this
// copy is the 2022-11-19 capture of it.
//
// THE PAGE IS THE PEN'S TOO, and that is the whole effect. The site's body is
// #282828, the same grey as the dial, and neumorphism only works because of
// that: the face is not a grey disc sitting on a dark screen, it is the SAME
// surface as the page, and nothing but the shadows says a clock is there. It
// was pure black here for a while -- so an OLED panel is off everywhere the
// clock is not -- and on black the trick is lost: the dial becomes a grey plate
// on a hole, and the dark half of every shadow pair has nothing to darken. So
// all FOUR of the pen's box-shadows are drawn now:
//
//   -4px -4px 10px rgba(67, 67, 67, 0.5)   light, up and left (outside)
//    4px  4px 10px rgba(0, 0, 0, 0.3)      dark, down and right (outside)
//   inset 4px 4px 10px rgba(0, 0, 0, 0.5)  dark band inside the top left
//   inset -4px -4px 10px rgba(67,67,67,0.3) light band inside the bottom right
//
// THE LINE UNDER IT. One per hour, from clockQuotes.js, chosen by a full-cycle
// rotation so nothing repeats until the pool is exhausted (~230 hours). The
// small amber rule above it is the hour hand's amber, the only other lit colour
// on the screen.
Item {
    id: root

    // ── The page ───────────────────────────────────────────────────────
    // `body { background: #282828 }`, and it is not decoration: the dial is
    // the SAME grey, so this fill is what the clock is carved out of. Take it
    // away (or paint it black) and the shadows stop reading as depth and start
    // reading as a grey plate on a hole.
    Rectangle {
        anchors.fill: parent
        color: "#282828"
    }

    // ── Time ───────────────────────────────────────────────────────────
    // Seconds precision, always: the second hand IS the sign that the clock is
    // live, and it must tick whether or not the rest of the shell is showing
    // seconds (Config.options.time.secondPrecision is about the bar).
    SystemClock {
        id: wallClock
        precision: SystemClock.Seconds
    }
    readonly property date now: wallClock.date

    readonly property real hoursAngle: (now.getHours() % 12) * 30
        + now.getMinutes() * 0.5
        + now.getSeconds() / 120
    readonly property real minutesAngle: now.getMinutes() * 6
        + now.getSeconds() * 0.1
    readonly property real secondsAngle: now.getSeconds() * 6

    // ── The hourly line ────────────────────────────────────────────────
    readonly property int quoteCount: Quotes.list.length
    readonly property real hourEpoch: Math.floor(now.getTime() / 3600000)
    // A step COPRIME with the pool length. Multiplying the hour by it and
    // taking the remainder walks the whole pool -- every line once before any
    // line twice -- while consecutive hours land far apart, so it reads as
    // random without ever repeating inside a cycle. The candidate list exists
    // only so a pool length that happens to divide the first step still gets a
    // coprime one; `1` is the degenerate fallback and never reached at sane
    // pool sizes.
    readonly property int quoteStep: {
        const n = root.quoteCount;
        const steps = [97, 89, 83, 79, 73, 71, 67, 61];
        for (let i = 0; i < steps.length; i++)
            if (n % steps[i] !== 0)
                return steps[i];
        return 1;
    }
    readonly property string quoteForHour: {
        const n = root.quoteCount;
        if (n === 0)
            return "";
        const index = ((root.hourEpoch * root.quoteStep) % n + n) % n;
        return Quotes.list[index];
    }

    // ── Geometry ───────────────────────────────────────────────────────
    readonly property real dialSize: Math.min(520, Math.min(width, height) * 0.46)
    readonly property real quoteWidth: Math.min(980, width * 0.62)
    // The pen's 350px dial, as a multiplier: every measurement below is a
    // number from its CSS times this.
    readonly property real k: root.dialSize / 350

    // ── CSS box-shadow, as arithmetic ──────────────────────────────────
    // A CSS shadow is not a hand-picked fade. The shadow's SILHOUETTE is
    // shifted by the offset and blurred with a Gaussian whose standard
    // deviation is HALF the blur radius ("a Gaussian blur with a standard
    // deviation equal to half the blur radius" -- css-backgrounds, the
    // shadow algorithm). Every profile below is therefore that Gaussian's
    // cumulative curve, sampled into a gradient, rather than a linear ramp:
    // the pen's shadows have a soft edge, not a cone.
    //
    //   cast   (outer): alpha = A * (1 - Phi)   dark inside the silhouette,
    //                                           gone well outside it
    //   inset:          alpha = A * Phi         the other way round, clipped
    //                                           to the padding box -- CSS's
    //                                           inset shadow is the same
    //                                           blur, turned inside out
    //
    // Phi is the standard normal CDF via Abramowitz & Stegun 7.1.26 (|error|
    // < 1.5e-7, far below one 8-bit step).
    function _erf(x) {
        const t = 1 / (1 + 0.3275911 * Math.abs(x));
        const poly = ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t
            - 0.284496736) * t + 0.254829592) * t;
        const y = 1 - poly * Math.exp(-x * x);
        return x < 0 ? -y : y;
    }
    function _phi(x) {
        return 0.5 * (1 + root._erf(x / Math.SQRT2));
    }

    // One radial gradient holding a blurred disc edge, centred on the shadow's
    // shifted position: `cast` fades inwards-out, `inset` the other way. Both
    // directions are radially symmetric, which is exactly what a gradient is.
    function _shadowGradient(ctx, cx, cy, R, sigma, rgb, alpha, cast) {
        const inner = Math.max(0, R - 3 * sigma);
        const outer = R + 3 * sigma;
        const g = ctx.createRadialGradient(cx, cy, inner, cx, cy, outer);
        const steps = 48;
        for (let i = 0; i <= steps; i++) {
            const r = inner + (outer - inner) * i / steps;
            // Fraction of the (blurred) silhouette that is outside radius r.
            const outside = root._phi((r - R) / sigma);
            const a = alpha * (cast ? 1 - outside : outside);
            g.addColorStop(i / steps, `rgba(${rgb}, ${a})`);
        }
        return g;
    }

    Column {
        id: stack
        anchors.centerIn: parent
        spacing: root.dialSize * 0.10
        readonly property real contentWidth: Math.max(root.dialSize * 1.16, root.quoteWidth)

        // ── The clock ──────────────────────────────────────────────────
        Item {
            width: stack.contentWidth
            height: root.dialSize * 1.16

            // The cast shadow, first and behind everything: the pen's light
            // `-4px -4px 10px rgba(67, 67, 67, 0.5)` up and left, and its dark
            // `4px 4px 10px rgba(0, 0, 0, 0.3)` counterpart down and right.
            // Together they are what lifts the dial off the page -- and the page
            // is the SAME grey as the dial, so they are the only thing that
            // separates the two.
            Canvas {
                id: haloCanvas
                anchors.centerIn: parent
                // The blur reaches three sigma (3 x half the CSS blur) plus the
                // offset past the rim, and the gradient is cut off at the canvas
                // edge, so the dial has to sit that far inside it.
                width: root.dialSize + (3 * 5 + 4) * root.k * 2
                height: width
                onWidthChanged: requestPaint()
                Component.onCompleted: requestPaint()
                onPaint: {
                    // The pen's two OUTER shadows:
                    //
                    //   -4px -4px 10px rgba(67, 67, 67, 0.5)  light, up and left
                    //    4px  4px 10px rgba(0, 0, 0, 0.3)     dark, down and right
                    //
                    // Each is the dial's SILHOUETTE, shifted by the CSS offset
                    // and blurred by the CSS blur -- a soft-edged disc, not a
                    // ring with a hand-picked fade and a diagonal mask. The dial
                    // is opaque and sits on top, so only the crescent outside it
                    // is ever seen: half strength at the silhouette's edge (the
                    // 50% point of any blur) and spent within ~1.5 sigma. The dark one is drawn
                    // now that the page is #282828 -- on black it had nothing to
                    // darken, which is exactly why the clock read as a plate
                    // rather than as a raised disc.
                    const ctx = getContext("2d");
                    const R = root.dialSize / 2;
                    const sigma = 10 * root.k / 2;   // CSS blur radius / 2
                    const off = 4 * root.k;
                    const cx = width / 2, cy = height / 2;
                    ctx.clearRect(0, 0, width, height);

                    const cast = (rgb, alpha, dx, dy) => {
                        ctx.fillStyle = root._shadowGradient(ctx, cx + dx, cy + dy,
                            R, sigma, rgb, alpha, true);
                        ctx.fillRect(0, 0, width, height);
                    };

                    // Painted in the pen's order reversed: later shadows sit
                    // under earlier ones, and both are translucent, so the
                    // light one has to go on top to show through the dark one
                    // the way CSS composites them.
                    cast("0, 0, 0", 0.30, off, off);        // down and right
                    cast("67, 67, 67", 0.50, -off, -off);   // up and left
                }
            }

            Item {
                id: dial
                anchors.centerIn: parent
                width: root.dialSize
                height: width

                // `background: #282828` (the pen's body colour showing through
                // the dial) + `border-radius: 50%`.
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: "#282828"
                }

                // `background: url(clock-sam.png); background-size: cover`.
                // The artwork is transparent except for the numerals and ticks,
                // so the grey above is what it is printed on.
                // `background-size: cover` covers the PADDING box -- the
                // artwork stops at the border's inner edge, not under it, so
                // the 4px is taken off every side before it is stretched.
                Image {
                    anchors.fill: parent
                    anchors.margins: 4 * root.k
                    source: Quickshell.shellPath("assets/clock/clock-sam.png")
                    fillMode: Image.PreserveAspectCrop
                    smooth: true
                    mipmap: true
                }

                // ── The two INSET shadows ────────────────────────────────
                // An inset shadow is the OUTER shadow of the box's own hole:
                // the padding box's edge, shifted by the offset and blurred, and
                // then the inside of the shifted circle is what does NOT get
                // shadowed. So the alpha is full against the rim, fading away
                // over the same Gaussian one blur-width in, and flat zero from
                // there on -- the middle of the face stays the page grey.
                //
                //   inset 4px 4px 10px rgba(0, 0, 0, 0.5)       dark,  top left
                //   inset -4px -4px 10px rgba(67, 67, 67, 0.3)   light, bottom right
                //
                // Two canvases, not one: each gradient is translucent all the
                // way to its outer stop, and a single canvas would have the
                // second gradient's clip eat the band the first one drew.
                Canvas {
                    id: insetDarkCanvas
                    anchors.fill: parent
                    onWidthChanged: requestPaint()
                    Component.onCompleted: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d");
                        const cx = width / 2, cy = height / 2;
                        // Inside the border: a CSS inset shadow is clipped to the
                        // padding box, and the 4px border is not part of it.
                        const R = Math.min(width, height) / 2 - 4 * root.k;
                        const sigma = 10 * root.k / 2;
                        const off = 4 * root.k;
                        ctx.clearRect(0, 0, width, height);
                        ctx.save();
                        ctx.beginPath();
                        ctx.arc(cx, cy, R, 0, Math.PI * 2);
                        ctx.clip();
                        // The shadow of the padding box's own edge, shifted
                        // DOWN-RIGHT: the band it leaves is the top and left.
                        ctx.fillStyle = root._shadowGradient(ctx, cx + off,
                            cy + off, R, sigma, "0, 0, 0", 0.5, false);
                        ctx.fillRect(0, 0, width, height);
                        ctx.restore();
                    }
                }
                Canvas {
                    id: insetLightCanvas
                    anchors.fill: parent
                    onWidthChanged: requestPaint()
                    Component.onCompleted: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d");
                        const cx = width / 2, cy = height / 2;
                        const R = Math.min(width, height) / 2 - 4 * root.k;
                        const sigma = 10 * root.k / 2;
                        const off = 4 * root.k;
                        ctx.clearRect(0, 0, width, height);
                        ctx.save();
                        ctx.beginPath();
                        ctx.arc(cx, cy, R, 0, Math.PI * 2);
                        ctx.clip();
                        // Shifted UP-LEFT: the light band is the bottom right.
                        ctx.fillStyle = root._shadowGradient(ctx, cx - off,
                            cy - off, R, sigma, "67, 67, 67", 0.3, false);
                        ctx.fillRect(0, 0, width, height);
                        ctx.restore();
                    }
                }

                // `border: 4px solid #191919`. Drawn above the artwork because
                // that is what a CSS border does (it paints over the background
                // image's edge), and below the hands because they are children.
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: "transparent"
                    border.width: 4 * root.k
                    border.color: "#191919"
                }

                // ── The three hands, exactly the pen's ─────────────────────
                // .hr = 160px circle, hand 80 tall from its top -> starts 80
                // from the centre and ends at it.
                Item {
                    anchors.fill: parent
                    rotation: root.hoursAngle
                    Rectangle {
                        x: (parent.width - width) / 2
                        y: parent.height / 2 - 80 * root.k
                        width: 8 * root.k
                        height: 80 * root.k
                        radius: 6 * root.k
                        color: "#ffb510"
                    }
                }
                // .mn = 190px circle, hand 90 tall -> starts 95 from the centre,
                // ends 5 short of it.
                Item {
                    anchors.fill: parent
                    rotation: root.minutesAngle
                    Rectangle {
                        x: (parent.width - width) / 2
                        y: parent.height / 2 - 95 * root.k
                        width: 4 * root.k
                        height: 90 * root.k
                        radius: 6 * root.k
                        color: "#8b8b8b"
                    }
                }
                // .sc = 230px circle, hand 150 tall -> starts 115 from the
                // centre and runs 35 PAST it: the pen's second hand has a tail,
                // which is what makes it read as a watch hand.
                Item {
                    anchors.fill: parent
                    rotation: root.secondsAngle
                    Rectangle {
                        x: (parent.width - width) / 2
                        y: parent.height / 2 - 115 * root.k
                        width: 2 * root.k
                        height: 150 * root.k
                        radius: 1 * root.k
                        color: "#e5e5e5"
                    }
                }

                // `.clock:before` -- a 15px #747474 dot, over every hand.
                Rectangle {
                    anchors.centerIn: parent
                    width: 15 * root.k
                    height: width
                    radius: width / 2
                    color: "#747474"
                }
            }
        }

        // ── The hourly line ────────────────────────────────────────────
        Item {
            width: stack.contentWidth
            height: quoteBlock.implicitHeight

            Column {
                id: quoteBlock
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: root.dialSize * 0.038
                width: root.quoteWidth

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(26, root.dialSize * 0.055)
                    height: 2
                    radius: 1
                    color: "#ffb510"
                    opacity: 0.9
                }
                StyledText {
                    id: quoteText
                    width: parent.width
                    text: root.quoteForHour
                    animateChange: true
                    animationDistanceY: 12
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    color: "#dedede"
                    font.family: Appearance.font.family.main
                    font.pixelSize: Math.max(16, Math.round(root.dialSize * 0.052))
                    font.weight: Font.Medium
                    font.letterSpacing: Math.max(1.2, root.dialSize * 0.0052)
                    font.capitalization: Font.AllUppercase
                    lineHeight: 1.22
                }
            }
        }
    }
}
