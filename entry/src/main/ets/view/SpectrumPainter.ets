import { Palette, VizStyle, themeColors } from '../model/Station';

/**
 * 频谱绘制器：由 UI 层定时驱动（160ms），直接向 CanvasRenderingContext2D 绘制。
 * 参考 E6 版 8 种样式与 5 套配色，平板版收敛为 4 种更适合大屏的样式。
 */
export class SpectrumPainter {
  private static readonly BARS: number = 44;
  private levels: number[] = [];
  private phase: number = 0;

  constructor() {
    for (let i = 0; i < SpectrumPainter.BARS; i++) {
      this.levels.push(0.18);
    }
  }

  /** 计算下一帧目标电平；未播放时保持一条可见的静态待机波形。 */
  tick(active: boolean): void {
    this.phase += 1;
    for (let i = 0; i < this.levels.length; i++) {
      let target: number = 0.18 + 0.08 * Math.sin(i * 0.45);
      if (active) {
        const wave: number = 0.52
          + 0.23 * Math.sin(i * 0.37 + this.phase * 0.23)
          + 0.15 * Math.sin(i * 0.13 - this.phase * 0.11)
          + 0.12 * Math.random();
        target = Math.max(0.08, Math.min(0.96, wave));
      }
      this.levels[i] += (target - this.levels[i]) * 0.42;
    }
  }

  draw(ctx: CanvasRenderingContext2D, width: number, height: number, style: number,
       theme: number, active: boolean): void {
    ctx.clearRect(0, 0, width, height);
    if (width <= 0 || height <= 0) {
      return;
    }
    this.drawGrid(ctx, width, height);
    const colors: string[] = themeColors(theme);
    switch (style) {
      case VizStyle.Leds:
        this.drawLeds(ctx, width, height, colors, active);
        break;
      case VizStyle.Wave:
        this.drawWave(ctx, width, height, colors, active);
        break;
      case VizStyle.Meter:
        this.drawMeter(ctx, width, height, colors, active);
        break;
      default:
        this.drawBars(ctx, width, height, colors, active);
        break;
    }
  }

  private drawGrid(ctx: CanvasRenderingContext2D, width: number, height: number): void {
    ctx.strokeStyle = '#263A52';
    ctx.lineWidth = 1;
    for (let r = 1; r < 4; r++) {
      const y: number = height * r / 4;
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(width, y);
      ctx.stroke();
    }
  }

  private colorAt(colors: string[], ratio: number, active: boolean): string {
    if (!active) {
      return '#3B5470';
    }
    const idx: number = Math.max(0, Math.min(colors.length - 1, Math.floor(ratio * colors.length)));
    return colors[idx];
  }

  private drawBars(ctx: CanvasRenderingContext2D, width: number, height: number,
                   colors: string[], active: boolean): void {
    const n: number = this.levels.length;
    const slot: number = width / n;
    const barWidth: number = slot * 0.62;
    for (let i = 0; i < n; i++) {
      const level: number = this.levels[i];
      const barHeight: number = Math.max(3, level * (height - 12));
      const x: number = i * slot + (slot - barWidth) / 2;
      const y: number = height - barHeight;
      ctx.fillStyle = this.colorAt(colors, i / n, active);
      ctx.fillRect(x, y, barWidth, barHeight);
      if (active && barHeight > 8) {
        ctx.fillStyle = '#FFFFFF';
        ctx.globalAlpha = 0.55;
        ctx.fillRect(x, y, barWidth, 2);
        ctx.globalAlpha = 1;
      }
    }
  }

  private drawLeds(ctx: CanvasRenderingContext2D, width: number, height: number,
                   colors: string[], active: boolean): void {
    const n: number = this.levels.length;
    const rows: number = 10;
    const slot: number = width / n;
    const dot: number = Math.max(2, slot * 0.56);
    const gap: number = (height - rows * dot) / (rows + 1);
    for (let i = 0; i < n; i++) {
      const lit: number = Math.round(this.levels[i] * rows);
      const x: number = i * slot + (slot - dot) / 2;
      for (let r = 0; r < rows; r++) {
        const y: number = gap + r * (dot + gap);
        const on: boolean = r >= rows - lit;
        ctx.fillStyle = on ? this.colorAt(colors, r / rows, active) : '#22334A';
        ctx.fillRect(x, y, dot, dot);
      }
    }
  }

  private drawWave(ctx: CanvasRenderingContext2D, width: number, height: number,
                   colors: string[], active: boolean): void {
    const n: number = this.levels.length;
    const mid: number = height / 2;
    ctx.lineWidth = 3;
    ctx.strokeStyle = active ? colors[3] : Palette.TEXT_FAINT;
    ctx.beginPath();
    for (let i = 0; i < n; i++) {
      const x: number = i * width / (n - 1);
      const y: number = mid - this.levels[i] * (height * 0.42);
      if (i === 0) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.stroke();
    ctx.strokeStyle = active ? colors[1] : Palette.BORDER;
    ctx.lineWidth = 2;
    ctx.beginPath();
    for (let i = 0; i < n; i++) {
      const x: number = i * width / (n - 1);
      const y: number = mid + this.levels[i] * (height * 0.42);
      if (i === 0) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.stroke();
    ctx.strokeStyle = '#263A52';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, mid);
    ctx.lineTo(width, mid);
    ctx.stroke();
  }

  private drawMeter(ctx: CanvasRenderingContext2D, width: number, height: number,
                    colors: string[], active: boolean): void {
    const rowH: number = 22;
    const top: number = (height - rowH * 2 - 16) / 2;
    for (let ch = 0; ch < 2; ch++) {
      const y: number = top + ch * (rowH + 16);
      ctx.fillStyle = '#1A2A3E';
      ctx.fillRect(0, y, width, rowH);
      let energy: number = 0;
      for (let i = 0; i < this.levels.length; i++) {
        energy += this.levels[i];
      }
      const ratio: number = active ? Math.min(1, energy / this.levels.length + ch * 0.06) : 0.02;
      const segW: number = width / 24;
      const litSegs: number = Math.round(ratio * 24);
      for (let s = 0; s < 24; s++) {
        if (s >= litSegs) {
          break;
        }
        const r: number = s / 24;
        ctx.fillStyle = r > 0.88 ? Palette.RED : (r > 0.70 ? Palette.GOLD : (active ? colors[4] : Palette.TEXT_FAINT));
        ctx.fillRect(s * segW + 2, y + 3, segW - 4, rowH - 6);
      }
      if (active) {
        ctx.fillStyle = '#FFFFFF';
        ctx.fillRect(Math.min(width - 3, litSegs * segW), y, 3, rowH);
      }
    }
  }
}
