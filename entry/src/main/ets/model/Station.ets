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

/** 列表范围：全部 / 收藏 / 国内 / 国际。 */
export enum Scope {
  All = 0,
  Favorite = 1,
  Domestic = 2,
  International = 3
}

export const SCOPE_NAMES: string[] = ['全部电台', '我的收藏', '国内电台', '国际电台'];

/** 频谱可视化样式。 */
export enum VizStyle {
  Bars = 0,
  Leds = 1,
  Wave = 2,
  Meter = 3
}

export const VIZ_NAMES: string[] = ['频谱柱', 'LED 点阵', '声波', '电平表'];

export const THEME_NAMES: string[] = ['彩虹', '灰白', '赛博', '琥珀'];

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

/** 每套配色给出 6 个由低到高的色谱，供柱形/点阵/声波渐变取色。 */
export function themeColors(theme: number): string[] {
  switch (theme) {
    case 1:
      return ['#4A5B70', '#6B7F97', '#93A6BC', '#B6C6D8', '#D6E2EF', '#FFFFFF'];
    case 2:
      return ['#164E63', '#0E7490', '#0891B2', '#22D3EE', '#67E8F9', '#A5F3FC'];
    case 3:
      return ['#7C3A10', '#B45309', '#D97706', '#F59E0B', '#FBBF24', '#FDE68A'];
    default:
      return ['#3B5BDB', '#7048E8', '#C7409B', '#F03E63', '#F59F00', '#37B24D'];
  }
}
