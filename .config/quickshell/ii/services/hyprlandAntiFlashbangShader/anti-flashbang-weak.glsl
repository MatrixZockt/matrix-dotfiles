#version 300 es
precision highp float;

in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

// See anti-flashbang.glsl for the gate (a white-dominant frame) and how its
// thresholds were measured. The weak level uses the same test; only the strength
// of the dim is gentler.
//
// WHY 0.15 (2026-10-23). Weak is the level the sidebar button turns on first, so
// it has to be visible on a white page -- a 0.12 dim ended white at 0.88, which
// reads as "nothing happened" next to the level before it. 0.15 ends white at
// 0.85: a step you can see when the gate opens, still nowhere near the grey wash
// a 0.40 dim used to produce. The deeper cut is the strong level (0.25).
const float PEAK = 0.15;      // white-dominant frame ends at 1.0 - PEAK = 0.85

const float WHITE = 0.88;
const float HOT_LOW = 0.42;   // see the measured note in anti-flashbang.glsl
const float HOT_HIGH = 0.58;
const float MEAN_LOW = 0.35;
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
    float opacity = PEAK * gate;

    fragColor = vec4(pixColor.rgb * (1.0 - opacity), pixColor.a);
}
