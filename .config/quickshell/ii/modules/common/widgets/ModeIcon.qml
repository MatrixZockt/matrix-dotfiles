import QtQuick

/**
 * ModeIcon — hand-drawn power-mode icons so all three read as one family.
 *
 *   performance: arc gauge, needle swung to the hot end + a filled dot
 *   balanced:    same gauge, needle centered
 *   power-saver: a leaf over a battery pill
 *
 * Drawn on canvas at the exact size requested; color follows the chip state.
 */
Canvas {
    id: root

    property string mode: "balanced"
    property color iconColor: "#3fb950"
    property real size: 22

    width: size
    height: size
    antialiasing: true
    onModeChanged: requestPaint()
    onIconColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d");
        ctx.clearRect(0, 0, width, height);
        const c = iconColor;
        const cx = width / 2, cy = height / 2;

        if (mode === "performance" || mode === "balanced") {
            // arc gauge: 220° sweep, needle per mode
            const r = width * 0.36;
            const a0 = Math.PI * 0.75;
            const a1 = Math.PI * 2.25;
            ctx.lineWidth = Math.max(2, width * 0.09);
            ctx.lineCap = "round";
            ctx.strokeStyle = Qt.rgba(c.r, c.g, c.b, 0.30);
            ctx.beginPath();
            ctx.arc(cx, cy + height * 0.08, r, a0, a1);
            ctx.stroke();

            const frac = mode === "performance" ? 1.0 : 0.5;
            ctx.strokeStyle = Qt.rgba(c.r, c.g, c.b, 1.0);
            ctx.beginPath();
            ctx.arc(cx, cy + height * 0.08, r, a0, a0 + (a1 - a0) * frac);
            ctx.stroke();

            // needle
            const na = a0 + (a1 - a0) * frac;
            ctx.strokeStyle = Qt.rgba(c.r, c.g, c.b, 1.0);
            ctx.lineWidth = Math.max(1.5, width * 0.06);
            ctx.beginPath();
            ctx.moveTo(cx, cy + height * 0.08);
            ctx.lineTo(cx + Math.cos(na) * r * 0.78,
                       cy + height * 0.08 + Math.sin(na) * r * 0.78);
            ctx.stroke();

            // hub
            ctx.fillStyle = Qt.rgba(c.r, c.g, c.b, 1.0);
            ctx.beginPath();
            ctx.arc(cx, cy + height * 0.08, Math.max(1.6, width * 0.055), 0, 7);
            ctx.fill();
        } else {
            // power-saver: leaf + battery pill
            const bw = width * 0.52, bh = height * 0.20;
            const bx = cx - bw / 2, by = height * 0.66;
            ctx.strokeStyle = Qt.rgba(c.r, c.g, c.b, 1.0);
            ctx.lineWidth = Math.max(1.5, width * 0.06);
            ctx.strokeRect(bx, by, bw, bh);
            ctx.fillStyle = Qt.rgba(c.r, c.g, c.b, 1.0);
            ctx.fillRect(bx + 1.5, by + 1.5, (bw - 3) * 0.35, bh - 3);
            // battery nub
            ctx.fillRect(bx + bw, by + bh * 0.3, width * 0.05, bh * 0.4);

            // leaf: two arcs meeting at points
            const lr = width * 0.26;
            const lx = cx + width * 0.04, ly = height * 0.34;
            ctx.fillStyle = Qt.rgba(c.r, c.g, c.b, 1.0);
            ctx.beginPath();
            ctx.moveTo(lx - lr, ly);
            ctx.quadraticCurveTo(lx - lr, ly - lr * 1.5, lx + lr, ly - lr * 0.2);
            ctx.quadraticCurveTo(lx + lr * 0.2, ly + lr * 0.9, lx - lr, ly);
            ctx.fill();
        }
    }
}
