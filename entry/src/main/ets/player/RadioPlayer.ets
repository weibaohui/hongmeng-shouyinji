import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';

export enum PlayState {
  Idle = 0,
  Loading = 1,
  Playing = 2,
  Paused = 3,
  Error = 4,
  Stopped = 5
}

/**
 * 基于 AVPlayer 的网络电台播放器。
 * E6 版依赖固件 soundPlayer.playOnlineAudio，鸿蒙版改用系统 AVPlayer 直接拉流；
 * 状态机：idle -> initialized -> prepared -> playing，切台时 reset 后重新 set url。
 */
export class RadioPlayer {
  private player: media.AVPlayer | null = null;
  private avState: string = 'idle';
  private volume: number = 0.6;
  private currentUrl: string = '';
  private protocolRetried: boolean = false;
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
        p.prepare().catch(() => {
          this.onState(PlayState.Error, '缓冲失败，请换一个电台');
        });
        break;
      case 'prepared':
        try {
          p.setVolume(this.volume);
        } catch (e) {
          // 部分状态下暂不支持设置音量，播放后由 UI 再次同步
        }
        p.play().catch(() => {
          this.onState(PlayState.Error, '播放启动失败');
        });
        this.onState(PlayState.Playing, '正在播放');
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

  /** 播放某个流地址。reset 失败时重建一次 AVPlayer 再试。 */
  async play(url: string): Promise<void> {
    this.protocolRetried = false;
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

  /** 协议切换重试：先彻底释放旧实例，避免 error 状态下 reset 失败。 */
  private async restartWith(url: string): Promise<void> {
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
    if (this.avState === 'playing') {
      try {
        p.pause();
        return true;
      } catch (e) {
        return false;
      }
    }
    if (this.avState === 'paused') {
      try {
        p.play();
        return true;
      } catch (e) {
        return false;
      }
    }
    return false;
  }

  stop(): void {
    const p: media.AVPlayer | null = this.player;
    if (p !== null && (this.avState === 'playing' || this.avState === 'paused' || this.avState === 'prepared')) {
      try {
        p.stop();
      } catch (e) {
        // 状态已变化，忽略
      }
    }
    this.onState(PlayState.Stopped, '已停止');
  }

  setVolume(level: number): void {
    this.volume = Math.max(0, Math.min(1, level / 100));
    const p: media.AVPlayer | null = this.player;
    if (p !== null && this.avState !== 'idle' && this.avState !== 'released') {
      try {
        p.setVolume(this.volume);
      } catch (e) {
        // 忽略：下次 prepared 时会重新应用
      }
    }
  }

  retry(): void {
    if (this.currentUrl.length > 0) {
      this.play(this.currentUrl);
    }
  }

  release(): void {
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
