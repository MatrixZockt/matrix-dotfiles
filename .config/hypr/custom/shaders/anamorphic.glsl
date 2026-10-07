#version 300 es
precision highp float;

/*
 * Anamorphic illusion - desktop switch.
 *
 * The flat desktop behaves like a stack of five glass sheets sliding past
 * each other: depth bands shear horizontally (raked perspective), each band
 * carries its own seam grid (coarser + brighter with depth), and a "focus
 * band" pulls pixels toward the screen's horizontal center - the layered-
 * print look anamorphic illusions get from the sweet spot.
 *
 * CLOCK - IMPORTANT, read before touching:
 * This fork's screen-shader pipeline does NOT feed a clock to user shaders.
 * A `clock` variable compiles fine as a declaration but stays 0 forever
 * (proven live with a damage-forcing test: a clock-gated shader never lit
 * up, while a constant shader rendered instantly). The binary's internal
 * clock strings belong to the CRASH-screen boilerplate only. User shaders
 * therefore get NO preamble and NO uniforms beyond what they declare -
 * and nothing they declare is updated per frame.
 *
 * The animation clock is thus EXTERNAL: this shader renders at constant
 * full strength while armed, and anamorphic.py (custom/scripts/) clears it
 * once the workspace-switch animation has landed. The driver is the sole
 * clearer: it always clears (finally-block, atexit, SIGINT/SIGTERM), and
 * the option is not persisted, so a reload/login clears it too.
 *
 * WARNING for future editors: the compositor SCANS THE RAW SOURCE TEXT for
 * clock-uniform references - a mere MENTION in a comment is enough to
 * make it demand damage-tracking off (the GPU warning you may have seen).
 * Never write the words u-n-i-f-o-r-m and the clock name adjacent to each
 * other, in code OR in comments.
 *
 * Interface: #version 300 es, v_texcoord in, tex sampler, fragColor out.
 * The file is compiled as a STANDALONE unit - statements outside main()
 * are a parse error, so everything lives in main().
 */

in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

void main() {
    // Constant full strength: the armed window IS the effect's whole span
    // (the clock lives in the driver, see the header).
    const float p = 1.0;

    // -- which depth band is this pixel in (static striping, wobbled) ------
    const int   NB = 5;
    float bandF = v_texcoord.y * float(NB);
    bandF += 0.012 * sin(v_texcoord.x * 14.0 + floor(bandF) * 2.1);
    float band01 = clamp(bandF, 0.0, float(NB)) / float(NB);   // 0..1
    float par    = band01 * 2.0 - 1.0;                         // -1..1

    // -- sheared sample: sheets slide past each other ----------------------
    const float SHEAR = 0.10;
    float       shear = par * SHEAR * p;
    vec2 uv = vec2(v_texcoord.x - shear, v_texcoord.y);

    // Focus band: pixels funnel toward the horizontal center.
    float focusness = 1.0 - abs(par);
    uv.x = mix(uv.x, 0.5 + (uv.x - 0.5) * 0.92, 0.10 * p * focusness * focusness);
    uv = clamp(uv, vec2(0.001), vec2(0.999));

    vec4 c = texture(tex, uv);

    // -- anamorphic seams: coarse grid, stronger in far bands --------------
    float depth  = (par + 1.0) * 0.5;
    float cells  = mix(26.0, 10.0, depth);
    vec2  g      = abs(fract(uv * vec2(cells, cells * 0.6)) - 0.5);
    float seam   = smoothstep(0.46, 0.5, max(g.x, g.y));
    c.rgb = mix(c.rgb, vec3(0.85, 0.87, 0.92), seam * (0.030 + 0.075 * depth) * p);

    // -- depth shading + a glassy anamorphic streak along the top bands ----
    c.rgb *= 1.0 - 0.10 * depth * p;
    float streak = 1.0 - smoothstep(0.0, 0.35, abs(v_texcoord.y - 0.30));
    c.rgb += vec3(0.045, 0.050, 0.060) * streak * p * (0.4 + 0.6 * focusness);

    // -- chromatic split at the sheet edges (print aberration) -------------
    float ab = 0.0022 * p * (0.5 + depth);
    c.r = texture(tex, clamp(uv + vec2(ab, 0.0), vec2(0.001), vec2(0.999))).r;
    c.b = texture(tex, clamp(uv - vec2(ab, 0.0), vec2(0.001), vec2(0.999))).b;

    fragColor = c;
}
