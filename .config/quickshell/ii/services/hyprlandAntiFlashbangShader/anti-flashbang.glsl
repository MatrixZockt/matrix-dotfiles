#version 300 es
precision highp float;

in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

// Anti-flashbang: a white-dominant gate.
//
// The gate asks one question -- is this frame mostly white? -- and it answers it
// from a 5x5 grid of taps over the frame: `hot`, the share of taps that are at
// least 88% luma, and `mean`, the frame's average luma. Both must agree before
// anything is dimmed, so a dark UI, a photo, a video, a terminal or a mixed
// layout stays exactly as drawn.
//
// THE THRESHOLDS ARE MEASURED, NOT GUESSED (2026-10-23). A maximized light-mode
// browser (Gmail) on this desktop screenshots at hot = 0.71 / mean = 0.74: the
// page body is white but the shell bar, the tab strip and the address bar are
// dark and sit on the shader's first tap rows. An earlier gate asked for
// hot >= 0.60 with a fully-open point at 0.78 plus mean >= 0.55 / 0.72, which
// scored that page at 0.66 -- a fifth of the dim, i.e. nothing anyone could see,
// which is exactly what "the button does nothing" meant. The bar is now
// hot 0.42 -> 0.58 and mean 0.35 -> 0.52, so a real light page opens the gate
// completely, while a half-white layout (hot ~0.45) only just cracks it and a
// dark or photographic frame (hot ~0) never does.
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

const float WHITE = 0.88;     // a tap at or above this luma counts as "white"
const float HOT_LOW = 0.42;   // share of white taps before the gate opens
const float HOT_HIGH = 0.58;  // ...and where it is fully open
const float MEAN_LOW = 0.35;  // frame average before the gate opens
const float MEAN_HIGH = 0.52;

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
    vec4 pixColor = texture(tex, v_texcoord);

    float hot = 0.0;
    float sum = 0.0;
    float samples = 0.0;
    // WHY 5x5, NOT 10x10 (2026-10-27). This grid runs for every pixel of
    // every frame: at 2560x1600 the 10x10 asked ~410 million questions a
    // frame and measured +11 ms of compositor time, which held the whole
    // desktop to 36 fps in eco and 45 fps on AC regardless of the panel's
    // refresh -- the gate was paid for on every pixel instead of once.
    // The taps are every other row and column of the calibrated grid (the
    // positions the thresholds were measured against), so the gate still
    // answers the same way; 25 taps measured at the panel's full rate.
    for (float x = 0.05; x < 1.0; x += 0.2) {
        for (float y = 0.05; y < 1.0; y += 0.2) {
            float l = luma(texture(tex, vec2(x, y)).rgb);
            hot += step(WHITE, l);
            sum += l;
            samples += 1.0;
        }
    }
    hot /= samples;
    float mean = sum / samples;

    float gate = smoothstep(HOT_LOW, HOT_HIGH, hot) * smoothstep(MEAN_LOW, MEAN_HIGH, mean);
    float dim = 1.0 - PEAK * gate;

    fragColor = vec4(pixColor.rgb * dim, pixColor.a);
}
