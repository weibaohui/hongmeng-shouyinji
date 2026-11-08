import { rgbToHex, spectrumLutRgb } from '../model/Station';

/**
 * 频谱绘制器：1:1 复刻 E6 版 index.vue 的频谱效果。
 * - 动画：startWaveLoop 同款「多频叠加 + 节拍脉冲」公式，升快(0.65)降慢(0.40)，70ms 一帧；
 * - 配色：16 根柱按柱序号取 16 色 LUT（非按高度），待机色 #2b3e50、未亮点 #161b22；
 * - 几何：9 种样式全部按 E6 的 CSS 布局值（240 宽设计稿，等比缩放居中绘制）。
 *
 * 说明：E6 的「随音乐律动」模式依赖外挂 e6_sound_meter 读取系统 PCM，鸿蒙三方应用
 * 无法捕获播放音频（audio capturer 返回 6800301），因此仅复刻其模拟动画分支；
 * 分贝电平表使用 E6 模拟模式的 simL/simR 公式与峰值保持(0.93)。
 */

const STANDBY: string = '#2b3e50';
const UNLIT: string = '#161b22';
const BAR_COUNT: number = 16;
/** E6 频谱区设计宽度（240px，16 列 × 14px，两侧 8px padding）。 */
const DESIGN_W: number = 240;

export class SpectrumPainter {
  private spec: number[] = [];
  private peak: number[] = [];
  private dbmValL: number = 0;
  private dbmValR: number = 0;
  private dbmPeakL: number = 0;
  private dbmPeakR: number = 0;
  private themeIdx: number = -1;
  /** 当前频谱样式：由页面在切换时显式写入，绘制时不再依赖每帧传入的状态快照。 */
  private styleIdx: number = 0;
  /** 是否使用真实音频分析结果；false 时走原本的模拟动画。 */
  private realMode: boolean = false;
  /** 最近一帧真实频段能量（16 个，0~1）。 */
  private realBands: number[] = [];
  private baseHue: number = 0;
  private lut: string[] = [];
  private lutRgb: number[][] = [];

  constructor() {
    for (let i = 0; i < BAR_COUNT; i++) {
      this.spec.push(0.04);
      this.peak.push(0.04);
    }
    this.buildLut(0);
  }

  /** 切换配色；随机主题时重掷基准色相（对齐 E6 setColorTheme）。 */
  setTheme(theme: number): void {
    this.buildLut(theme);
  }

  /** 切换频谱样式：立即生效，下一帧即按新样式绘制。 */
  setStyle(style: number): void {
    this.styleIdx = style;
  }

  style(): number {
    return this.styleIdx;
  }

  /** 切换数据来源：模拟动画 / 真实音频分析。 */
  setRealMode(on: boolean): void {
    this.realMode = on;
    if (!on) {
      this.realBands = [];
    }
  }

  isRealMode(): boolean {
    return this.realMode;
  }

  /** 写入真实频段能量；长度不足时缺失的频段按静音处理。 */
  setRealBands(bands: number[]): void {
    this.realBands = bands;
  }

  /** 换台时随机主题重掷色相（对齐 E6 playStationObj）。 */
  reseedRandom(): void {
    if (this.themeIdx === 2) {
      this.buildLut(2);
    }
  }

  private buildLut(theme: number): void {
    this.themeIdx = theme;
    if (theme === 2) {
      this.baseHue = Math.floor(Math.random() * 360);
    }
    this.lutRgb = spectrumLutRgb(theme, this.baseHue);
    this.lut = [];
    for (let i = 0; i < this.lutRgb.length; i++) {
      this.lut.push(rgbToHex(this.lutRgb[i]));
    }
  }

  /**
   * 计算下一帧：与 E6 startWaveLoop（70ms 周期）逐参数一致。
   * t = now/140；beat 节拍脉冲、双波叠加、flutter 抖动；升快降慢；峰值独立衰减。
   */
  tick(active: boolean): void {
    const now: number = Date.now();
    const t: number = now / 140;
    const beat: number = Math.sin(t * 1.8) > 0.6 ? 0.24 : 0;
    const next: number[] = [];
    const real: boolean = this.realMode;
    const hasReal: boolean = real && this.realBands.length >= BAR_COUNT;
    for (let i = 0; i < BAR_COUNT; i++) {
      let target: number = 0.04;
      let attack: number = 0.65;
      let release: number = 0.40;
      if (active) {
        if (real) {
          // 真实模式直接映射分析出的频段能量；起落比模拟更快，才能跟上声音
          target = hasReal ? Math.max(0.02, Math.min(1, this.realBands[i])) : 0.04;
          attack = 0.62;
          release = 0.26;
        } else {
          const w1: number = Math.sin(t * 0.85 + i * 0.42);
          const w2: number = Math.cos(t * 1.25 - i * 0.35);
          const flutter: number = Math.sin(now / 70 + i * 1.7) * 0.09;
          target = Math.max(0.06, Math.min(0.92, w1 * 0.28 + w2 * 0.22 + 0.40 + beat + flutter));
        }
      }
      const cur: number = this.spec[i];
      const factor: number = target > cur ? attack : release;
      next.push(cur * (1 - factor) + target * factor);
    }
    this.spec = next;

    // 分贝电平表：真实模式取频段均值，模拟模式沿用 E6 startWaveLoop 的 sim 分支
    if (active) {
      let simL: number = 0;
      let simR: number = 0;
      if (real) {
        let sum: number = 0;
        let low: number = 0;
        let high: number = 0;
        const n: number = this.realBands.length;
        if (n > 0) {
          for (let i = 0; i < n; i++) {
            const v: number = Math.max(0, Math.min(1, this.realBands[i]));
            sum += v;
            if (i < n / 3) {
              low += v;
            } else if (i >= n * 2 / 3) {
              high += v;
            }
          }
          simL = Math.max(0.05, Math.min(1, sum / n * 1.35));
          simR = Math.max(0.05, Math.min(1, (low * 0.6 + high * 0.9) / Math.max(1, n / 3) * 0.85));
        }
      } else {
        simL = Math.max(0.08, Math.min(0.96, 0.46 + Math.sin(t * 0.9) * 0.32 + beat));
        simR = Math.max(0.08, Math.min(0.96, 0.44 + Math.cos(t * 1.1) * 0.32 + beat));
      }
      this.dbmValL = simL;
      this.dbmValR = simR;
      this.dbmPeakL = Math.max(simL, this.dbmPeakL * 0.93);
      this.dbmPeakR = Math.max(simR, this.dbmPeakR * 0.93);
    } else {
      this.dbmValL = 0;
      this.dbmValR = 0;
      this.dbmPeakL = 0;
      this.dbmPeakR = 0;
    }

    // 峰值山峰：peak = max(level, peak*0.88)
    for (let i = 0; i < BAR_COUNT; i++) {
      this.peak[i] = Math.max(next[i], this.peak[i] * 0.88);
    }
  }

  draw(ctx: CanvasRenderingContext2D, width: number, height: number, active: boolean): void {
    if (width <= 0 || height <= 0) {
      return;
    }
    const style: number = this.styleIdx;
    ctx.clearRect(0, 0, width, height);
    let designH: number = 112;
    if (style === 2) {
      designH = 108;
    } else if (style === 5) {
      designH = 160;
    } else if (style === 6) {
      designH = 104;
    }
    // 以 E6 设计稿尺寸等比缩放并居中，保持全部比例与间隙一致
    const scale: number = Math.min(width / DESIGN_W, height / designH);
    ctx.save();
    ctx.translate((width - DESIGN_W * scale) / 2, (height - designH * scale) / 2);
    ctx.scale(scale, scale);
    switch (style) {
      case 1:
        this.drawClassic(ctx, active);
        break;
      case 2:
        this.drawLeds(ctx, active);
        break;
      case 3:
        this.drawPeak(ctx, active);
        break;
      case 4:
        this.drawWaveUp(ctx, active);
        break;
      case 5:
        this.drawRadial(ctx, active);
        break;
      case 6:
        this.drawWaterfall(ctx, active);
        break;
      case 7:
        this.drawParticles(ctx, active);
        break;
      case 8:
        this.drawDbMeter(ctx, active);
        break;
      default:
        this.drawMirror(ctx, active);
        break;
    }
    ctx.restore();
  }

  // ---------- 通用绘制 ----------

  /** 圆角矩形填充，半径顺序：左上/右上/右下/左下。 */
  private fillRR(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number,
                 tl: number, tr: number, br: number, bl: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.beginPath();
    ctx.moveTo(x + tl, y);
    ctx.lineTo(x + w - tr, y);
    ctx.arcTo(x + w, y, x + w, y + tr, tr);
    ctx.lineTo(x + w, y + h - br);
    ctx.arcTo(x + w, y + h, x + w - br, y + h, br);
    ctx.lineTo(x + bl, y + h);
    ctx.arcTo(x, y + h, x, y + h - bl, bl);
    ctx.lineTo(x, y + tl);
    ctx.arcTo(x, y, x + tl, y, tl);
    ctx.closePath();
    ctx.fill();
  }

  /** 圆角矩形描边（E6 CSS 的 border，用自绘路径避免依赖 roundRect API）。 */
  private strokeRR(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number,
                   r: number): void {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.arcTo(x + w, y, x + w, y + r, r);
    ctx.lineTo(x + w, y + h - r);
    ctx.arcTo(x + w, y + h, x + w - r, y + h, r);
    ctx.lineTo(x + r, y + h);
    ctx.arcTo(x, y + h, x, y + h - r, r);
    ctx.lineTo(x, y + r);
    ctx.arcTo(x, y, x + r, y, r);
    ctx.closePath();
    ctx.stroke();
  }

  /** 第 i 列柱的 x（列宽 14，柱宽 9，居中）。 */
  private colX(i: number): number {
    return 8 + i * 14 + 2.5;
  }

  private barColor(i: number, active: boolean): string {
    return active ? this.lut[i] : STANDBY;
  }

  // ---------- 样式 0：双向镜像（specB：上 80px 柱 + 下 32px 镜像） ----------

  private drawMirror(ctx: CanvasRenderingContext2D, active: boolean): void {
    for (let i = 0; i < BAR_COUNT; i++) {
      const v: number = this.spec[i];
      const x: number = this.colX(i);
      const up: number = 4 + Math.round(v * 76);
      ctx.fillStyle = this.barColor(i, active);
      this.fillRR(ctx, x, 80 - up, 9, up, 3, 3, 0, 0);
      const dn: number = 2 + Math.round(v * 30);
      this.fillRR(ctx, x, 80, 9, dn, 0, 0, 2, 2);
    }
  }

  // ---------- 样式 1：经典柱状（specB-classic：112px 区，柱 4+v*104） ----------

  private drawClassic(ctx: CanvasRenderingContext2D, active: boolean): void {
    for (let i = 0; i < BAR_COUNT; i++) {
      const h: number = 4 + Math.round(this.spec[i] * 104);
      ctx.fillStyle = this.barColor(i, active);
      this.fillRR(ctx, this.colX(i), 112 - h, 9, h, 3, 3, 0, 0);
    }
  }

  // ---------- 样式 2：LED点阵（specB-dots：11 段 9×6，space-between 于 108px） ----------

  private drawLeds(ctx: CanvasRenderingContext2D, active: boolean): void {
    const pitch: number = (108 - 6) / 10;
    for (let i = 0; i < BAR_COUNT; i++) {
      const lit: number = Math.round(this.spec[i] * 11);
      for (let s = 0; s <= 10; s++) {
        const on: boolean = s < lit;
        ctx.fillStyle = on ? this.barColor(i, active) : UNLIT;
        // segIdx 顺序 s=10 在顶部，点亮自底向上
        this.fillRR(ctx, this.colX(i), (10 - s) * pitch, 9, 6, 1, 1, 1, 1);
      }
    }
  }

  // ---------- 样式 3：峰值山峰（peakcol：白峰值条 margin=(p-v)*104 悬于柱顶） ----------

  private drawPeak(ctx: CanvasRenderingContext2D, active: boolean): void {
    for (let i = 0; i < BAR_COUNT; i++) {
      const v: number = this.spec[i];
      const h: number = 4 + Math.round(v * 104);
      const gap: number = Math.max(0, Math.round((this.peak[i] - v) * 104));
      ctx.fillStyle = this.barColor(i, active);
      this.fillRR(ctx, this.colX(i), 112 - h, 9, h, 3, 3, 0, 0);
      ctx.fillStyle = active ? '#ffffff' : STANDBY;
      this.fillRR(ctx, this.colX(i), 112 - h - gap - 2, 9, 2, 0, 0, 0, 0);
    }
  }

  // ---------- 样式 4：动感波峰（specB-wave：80px 区柱 4+v*88 圆角4 + 镜像） ----------

  private drawWaveUp(ctx: CanvasRenderingContext2D, active: boolean): void {
    for (let i = 0; i < BAR_COUNT; i++) {
      const v: number = this.spec[i];
      const x: number = this.colX(i);
      const up: number = 4 + Math.round(v * 88);
      ctx.fillStyle = this.barColor(i, active);
      this.fillRR(ctx, x, 80 - up, 9, up, 4, 4, 0, 0);
      const dn: number = 2 + Math.round(v * 30);
      this.fillRR(ctx, x, 80, 9, dn, 0, 0, 2, 2);
    }
  }

  // ---------- 样式 5：环形雷达（specB-radial：160 圆环 r58，16 组竖排 4 点） ----------

  private drawRadial(ctx: CanvasRenderingContext2D, active: boolean): void {
    ctx.fillStyle = UNLIT;
    ctx.beginPath();
    ctx.arc(80, 80, 20, 0, Math.PI * 2);
    ctx.fill();
    for (let i = 0; i < BAR_COUNT; i++) {
      const rad: number = (i / BAR_COUNT) * Math.PI * 2 - Math.PI / 2;
      const px: number = 80 + 58 * Math.cos(rad);
      const py: number = 80 + 58 * Math.sin(rad);
      const lit: number = Math.round(this.spec[i] * 4);
      for (let s = 0; s <= 3; s++) {
        // radialSegIdx [3,2,1,0]：s=3 在顶部，点亮自底向上
        const cy: number = py + (1.5 - s) * 6;
        ctx.fillStyle = s < lit ? this.barColor(i, active) : UNLIT;
        this.fillRR(ctx, px - 2, cy - 2, 4, 4, 2, 2, 2, 2);
      }
    }
  }

  // ---------- 样式 6：瀑布流（specB-fall：4 行 × 4 段 9×9，行亮度 1/0.75/0.5/0.3） ----------

  private drawWaterfall(ctx: CanvasRenderingContext2D, active: boolean): void {
    const dims: number[] = [1, 0.75, 0.5, 0.3];
    const pitch: number = (26 - 9) / 3;
    for (let r = 0; r < 4; r++) {
      for (let i = 0; i < BAR_COUNT; i++) {
        const lit: number = Math.round(this.spec[i] * 4);
        for (let s = 0; s <= 3; s++) {
          const on: boolean = s < lit;
          if (on && active) {
            // E6 fallDotStyle：按行亮度衰减 RGB
            const c: number[] = this.lutRgb[i];
            const dim: number = dims[r];
            ctx.fillStyle = 'rgb(' + Math.round(c[0] * dim).toString() + ',' +
              Math.round(c[1] * dim).toString() + ',' + Math.round(c[2] * dim).toString() + ')';
          } else if (on) {
            ctx.fillStyle = STANDBY;
          } else {
            ctx.fillStyle = UNLIT;
          }
          // fallSegIdx [3,2,1,0]：s=3 在顶部，space-between 间距 5.67
          this.fillRR(ctx, this.colX(i), r * 26 + (3 - s) * pitch, 9, 9, 2, 2, 2, 2);
        }
      }
    }
  }

  // ---------- 样式 7：粒子散落（partcol：4 点竖排（含 3px 间隔）悬于经典柱顶） ----------

  private drawParticles(ctx: CanvasRenderingContext2D, active: boolean): void {
    for (let i = 0; i < BAR_COUNT; i++) {
      const v: number = this.spec[i];
      const h: number = 4 + Math.round(v * 104);
      const lit: number = Math.round(v * 4);
      const dotX: number = 8 + i * 14 + 5;
      ctx.fillStyle = this.barColor(i, active);
      this.fillRR(ctx, this.colX(i), 112 - h, 9, h, 3, 3, 0, 0);
      for (let s = 0; s <= 3; s++) {
        ctx.fillStyle = s < lit ? this.barColor(i, active) : UNLIT;
        // 点栈（每点占 4+3=7px）整体贴住柱顶；s=3 在顶部
        this.fillRR(ctx, dotX, 112 - h - 28 + (3 - s) * 7, 4, 4, 2, 2, 2, 2);
      }
    }
  }

  // ---------- 样式 8：分贝电平（dbm-card：刻度 + 双声道绿黄红 + 白峰值线） ----------

  private drawDbMeter(ctx: CanvasRenderingContext2D, active: boolean): void {
    const cardX: number = 12;
    const cardY: number = 18;
    const cardW: number = 216;
    const cardH: number = 75;
    // 卡片
    ctx.fillStyle = '#11141a';
    this.fillRR(ctx, cardX, cardY, cardW, cardH, 10, 10, 10, 10);
    ctx.lineWidth = 1;
    ctx.strokeStyle = '#21262d';
    this.strokeRR(ctx, cardX, cardY, cardW, cardH, 10);
    const ix: number = cardX + 8;
    const iw: number = 200;
    // 刻度文字：-60/-36/-24/-18/-12/-6/0（0 红色加粗，位置取自 dbmMarks）
    ctx.font = '8px sans-serif';
    ctx.textBaseline = 'top';
    ctx.textAlign = 'left';
    ctx.fillStyle = '#8b949e';
    const marksX: number[] = [0, 40, 82, 120, 154, 178];
    const labels: string[] = ['-60', '-36', '-24', '-18', '-12', '-6'];
    for (let m = 0; m < labels.length; m++) {
      ctx.fillText(labels[m], ix + marksX[m], cardY + 6);
    }
    ctx.font = '8px sans-serif';
    ctx.textAlign = 'right';
    ctx.fillStyle = '#da3633';
    ctx.fillText('0', ix + iw - 2, cardY + 6);
    // 刻度线
    const tickY: number = cardY + 21;
    const tickXs: number[] = [7, 48, 90, 128, 162, 184];
    ctx.fillStyle = '#30363d';
    for (let m = 0; m < tickXs.length; m++) {
      ctx.fillRect(ix + tickXs[m], tickY, 1, 5);
    }
    ctx.fillStyle = '#da3633';
    ctx.fillRect(ix + iw - 5, tickY, 1, 5);
    // 电平条区域（200×22 圆角 4，内边 2）
    const wrapY: number = cardY + 29;
    ctx.fillStyle = '#0b0e14';
    this.fillRR(ctx, ix, wrapY, iw, 22, 4, 4, 4, 4);
    ctx.strokeStyle = '#30363d';
    this.strokeRR(ctx, ix, wrapY, iw, 22, 4);
    const secW: number[] = [132, 34, 28];
    const dark: string[] = ['#0a2712', '#332400', '#3b0d0e'];
    const litC: string[] = ['#238636', '#d29922', '#f85149'];
    const chY: number[] = [wrapY + 2, wrapY + 13];
    for (let ch = 0; ch < 2; ch++) {
      const val: number = ch === 0 ? this.dbmValL : this.dbmValR;
      const pk: number = ch === 0 ? this.dbmPeakL : this.dbmPeakR;
      const y: number = chY[ch];
      // 暗色轨道（通道底 #161b22 + 三段暗绿/暗黄/暗红）
      ctx.fillStyle = '#161b22';
      this.fillRR(ctx, ix, y, 194, 7, 2, 2, 2, 2);
      let sx: number = ix;
      for (let s = 0; s < 3; s++) {
        ctx.fillStyle = dark[s];
        ctx.fillRect(sx, y, secW[s], 7);
        sx += secW[s];
      }
      // 亮色填充：宽度 = max(2, round(v*100))% × 194（对齐 E6 getDbmFill）
      const clipW: number = Math.min(194, Math.max(2, Math.round(val * 100)) * 1.94);
      sx = ix;
      for (let s = 0; s < 3; s++) {
        const left: number = Math.max(ix, Math.min(ix + clipW, sx));
        const right: number = Math.max(ix, Math.min(ix + clipW, sx + secW[s]));
        if (right > left) {
          ctx.fillStyle = litC[s];
          ctx.fillRect(left, y, right - left, 7);
        }
        sx += secW[s];
      }
      // 白色峰值保持线（getDbmPeak：left=clamp(round(p*198),0,194)）
      if (active && pk > 0.05) {
        const px: number = ix + Math.max(0, Math.min(194, Math.round(pk * 198)));
        ctx.fillStyle = '#ffffff';
        this.fillRR(ctx, px, y, 2, 7, 1, 1, 1, 1);
      }
    }
    // 底部标签
    ctx.font = '8px sans-serif';
    ctx.textBaseline = 'top';
    ctx.textAlign = 'left';
    ctx.fillStyle = '#484f58';
    ctx.fillText('CH 1/2 · L/R', ix, cardY + 56);
    ctx.textAlign = 'right';
    ctx.fillStyle = '#79c0ff';
    ctx.fillText('dBFS PEAK', ix + iw, cardY + 56);
  }
}
