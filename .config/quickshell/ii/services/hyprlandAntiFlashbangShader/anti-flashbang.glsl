#version 300 es
precision highp float;

in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

// Anti-flashbang: a white-patch gate.
//
// The gate asks one question -- is there a large white AREA on this screen? --
// and answers it from a 5x5 grid of taps over the frame:
//
//   hot   the share of taps that are at least 88% luma;
//   block the fullest 2x2 group of neighbouring taps (0, .25, .5, .75 or 1);
//   mean  the frame's average luma.
//
// WHY A PATCH AND NOT JUST A SHARE (2026-11-01). The share test alone only fires
// when white covers most of the frame, which is the easy case: a maximized light
// page (hot 0.71). It misses the case that actually matters -- a white page
// TILED in dark chrome. A PDF in a browser at fullscreen puts the page in a
// column about a third of the frame wide, with a dark thumb rail, tab strip and
// toolbars around it: that frame scores hot = 0.32 and mean = 0.37, and the old
// gate (hot 0.42 -> 0.58, mean 0.35 -> 0.52) scored it 0.14, i.e. nothing, which
// is exactly what "the anti-flashbang does not trigger on this amount of white"
// meant. A share of the WHOLE frame can never describe "a whole page of white
// sitting inside a dark frame".
//
// The 2x2 test measures the opposite thing: how big the biggest contiguous white
// region is. Two taps apart is a fifth of the frame in each direction, so a 2x2
// group of white taps means a white area at least that large -- a paper column
// scores 0.75-1.0, while scattered white (a bright photo, white text on a dark
// page, a small dialog) cannot fill a quarter of the grid square it sits in.
//
// The mean guard still has to agree, so a genuinely dark screen stays untouched
// even if one white window is open on it: a white dialog on a black desktop
// scores block 1.0 but mean ~0.15, and the gate stays shut.
//
// CALIBRATION. Tap luma of white paper on this panel is 0.93-0.96 and of the
// shell's own chrome 0.05-0.19, so a tap either clears WHITE comfortably or
// misses by a mile -- the thresholds are not sitting on a knife edge.
//
// When the gate opens it SCALES the frame down (a multiplicative dim, the way an
// exposure change works). White stays white, just less bright -- it is never
// blended toward black, so text keeps its contrast.
//
// THE TRADE, stated plainly: a white page IS dimmed while this is on. That is
// the point -- the levels have to do something you can see on a white page, or
// the button is decoration. `off` is one click away in the three-way cycle.
//
// WHY 0.25. Blank white ends at 0.75 against weak's 0.85 -- clearly deeper, and
// still obviously white rather than the grey cardboard a 0.68 strong level used
// to produce.
const float PEAK = 0.25;      // blank-white frame ends at (1 - PEAK) = 0.75

const float WHITE = 0.88;     // a tap at or above this luma counts as white
const float HOT_LOW = 0.16;   // share of white taps before the share route opens
const float HOT_HIGH = 0.30;  // ...and where it is fully open
const float BLOCK_LOW = 0.50; // whitest 2x2 group before the patch route opens
const float BLOCK_HIGH = 0.75;// ...and where it is fully open (3 or 4 taps white)
// 0.16 -> 0.30, not 0.20 -> 0.38: a page column in dark chrome averages 0.31,
// and at the old pair that only reached 0.68 of the dim -- a step you had to
// look for. The guard's job is to keep a dark screen out (it sits at 0.11-0.15,
// below MEAN_LOW), not to scale the good case down.
const float MEAN_LOW = 0.16;  // frame average before either route can open
const float MEAN_HIGH = 0.30;

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
    vec4 pixColor = texture(tex, v_texcoord);

    float white[25];
    float sum = 0.0;
    int i = 0;
    // WHY 5x5, NOT 10x10 (2026-10-27). This grid runs for every pixel of
    // every frame: at 2560x1600 the 10x10 asked ~410 million questions a
    // frame and measured +11 ms of compositor time, which held the whole
    // desktop to 36 fps in eco and 45 fps on AC regardless of the panel's
    // refresh -- the gate was paid for on every pixel instead of once.
    // 25 taps measured at the panel's full rate; the 2x2 test below is
    // arithmetic on those same 25 answers, so it costs no extra sampling.
    for (int xi = 0; xi < 5; ++xi) {
        for (int yi = 0; yi < 5; ++yi) {
            float l = luma(texture(tex, vec2(0.05 + 0.2 * float(xi), 0.05 + 0.2 * float(yi))).rgb);
            white[i] = step(WHITE, l);
            sum += l;
            ++i;
        }
    }

    float hot = 0.0;
    for (int k = 0; k < 25; ++k)
        hot += white[k];
    hot /= 25.0;
    float mean = sum / 25.0;

    // The whitest 2x2 group. `white` is filled column-major (xi outer, yi
    // inner), so a step of 5 moves along x and a step of 1 along y; either way
    // the four taps below are a square of neighbours.
    float block = 0.0;
    for (int gy = 0; gy < 4; ++gy) {
        for (int gx = 0; gx < 4; ++gx) {
            int a = gy * 5 + gx;
            block = max(block, (white[a] + white[a + 1] + white[a + 5] + white[a + 6]) * 0.25);
        }
    }

    float gate = max(smoothstep(HOT_LOW, HOT_HIGH, hot),
                     smoothstep(BLOCK_LOW, BLOCK_HIGH, block))
               * smoothstep(MEAN_LOW, MEAN_HIGH, mean);
    float dim = 1.0 - PEAK * gate;

    fragColor = vec4(pixColor.rgb * dim, pixColor.a);
}
