#version 300 es
precision highp float;

/*
 * The retention wash.
 *
 * What this is: a compositor-side screen shader that replaces the whole picture
 * with ONE uniform tone, deliberately flat. Nothing is drawn, nothing moves.
 *
 * Why: temporary image retention on an OLED fades fastest when every pixel is
 * driven at the same level for a while, so the trapped charge everywhere gets
 * the same treatment instead of the bright area being driven and the dark area
 * resting. That is all the panel-refresh cycles on a TV are doing.
 *
 * Why not a white field: a full white at a panel's peak is the most wear you
 * can ask for and it hurts to look at. A mid grey drives every pixel uniformly
 * without either. The level is a constant, not an animation: a moving or
 * shaped wash is a pattern, and a pattern is what retention is made of.
 *
 * Why a shader and not an overlay window: an overlay is another surface with a
 * lifetime, and if it ever fails to go away you are staring at a grey screen
 * with no way to know why. A shader is cleared by writing one empty keyword --
 * which is exactly what panel-care.py does when the timer ends, and what
 * `panel-care.py off` does if it is ever interrupted.
 *
 * The interface is Hyprland's screen-shader contract, same as idle-veil.glsl:
 * #version 300 es, `v_texcoord` in, a `tex` sampler, one `fragColor` out. The
 * sampler and the coordinate are part of that contract; this shader does not
 * read them.
 */

in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

const float LEVEL = 0.50;

void main() {
    fragColor = vec4(vec3(LEVEL), 1.0);
}
