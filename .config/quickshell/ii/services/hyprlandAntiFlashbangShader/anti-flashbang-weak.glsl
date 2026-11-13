#version 300 es
precision highp float;

in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

// See anti-flashbang.glsl for the gate (a large white patch) and why it is
// measured that way. The weak level uses the same test and only differs in how
// far it dims.
//
// WHY 0.15 (2026-10-23). Weak is the level the sidebar button turns on first, so
// it has to be visible on a white page -- a 0.12 dim ended white at 0.88, which
// reads as "nothing happened" next to the level before it. 0.15 ends white at
// 0.85: a step you can see when the gate opens, still nowhere near the grey wash
// a 0.40 dim used to produce. The deeper cut is the strong level (0.25).
const float PEAK = 0.15;      // white-dominant frame ends at 1.0 - PEAK = 0.85

const float WHITE = 0.88;
const float HOT_LOW = 0.16;
const float HOT_HIGH = 0.30;
const float BLOCK_LOW = 0.50;
const float BLOCK_HIGH = 0.75;
const float MEAN_LOW = 0.16;  // see the note in anti-flashbang.glsl
const float MEAN_HIGH = 0.30;

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
    vec4 pixColor = texture(tex, v_texcoord);

    float white[25];
    float sum = 0.0;
    int i = 0;
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
    float opacity = PEAK * gate;

    fragColor = vec4(pixColor.rgb * (1.0 - opacity), pixColor.a);
}
