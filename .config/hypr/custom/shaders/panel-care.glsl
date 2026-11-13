#version 300 es
precision highp float;

/*
 * The peak ceiling.
 *
 * What this is: a compositor-side screen shader that leaves everything up to
 * 0.72 alone, then compresses the top of the range into a ceiling of 0.90. A
 * pure white -- a document page, a light-mode app, a blank browser tab -- is
 * driven at 90% instead of 100%, and nothing below the knee is touched.
 *
 * Why a shader and not a brightness step: the backlight is the user's dial, and
 * it dims the whole picture including the parts that were never a problem. This
 * only touches the highlights, so the dark desktop, the text and the contrast
 * you actually read at stay exactly as they were. Burn-in is exposure, and the
 * exposure that hurts is the sustained large bright field -- exactly what this
 * clips. It is the one place software can reach into an app's own content.
 *
 * The compression is linear above the knee rather than a hard clip, so photo
 * highlights roll off instead of flattening into a band, and it is applied to
 * the brightest channel and then scaled back to all three, so hue and
 * saturation are preserved.
 *
 * Why not just clamp with min(): a hard cut at 0.90 destroys every value
 * between 0.90 and 1.00 -- the top 10% of a gradient becomes one flat tone.
 * This maps that same range onto 0.72..0.90 and keeps it distinguishable.
 *
 * The interface is Hyprland's screen-shader contract, the same one
 * idle-veil.glsl and the shell's anti-flashbang shader use:
 * #version 300 es, `v_texcoord` in, a `tex` sampler, one `fragColor` out.
 *
 * The tunables:
 *   0.72   where the ceiling starts to bite
 *   0.90   the brightest a pure white may be driven
 * Raising CEILING to 1.0 makes this a no-op (which is also what `off` does).
 */

in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

const float KNEE = 0.72;
const float CEILING = 0.90;

void main() {
    vec4 pix = texture(tex, v_texcoord);

    float brightest = max(pix.r, max(pix.g, pix.b));
    if (brightest > KNEE) {
        float mapped = KNEE + (CEILING - KNEE) * (brightest - KNEE) / (1.0 - KNEE);
        pix.rgb *= mapped / max(brightest, 1e-5);
    }

    fragColor = pix;
}
