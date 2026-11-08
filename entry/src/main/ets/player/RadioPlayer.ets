import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

export enum PlayState {
  Idle = 0,
  Loading = 1,
  Playing = 2,
  Paused = 3,
  Error = 4,
  Stopped = 5
}

const TAG: string = 'RadioPlayer';
const DOMAIN: number = 0x3200;

/**
 * 听感预设：全部由设备端能力实现，不需要云端接口，也不需要自行解码 PCM。
 * - usage 决定系统音效链路（音乐／影院／有声书／游戏），是唯一能改变「音色」的维度；
 * - gainDb 走 AVPlayer.setLoudnessGain，直接决定响度，档位之间刻意拉开 18dB；
 * - curve 把线性滑杆换算成不同的音量手感，trim 是防削峰余量，fadeIn 影响入声的缓急；
 * - effect 控制系统音效引擎（EFFECT_DEFAULT / EFFECT_NONE）是否介入。
 */
export interface SoundProfile {
  name: string;
  hint: string;
  usage: audio.StreamUsage;
  gainDb: number;
  curve: number;
  trim: number;
  fadeIn: number;
  effect: boolean;
}

const SOUND_PROFILES: SoundProfile[] = [
  { name: '原声', hint: '标准 · 0dB · 420ms', usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
    gainDb: 0, curve: 1.0, trim: 0.95, fadeIn: 420, effect: true },
  { name: '纯音', hint: '关闭系统音效 · 0dB', usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
    gainDb: 0, curve: 1.0, trim: 0.95, fadeIn: 300, effect: false },
  { name: '新闻', hint: '人声链路 · +4dB', usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
    gainDb: 4, curve: 1.0, trim: 0.62, fadeIn: 360, effect: true },
  { name: '人声', hint: '人声链路 · +1dB · 缓入', usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
    gainDb: 1, curve: 1.2, trim: 0.82, fadeIn: 520, effect: true },
  { name: '音乐', hint: '音乐链路 · +3dB', usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
    gainDb: 3, curve: 1.0, trim: 0.70, fadeIn: 440, effect: true },
  { name: '醇厚', hint: '音乐链路 · +6dB · 强增益', usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
    gainDb: 6, curve: 0.85, trim: 0.52, fadeIn: 380, effect: true },
  { name: '影院', hint: '影院链路 · +2dB', usage: audio.StreamUsage.STREAM_USAGE_MOVIE,
    gainDb: 2, curve: 1.0, trim: 0.78, fadeIn: 620, effect: true },
  { name: '环绕', hint: '影院链路 · +5dB · 长渐入', usage: audio.StreamUsage.STREAM_USAGE_MOVIE,
    gainDb: 5, curve: 0.95, trim: 0.58, fadeIn: 720, effect: true },
  { name: '游戏', hint: '低延迟链路 · 快入', usage: audio.StreamUsage.STREAM_USAGE_GAME,
    gainDb: 1, curve: 1.0, trim: 0.86, fadeIn: 240, effect: false },
  { name: '收音机', hint: '温和 · -5dB · 柔曲线', usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
    gainDb: -5, curve: 1.45, trim: 0.92, fadeIn: 680, effect: false },
  { name: '夜间', hint: '轻音 · -9dB · 慢入', usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
    gainDb: -9, curve: 1.9, trim: 1.0, fadeIn: 900, effect: true },
  { name: '轻语', hint: '极轻 · -12dB', usage: audio.StreamUsage.STREAM_USAGE_AUDIOBOOK,
    gainDb: -12, curve: 2.2, trim: 1.0, fadeIn: 1000, effect: false }
];

export const SOUND_NAMES: string[] = SOUND_PROFILES.map((p: SoundProfile): string => p.name);
export const SOUND_HINTS: string[] = SOUND_PROFILES.map((p: SoundProfile): string => p.hint);
export const SOUND_EFFECTS: boolean[] = SOUND_PROFILES.map((p: SoundProfile): boolean => p.effect);
export const FADE_NAMES: string[] = ['关闭', '短', '标准', '舒缓'];

const FADE_SCALES: number[] = [0, 0.5, 1, 1.8];

/**
 * 基于 AVPlayer 的网络电台播放器。
 * 状态机：idle -> initialized -> prepared -> playing，切台时 reset 后重新 set url。
 * 所有音量变化都经过渐变引擎：切台先淡出、新台从 0 淡入，避免流切换瞬间的电平跳变爆音。
 */
export class RadioPlayer {
  private player: media.AVPlayer | null = null;
  private avState: string = 'idle';
  /** 用户设定的音量，0-100。实际送给 AVPlayer 的电平由 steadyLevel() 换算。 */
  private volume: number = 60;
  /** 当前实际生效的电平，0-1。 */
  private level: number = 0;
  private currentUrl: string = '';
  private protocolRetried: boolean = false;
  private profileIndex: number = 0;
  private fadeIndex: number = 2;
  private systemEffect: boolean = true;
  /** 用户在预设之上叠加的响度微调与柔和度；0 表示跟随预设。 */
  private userGainDb: number = 0;
  private userCurve: number = 0;
  /** 当前播放器实际设置的 usage，用于判断切换预设是否需要重连。 */
  private appliedUsage: number = -1;
  private fadeTimer: number = -1;
  private fadeResolve: (() => void) | null = null;
  private switchToken: number = 0;
  private toggleToken: number = 0;
  private pausePending: boolean = false;

  onState: (state: PlayState, message: string) => void = () => {
  };

  async ensure(): Promise<void> {
    if (this.player !== null) {
      return;
    }
    try {
      const p: media.AVPlayer = await media.createAVPlayer();
      this.player = p;
      this.avState = 'idle';
      p.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason) => {
        this.avState = state;
        this.handleState(p, state);
      });
      p.on('error', (err: BusinessError) => {
        this.avState = 'error';
        const alt: string = this.alternateUrl(this.currentUrl);
        if (!this.protocolRetried && alt.length > 0) {
          // 明文 HTTP 被系统拦截、或 HTTPS 证书异常时，自动切到另一协议重试一次
          this.protocolRetried = true;
          this.onState(PlayState.Loading, '正在尝试备用线路…');
          setTimeout(() => {
            this.restartWith(alt).catch(() => {
              this.onState(PlayState.Error, '备用线路连接失败');
            });
          }, 120);
          return;
        }
        const detail: string = err.message ?? '';
        this.onState(PlayState.Error, '无法收听：' + (detail.length > 0 ? detail : '直播流不可用'));
      });
    } catch (e) {
      this.player = null;
      this.onState(PlayState.Error, '播放器初始化失败');
    }
  }

  private handleState(p: media.AVPlayer, state: media.AVPlayerState): void {
    switch (state) {
      case 'initialized':
        // audioRendererInfo 只能在 initialized 且首次 prepare 之前设置，决定系统音效链路。
        try {
          const usage: audio.StreamUsage = this.profile().usage;
          p.audioRendererInfo = { usage: usage, rendererFlags: 0 };
          this.appliedUsage = usage;
        } catch (e) {
          // 个别版本不支持该属性时沿用系统默认值，不影响播放
        }
        p.prepare().catch(() => {
          this.onState(PlayState.Error, '缓冲失败，请换一个电台');
        });
        break;
      case 'prepared':
        this.applyRendererSettings(p);
        this.rawVolume(0);
        p.play().catch(() => {
          this.onState(PlayState.Error, '播放启动失败');
        });
        this.onState(PlayState.Playing, '正在播放');
        this.fadeTo(this.steadyLevel(), this.fadeInMs());
        break;
      case 'playing':
        this.onState(PlayState.Playing, '正在播放');
        break;
      case 'paused':
        this.onState(PlayState.Paused, '已暂停');
        break;
      case 'stopped':
        this.onState(PlayState.Stopped, '已停止');
        break;
      case 'completed':
        this.onState(PlayState.Error, '直播流已结束');
        break;
      case 'error':
        this.onState(PlayState.Error, '播放出错，请重试或换台');
        break;
      default:
        break;
    }
  }

  // ============================== 渐变引擎 ==============================

  private profile(): SoundProfile {
    const i: number = this.profileIndex;
    return SOUND_PROFILES[i >= 0 && i < SOUND_PROFILES.length ? i : 0];
  }

  private gainDb(): number {
    return Math.max(-24, Math.min(12, this.profile().gainDb + this.userGainDb));
  }

  private curve(): number {
    return this.userCurve > 0 ? this.userCurve : this.profile().curve;
  }

  /** 稳态电平：感知曲线 + 防削峰余量。响度增益由系统侧叠加，不在这里抵消。 */
  private steadyLevel(): number {
    const x: number = Math.max(0, Math.min(1, this.volume / 100));
    return Math.max(0, Math.min(1, Math.pow(x, this.curve()) * this.profile().trim));
  }

  private fadeInMs(): number {
    const i: number = this.fadeIndex;
    const scale: number = (i >= 0 && i < FADE_SCALES.length) ? FADE_SCALES[i] : 1;
    return scale <= 0 ? 0 : Math.round(this.profile().fadeIn * scale);
  }

  private fadeOutMs(): number {
    const ms: number = this.fadeInMs();
    return ms <= 0 ? 0 : Math.max(90, Math.round(ms * 0.55));
  }

  /** 结束当前渐变；被取消的渐变也会 resolve，由调用方用 switchToken 判断是否继续。 */
  private finishFade(): void {
    if (this.fadeTimer >= 0) {
      clearInterval(this.fadeTimer);
      this.fadeTimer = -1;
    }
    const done: (() => void) | null = this.fadeResolve;
    this.fadeResolve = null;
    if (done !== null) {
      done();
    }
  }

  private rawVolume(v: number): void {
    this.level = Math.max(0, Math.min(1, v));
    const p: media.AVPlayer | null = this.player;
    if (p !== null && this.avState !== 'idle' && this.avState !== 'released') {
      try {
        p.setVolume(this.level);
      } catch (e) {
        // 状态切换瞬间可能不允许设置音量，下一次状态回调会重新同步
      }
    }
  }

  /** smoothstep 渐变，40ms 一档；duration 为 0 时立即到位。 */
  private fadeTo(to: number, duration: number): Promise<void> {
    const target: number = Math.max(0, Math.min(1, to));
    this.finishFade();
    if (duration <= 0 || this.player === null || Math.abs(this.level - target) < 0.004) {
      this.rawVolume(target);
      return Promise.resolve();
    }
    const from: number = this.level;
    const stepMs: number = 40;
    const steps: number = Math.max(1, Math.ceil(duration / stepMs));
    let count: number = 0;
    return new Promise<void>((resolve: () => void): void => {
      this.fadeResolve = resolve;
      this.fadeTimer = setInterval((): void => {
        count += 1;
        const t: number = Math.min(1, count / steps);
        const eased: number = t * t * (3 - 2 * t);
        this.rawVolume(from + (target - from) * eased);
        if (count >= steps) {
          this.finishFade();
        }
      }, stepMs);
    });
  }

  private applyRendererSettings(p: media.AVPlayer): void {
    try {
      p.audioEffectMode = this.systemEffect
        ? audio.AudioEffectMode.EFFECT_DEFAULT
        : audio.AudioEffectMode.EFFECT_NONE;
    } catch (e) {
      // 设备不支持时保持系统默认
    }
    const db: number = this.gainDb();
    try {
      // API 21+ 的响度增益；老设备会 reject，静默降级为纯音量曲线。
      p.setLoudnessGain(db).then((): void => {
        hilog.info(DOMAIN, TAG, 'loudness %{public}d dB applied', db);
      }).catch((err: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'loudness unsupported: %{public}d', err.code);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'loudness call failed');
    }
  }

  private applyLiveSettings(): void {
    const p: media.AVPlayer | null = this.player;
    const ready: boolean = this.avState === 'prepared' || this.avState === 'playing' ||
      this.avState === 'paused' || this.avState === 'completed';
    if (p !== null && ready) {
      this.applyRendererSettings(p);
    }
    this.fadeTo(this.steadyLevel(), 120);
  }

  // ============================== 播放控制 ==============================

  /** 播放某个流地址：先把旧台淡出到静音，再 reset 换流，新台 prepared 后自动淡入。 */
  async play(url: string): Promise<void> {
    this.protocolRetried = false;
    const token: number = ++this.switchToken;
    this.toggleToken += 1;
    this.pausePending = false;
    if (this.avState === 'playing') {
      await this.fadeTo(0, this.fadeOutMs());
      if (token !== this.switchToken) {
        return;
      }
    } else {
      this.finishFade();
      this.rawVolume(0);
    }
    await this.playOnce(url, false);
  }

  private alternateUrl(url: string): string {
    if (url.startsWith('http://')) {
      return 'https://' + url.substring(7);
    }
    if (url.startsWith('https://')) {
      return 'http://' + url.substring(8);
    }
    return '';
  }

  /** 协议 / 音效场景切换：彻底释放旧实例，确保新的 audioRendererInfo 生效。 */
  private async restartWith(url: string): Promise<void> {
    this.finishFade();
    const p: media.AVPlayer | null = this.player;
    if (p !== null) {
      try {
        p.release();
      } catch (e) {
        // ignore
      }
    }
    this.player = null;
    this.avState = 'idle';
    this.level = 0;
    this.appliedUsage = -1;
    await this.playOnce(url, false);
  }

  private async playOnce(url: string, retried: boolean): Promise<void> {
    await this.ensure();
    const p: media.AVPlayer | null = this.player;
    if (p === null) {
      return;
    }
    this.currentUrl = url;
    this.onState(PlayState.Loading, '正在连接电台…');
    try {
      if (this.avState !== 'idle') {
        await p.reset();
        this.avState = 'idle';
      }
      p.url = url;
    } catch (e) {
      if (retried) {
        this.onState(PlayState.Error, '播放器异常，请重新点选电台');
        return;
      }
      try {
        p.release();
      } catch (e2) {
        // ignore
      }
      this.player = null;
      this.avState = 'idle';
      await this.playOnce(url, true);
    }
  }

  /** 播放/暂停切换：无正在播放的电台时返回 false，由调用方决定开始播放。 */
  toggle(): boolean {
    const p: media.AVPlayer | null = this.player;
    if (p === null) {
      return false;
    }
    if (this.pausePending) {
      return true;
    }
    if (this.avState === 'playing') {
      const dur: number = this.fadeOutMs();
      if (dur <= 0) {
        this.finishFade();
        try {
          p.pause();
        } catch (e) {
          // ignore
        }
        this.rawVolume(0);
        return true;
      }
      this.pausePending = true;
      const t: number = ++this.toggleToken;
      this.fadeTo(0, dur).then((): void => {
        // 淡出期间用户又切了台 / 选了音效，就不要再把新流暂停掉
        if (t !== this.toggleToken) {
          return;
        }
        this.pausePending = false;
        if (this.avState === 'playing') {
          try {
            p.pause();
          } catch (e) {
            // ignore
          }
        }
        this.rawVolume(0);
      });
      return true;
    }
    if (this.avState === 'paused') {
      this.rawVolume(0);
      try {
        p.play();
      } catch (e) {
        return false;
      }
      this.fadeTo(this.steadyLevel(), this.fadeInMs());
      return true;
    }
    return false;
  }

  stop(): void {
    this.toggleToken += 1;
    const p: media.AVPlayer | null = this.player;
    const audible: boolean = this.avState === 'playing' || this.avState === 'paused' || this.avState === 'prepared';
    if (p !== null && audible) {
      const dur: number = this.avState === 'playing' ? this.fadeOutMs() : 0;
      if (dur > 0) {
        this.fadeTo(0, dur).then((): void => {
          try {
            p.stop();
          } catch (e) {
            // ignore
          }
        });
      } else {
        this.finishFade();
        this.rawVolume(0);
        try {
          p.stop();
        } catch (e) {
          // 状态已变化，忽略
        }
      }
    } else {
      this.finishFade();
      this.rawVolume(0);
    }
    this.onState(PlayState.Stopped, '已停止');
  }

  /** UI 音量 0-100；拖动时也走 90ms 短渐变，避免电平阶跃产生咔哒声。 */
  setVolume(level: number): void {
    this.volume = Math.max(0, Math.min(100, level));
    const to: number = this.steadyLevel();
    if (this.avState === 'playing') {
      this.fadeTo(to, this.fadeInMs() > 0 ? 90 : 0);
    } else {
      this.finishFade();
      this.rawVolume(to);
    }
  }

  // ============================== 音效 ==============================

  /**
   * 切换听感预设。只有系统音效场景（usage）变化才需要重建播放器——那种情况下先淡出
   * 再重连当前流；其余参数（增益、曲线、系统音效开关）即时生效，切换无中断。
   */
  setSoundProfile(index: number): void {
    this.profileIndex = Math.max(0, Math.min(SOUND_PROFILES.length - 1, Math.round(index)));
    const next: SoundProfile = this.profile();
    this.systemEffect = next.effect;
    const p: media.AVPlayer | null = this.player;
    const ready: boolean = this.avState === 'prepared' || this.avState === 'playing' || this.avState === 'paused';
    if (p !== null && ready) {
      this.applyRendererSettings(p);
    }
    const url: string = this.currentUrl;
    const rebuild: boolean = this.appliedUsage >= 0 && this.appliedUsage !== next.usage;
    if (url.length > 0 && rebuild && this.avState === 'playing') {
      const token: number = ++this.switchToken;
      this.toggleToken += 1;
      this.pausePending = false;
      this.fadeTo(0, this.fadeOutMs()).then((): void => {
        if (token !== this.switchToken) {
          return;
        }
        this.restartWith(url).catch(() => {
        });
      });
    } else {
      this.fadeTo(this.steadyLevel(), 140);
    }
  }

  /** 系统音效引擎（EFFECT_DEFAULT / EFFECT_NONE），可即时切换，无需重连。 */
  setSystemEffect(on: boolean): void {
    this.systemEffect = on;
    const p: media.AVPlayer | null = this.player;
    const ready: boolean = this.avState === 'prepared' || this.avState === 'playing' ||
      this.avState === 'paused' || this.avState === 'completed';
    if (p !== null && ready) {
      try {
        p.audioEffectMode = on ? audio.AudioEffectMode.EFFECT_DEFAULT : audio.AudioEffectMode.EFFECT_NONE;
      } catch (e) {
        // ignore
      }
    }
  }

  setFadePreset(index: number): void {
    this.fadeIndex = Math.max(0, Math.min(FADE_NAMES.length - 1, Math.round(index)));
  }

  /** 预设之上的响度微调，-12 ~ +12 dB，真实叠加到系统响度增益。 */
  setUserGain(db: number): void {
    this.userGainDb = Math.max(-12, Math.min(12, Math.round(db)));
    this.applyLiveSettings();
  }

  /** 柔和度即音量曲线指数，0 表示跟随预设。 */
  setUserCurve(curve: number): void {
    this.userCurve = curve <= 0 ? 0 : Math.max(0.8, Math.min(2.4, curve));
    this.applyLiveSettings();
  }

  retry(): void {
    if (this.currentUrl.length > 0) {
      this.play(this.currentUrl);
    }
  }

  release(): void {
    this.finishFade();
    const p: media.AVPlayer | null = this.player;
    if (p !== null) {
      try {
        p.release();
      } catch (e) {
        // ignore
      }
      this.player = null;
    }
  }
}
