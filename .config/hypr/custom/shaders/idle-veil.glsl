#version 300 es
precision highp float;

/*
 * The idle veil.
 *
 * What this is: a compositor-side screen shader that Hyprland applies to the
 * finished frame, so on idle the whole picture goes muted and dark while the
 * layout, the text and the shapes stay exactly where they were. It is not a
 * cover -- nothing is drawn on top of anything -- which is the point: you can
 * still read the build output across the room, you just are not staring into a
 * fully saturated panel while doing it.
 *
 * Why a shader and not an overlay window: an overlay is another surface to
 * keep alive, and if it ever fails to disappear on wake you are looking at a
 * darkened session with no way to know why. A shader is stateless, costs one
 * full-screen pass, and is cleared by writing one keyword.
 *
 * The tunables:
 *   0.60  how much colour is drained (0 = untouched, 1 = greyscale)
 *   0.55  how much of the remaining brightness survives
 * The leftover 0.02 lift keeps crushed blacks from turning the screen into a
 * flat rectangle, so window edges and separators are still legible.
 *
 * The interface is Hyprland's screen-shader contract, and it is not
 * negotiable: #version 300 es, `v_texcoord` in, a `tex` sampler, and one
 * `fragColor` out. See the shell's own anti-flashbang shader for the same
 * shape in a different costume.
 */

in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

void main() {
    vec4 pix = texture(tex, v_texcoord);

    float luminance = dot(pix.rgb, vec3(0.2126, 0.7152, 0.0722));
    vec3 muted = mix(pix.rgb, vec3(luminance), 0.60);

    muted = muted * 0.55 + vec3(0.02);

    fragColor = vec4(muted, pix.a);
}
