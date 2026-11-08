import spectrum from 'libspectrum.so';

/** 与原生模块 StatusCode 对齐：正数为运行态，负数为失败原因。 */
export const ANALYSIS_IDLE: number = 0;
export const ANALYSIS_STARTING: number = 1;
export const ANALYSIS_RUNNING: number = 2;

/**
 * 实时频谱分析：把电台音频流交给原生模块解封装 + 解码，再算 16 个频段能量。
 * 全程不采集麦克风，纯靠拉流 + 系统解码器，因此只有在本机播放的电台才有数据。
 */
export class SpectrumAnalyzer {
  private url: string = '';
  private active: boolean = false;
  private cachedBands: number[] = [];

  /** 启动分析；同一个地址重复调用不会重复开流。返回原生状态码。 */
  start(url: string): number {
    if (url.length === 0) {
      return -2;
    }
    if (this.active && this.url === url) {
      return spectrum.status() as number;
    }
    this.stop();
    this.url = url;
    this.active = true;
    this.cachedBands = [];
    return spectrum.start(url) as number;
  }

  stop(): void {
    if (this.active) {
      spectrum.stop();
    }
    this.active = false;
    this.url = '';
    this.cachedBands = [];
  }

  isActive(): boolean {
    return this.active;
  }

  currentUrl(): string {
    return this.url;
  }

  status(): number {
    return this.active ? spectrum.status() as number : ANALYSIS_IDLE;
  }

  message(): string {
    return this.active ? spectrum.message() as string : '';
  }

  /** 数据版本号：每产出一帧新频段自增，用来判断画面是否还在更新。 */
  seq(): number {
    return this.active ? spectrum.seq() as number : 0;
  }

  /** 取最近一次频段能量；没有新数据时沿用上一次，避免闪烁。 */
  bands(): number[] {
    if (!this.active) {
      return [];
    }
    const data: number[] = spectrum.bands() as number[];
    if (data.length > 0) {
      this.cachedBands = data;
    }
    return this.cachedBands;
  }
}
