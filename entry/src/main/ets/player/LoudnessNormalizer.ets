/**
 * 音量归一化：让不同电台的响度接近一致。
 *
 * 网络电台的推流响度差别很大——有的台压得很狠（接近削峰），有的台送出来就是轻的，
 * 换台时忽大忽小非常刺耳。传统做法是人工给每台挂一个补偿值，
 * 这里改成自动测量：用真实音频解析拿到流里的 PCM，算出这一拍的节目电平（dBFS），
 * 攒够一段时间后取一个稳健的统计量，再和目标电平相减，得到这一台该补多少 dB。
 *
 * 关键取舍：
 * - 用 RMS 而不是峰值。峰值会被鼓点、瞬态拉满，RMS 才反映"这一台整体有多响"。
 * - 用分位数而不是平均值。台与台之间、或同一台的不同时段之间差异很大，
 *   取偏高的分位数代表"它响的时候有多响"，静音段不会把结果拉下来。
 * - 只在样本足够且变化足够大时才更新，避免刚播几秒就用一个半成品数值去改增益。
 *
 * 修正增益最终并进播放器的 setLoudnessGain 链路，与听感预设、用户微调叠加生效。
 */

/** 目标节目电平（dBFS，RMS）。广播类节目压到这个量级听感上比较统一。 */
const TARGET_DB: number = -17.0;
/** 单台允许的最大修正量（dB）。超出这个范围多半是测量出了问题，宁可不动。 */
const MAX_GAIN_DB: number = 9.0;
/** 采样窗口长度（帧）。一帧约 70ms，600 帧约 42 秒。 */
const WINDOW_FRAMES: number = 600;
/** 攒够多少帧才算「测够了」（约 7 秒）。 */
const MIN_FRAMES: number = 100;
/** 低于这个电平认为是静音/间隙，不计入统计。 */
const SILENCE_DB: number = -55.0;
/** 取第几分位作为这一台的代表电平。 */
const PERCENTILE: number = 0.75;
/** 新的测量值与已生效值差多少 dB 才值得改（0.5dB 以内视为抖动，忽略）。 */
const APPLY_EPSILON: number = 0.5;

export class LoudnessNormalizer {
  private samples: number[] = [];
  private startedAt: number = 0;

  /** 换台或重新起流时调用：丢掉上一台的样本，重新测。 */
  reset(): void {
    this.samples = [];
    this.startedAt = Date.now();
  }

  /** 喂入一帧电平。静音段不计入：节目间隙、空档会把统计量拉低。 */
  feed(db: number): void {
    if (this.startedAt === 0) {
      this.startedAt = Date.now();
    }
    if (db <= SILENCE_DB || db <= -119.0) {
      return;
    }
    this.samples.push(db);
    if (this.samples.length > WINDOW_FRAMES) {
      this.samples.shift();
    }
  }

  /** 样本是否已经攒够，可以给出结论。 */
  ready(): boolean {
    return this.samples.length >= MIN_FRAMES;
  }

  /**
   * 算出这一台应该补多少 dB。
   * 没测够时返回 null；测出来的修正量超过上限时也返回 null（多半是异常流）。
   */
  measuredGain(): number | null {
    if (!this.ready()) {
      return null;
    }
    const sorted: number[] = this.samples.slice().sort((a: number, b: number): number => a - b);
    const at: number = Math.min(sorted.length - 1, Math.floor(sorted.length * PERCENTILE));
    const measured: number = sorted[at];
    const raw: number = TARGET_DB - measured;
    if (raw > MAX_GAIN_DB || raw < -MAX_GAIN_DB) {
      return null;
    }
    // 取到 0.5dB 一档：太细的数值既没有听感意义，又会让增益值不停抖动。
    return Math.round(raw * 2) / 2;
  }

  /**
   * 只有当新测出来的值和当前生效值差得够多时才返回新值，否则返回 null。
   * 这样调用方不用自己做抖动判断。
   */
  nextGain(current: number): number | null {
    const g: number | null = this.measuredGain();
    if (g === null) {
      return null;
    }
    if (Math.abs(g - current) < APPLY_EPSILON) {
      return null;
    }
    return g;
  }

  /** 已收集的有效样本数。 */
  sampleCount(): number {
    return this.samples.length;
  }

  /** 测量进度 0~1，用于设置页里的进度提示。 */
  progress(): number {
    return Math.min(1, this.samples.length / MIN_FRAMES);
  }
}
