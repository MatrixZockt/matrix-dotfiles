import QtQuick
import qs.modules.common
import qs.modules.common.functions

/**
 * A candlestick chart, drawn on a Canvas.
 *
 * Deliberately a Canvas and not a Shape tree: a 60-candle series with wicks
 * and a volume strip is ~180 primitives, and re-parenting that many Shape
 * nodes every 1.1s tick is exactly the kind of per-frame churn this shell
 * spent a whole investigation learning to avoid. One Canvas repaint of the
 * same picture is a single pass.
 *
 * `rev` is the repaint trigger rather than the array itself -- QML does not
 * diff a JS array, so a mutation in place would never repaint. The producer
 * bumps `rev` (TradingService does) and this listens.
 */
Canvas {
    id: root

    property var candles: []
    property int rev: 0
    property int decimals: 2
    property bool showVolume: true

    // Market semantics, not theme colours: green/red mean bid/ask the world
    // over, and a themed "up" that came out violet would be a worse chart.
    property color upColor: "#46A758"
    property color downColor: "#E5484D"
    readonly property color gridColor: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.88)
    readonly property color axisColor: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.45)
    readonly property color textColor: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.40)

    onCandlesChanged: requestPaint()
    onRevChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    readonly property real padRight: 54
    readonly property real padBottom: 16
    readonly property real padTop: 6
    readonly property real padLeft: 2

    onPaint: {
        const ctx = getContext("2d");
        const W = root.width, H = root.height;
        // NOT ctx.reset(): Qt installs a device-pixel-ratio transform on this
        // context, and reset() wipes it -- the chart would draw in physical
        // pixels and land at half size on a HiDPI screen. clearRect plus
        // per-draw state is the safe equivalent.
        ctx.clearRect(0, 0, W, H);
        ctx.setLineDash([]);
        if (root.candles.length < 2 || W < 40 || H < 30)
            return;

        const cw = W - root.padLeft - root.padRight;
        const ch = H - root.padTop - root.padBottom;
        const volH = root.showVolume ? Math.min(30, ch * 0.22) : 0;
        const priceH = ch - volH - (root.showVolume ? 6 : 0);

        let hiAll = -Infinity, loAll = Infinity;
        for (const c of root.candles) {
            if (c.h > hiAll) hiAll = c.h;
            if (c.l < loAll) loAll = c.l;
        }
        const span = (hiAll - loAll) || (Math.abs(hiAll) || 1);
        const pad = span * 0.08;
        const top = hiAll + pad, bot = loAll - pad;
        const y = v => root.padTop + (top - v) / (top - bot) * priceH;

        const stepX = cw / root.candles.length;
        const bw = Math.max(1.5, stepX * 0.62);

        ctx.font = "9px " + Appearance.font.family.monospace;
        ctx.textBaseline = "middle";

        // Horizontal grid + right-hand price axis.
        for (let i = 0; i <= 4; i++) {
            const gy = root.padTop + (priceH / 4) * i;
            ctx.strokeStyle = root.gridColor;
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(root.padLeft, gy + 0.5);
            ctx.lineTo(root.padLeft + cw, gy + 0.5);
            ctx.stroke();
            const v = top - (top - bot) * (i / 4);
            ctx.fillStyle = root.textColor;
            ctx.textAlign = "left";
            ctx.fillText(v.toFixed(root.decimals), root.padLeft + cw + 8, gy);
        }

        // Candles.
        for (let i = 0; i < root.candles.length; i++) {
            const c = root.candles[i];
            const x = root.padLeft + i * stepX + stepX / 2;
            const up = c.c >= c.o;
            const col = up ? root.upColor : root.downColor;
            ctx.strokeStyle = col;
            ctx.fillStyle = col;
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(x + 0.5, y(c.h));
            ctx.lineTo(x + 0.5, y(c.l));
            ctx.stroke();
            const yo = y(c.o), yc = y(c.c);
            ctx.fillRect(x - bw / 2, Math.min(yo, yc), bw, Math.max(1, Math.abs(yc - yo)));
        }

        // Volume strip.
        if (root.showVolume) {
            const vTop = root.padTop + priceH + 6;
            for (let i = 0; i < root.candles.length; i++) {
                const c = root.candles[i];
                const x = root.padLeft + i * stepX + stepX / 2;
                const vh = Math.max(1, c.v * volH);
                ctx.fillStyle = ColorUtils.transparentize(c.c >= c.o ? root.upColor : root.downColor, 0.72);
                ctx.fillRect(x - bw / 2, vTop + (volH - vh), bw, vh);
            }
        }

        // Last price: dashed rule + a filled pill on the axis.
        const last = root.candles[root.candles.length - 1];
        const ly = Math.max(root.padTop, Math.min(root.padTop + priceH, y(last.c)));
        const col = last.c >= root.candles[0].o ? root.upColor : root.downColor;
        ctx.strokeStyle = col;
        ctx.setLineDash([4, 4]);
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(root.padLeft, ly + 0.5);
        ctx.lineTo(root.padLeft + cw, ly + 0.5);
        ctx.stroke();
        ctx.setLineDash([]);

        const label = last.c.toFixed(root.decimals);
        ctx.font = "bold 9px " + Appearance.font.family.monospace;
        const tw = ctx.measureText(label).width + 12;
        ctx.fillStyle = col;
        ctx.fillRect(root.padLeft + cw + 2, ly - 7.5, tw, 15);
        ctx.fillStyle = "#0A0A0A";
        ctx.textAlign = "left";
        ctx.fillText(label, root.padLeft + cw + 8, ly);
    }
}
