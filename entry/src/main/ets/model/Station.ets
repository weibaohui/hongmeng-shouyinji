/** 一个网络电台。字段与 E6 版 radio.db 的 stations 表一一对应。 */
export interface Station {
  id: number;
  name: string;
  url: string;
  province: string;
  city: string;
  genre: string;
  country: string;
  countryCode: string;
}

/** 列表范围：全部 / 最近播放 / 收藏 / 国内 / 国际。 */
export enum Scope {
  All = 0,
  Recent = 1,
  Favorite = 2,
  Domestic = 3,
  International = 4
}

export const SCOPE_NAMES: string[] = ['全部电台', '最近播放', '我的收藏', '国内电台', '国际电台'];

/**
 * 频谱可视化样式，与 E6 版 index.vue 的 vizStyle 0-8 一一对应。
 * 双向镜像 / 经典柱状 / LED点阵 / 峰值山峰 / 动感波峰 / 环形雷达 / 瀑布流 / 粒子散落 / 分贝电平
 */
export enum VizStyle {
  Mirror = 0,
  Classic = 1,
  Leds = 2,
  Peak = 3,
  WaveUp = 4,
  Radial = 5,
  Waterfall = 6,
  Particles = 7,
  DbMeter = 8
}

export const VIZ_NAMES: string[] =
  ['双向镜像', '经典柱状', 'LED点阵', '峰值山峰', '动感波峰', '环形雷达', '瀑布流', '粒子散落', '分贝电平'];

export const THEME_NAMES: string[] = ['彩色', '灰白', '随机', '赛博', '琥珀'];

export const SLEEP_OPTIONS: number[] = [0, 15, 30, 60, 90];

/** 深色主题色板，沿用 E6 版 GitHub Dark 的观感并针对大屏调整层级。 */
export class Palette {
  static readonly BG: string = '#0B1017';
  static readonly SURFACE: string = '#111925';
  static readonly SURFACE_2: string = '#172231';
  static readonly CARD: string = '#1B2839';
  static readonly BORDER: string = '#26354A';
  static readonly TEXT: string = '#E8EFF8';
  static readonly TEXT_DIM: string = '#8FA2B8';
  static readonly TEXT_FAINT: string = '#5B6B80';
  static readonly BLUE: string = '#4C9AFF';
  static readonly GREEN: string = '#3DDC84';
  static readonly GOLD: string = '#F5C24B';
  static readonly RED: string = '#F2637B';
}

/**
 * 配色 LUT：与 E6 版 applyColorLut 逐字节一致，16 根柱各取一色（按柱序号而非高度）。
 * rainbow: 色相 210 + k*20 的 HSV 环；mono: 180→245 灰阶；random: 基准色相 + k*137.5；
 * cyber: 绿→红渐变；amber: 琥珀衰减。
 */
const HSV_S: number = 0.85;
const HSV_V: number = 0.95;

function hsvToRgb(h: number, s: number, v: number): number[] {
  const c: number = v * (1 - s);
  const f: number = h / 60 % 1;
  const x: number = v * (1 - s * f);
  const y: number = v * (1 - s * (1 - f));
  const sector: number = Math.floor(h / 60) % 6;
  if (sector === 0) {
    return [v, y, c];
  } else if (sector === 1) {
    return [x, v, c];
  } else if (sector === 2) {
    return [c, v, y];
  } else if (sector === 3) {
    return [c, x, v];
  } else if (sector === 4) {
    return [y, c, v];
  }
  return [v, c, x];
}

function toHex(n: number): string {
  const v: number = Math.max(0, Math.min(255, Math.round(n)));
  const h: string = v.toString(16);
  return h.length < 2 ? '0' + h : h;
}

function rgbStr(rgb: number[]): string {
  return '#' + toHex(rgb[0]) + toHex(rgb[1]) + toHex(rgb[2]);
}

/** 生成 16 色 LUT（E6 版同款），统一 0-255 数值约定。random 主题的 baseHue 由调用方传入以支持换台重掷。 */
export function spectrumLutRgb(theme: number, baseHue: number): number[][] {
  const lut: number[][] = [];
  for (let k = 0; k < 16; k++) {
    const t: number = k / 15;
    if (theme === 1) {
      const g: number = Math.round(180 + t * 65);
      lut.push([g, g, g]);
    } else if (theme === 2) {
      const c: number[] = hsvToRgb((baseHue + k * 137.5) % 360, HSV_S, HSV_V);
      lut.push([Math.round(c[0] * 255), Math.round(c[1] * 255), Math.round(c[2] * 255)]);
    } else if (theme === 3) {
      lut.push([Math.round(t * 224), Math.round(229 - t * 165), Math.round(255 - t * 4)]);
    } else if (theme === 4) {
      lut.push([255, Math.round(200 - t * 90), Math.round(50 - t * 30)]);
    } else {
      const c: number[] = hsvToRgb((210 + k * 20) % 360, HSV_S, HSV_V);
      lut.push([Math.round(c[0] * 255), Math.round(c[1] * 255), Math.round(c[2] * 255)]);
    }
  }
  return lut;
}

export function rgbToHex(rgb: number[]): string {
  return rgbStr(rgb);
}

/** 设置面板主题色带预览：16 色中均匀取 6 个采样。 */
export function themeColors(theme: number): string[] {
  const lut: number[][] = spectrumLutRgb(theme, 0);
  const picks: number[] = [0, 3, 6, 9, 12, 15];
  const out: string[] = [];
  for (let i = 0; i < picks.length; i++) {
    out.push(rgbStr(lut[picks[i]]));
  }
  return out;
}
