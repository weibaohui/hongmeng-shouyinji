import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { RadioPlayer, PlayState } from './RadioPlayer';
import { Station } from '../model/Station';

const DOMAIN: number = 0x3201;
const TAG: string = 'RadioService';
const SESSION_TAG: string = 'RADIO_SESSION';
/** 推给播控中心的队列窗口大小：当前台前后各这么多台。 */
const QUEUE_WINDOW: number = 30;

/**
 * 播放服务：整个进程唯一，播放器归属这里而不是页面。
 *
 * 之前播放器是 Index 页面的私有字段，页面销毁即 release，前台播放一切正常，
 * 但退到后台后没有会话、没有长时任务，系统随时可以挂起或回收进程。
 * 现在拆成三层：
 * - RadioPlayer：纯 AVPlayer 封装，负责流与音量渐变；
 * - AVSession：播控中心会话，提供锁屏卡片 / 控制中心 / 耳机按键；
 * - 长时任务（AUDIO_PLAYBACK）：保证退到后台后进程不被挂起。
 *
 * 页面只是订阅者：注册 onPlayState / onStation / onSleepTick 三个回调，
 * 页面重建后重新注册即可，服务侧保留最后一份状态。
 */
export class RadioService {
  private static instance: RadioService = new RadioService();

  private player: RadioPlayer = new RadioPlayer();
  private session: avSession.AVSession | null = null;
  private ctx: common.UIAbilityContext | null = null;
  /** 当前电台。锁屏的上一台 / 下一台、恢复播放都以它为基准。 */
  private current: Station | null = null;
  /** 切台队列，由页面把当前筛选结果推过来。 */
  private queue: Station[] = [];
  private randomMode: boolean = false;
  private sleepEnd: number = 0;
  private sleepMinutes: number = 0;
  private sleepLeft: number = 0;
  private sleepTimer: number = -1;
  /** 长时任务是否已经持有，避免重复申请。 */
  private bgActive: boolean = false;
  /** 最近一次播放状态，页面晚于服务注册时用它补推。 */
  private lastState: PlayState = PlayState.Idle;
  private lastMessage: string = '准备就绪';
  /** 媒体封面：用应用自己的图标（512×512 的 app_icon.png）。 */
  private icon: image.PixelMap | null = null;
  private iconLoading: boolean = false;
  /** 推给系统的队列 itemId → 电台。系统回的 itemId 是队列内序号，靠这张表还原。 */
  private queueMap: Map<number, Station> = new Map<number, Station>();

  /** 播放状态变化（状态枚举 + 可直接显示的文案）。 */
  onPlayState: (state: PlayState, message: string) => void = (): void => {
  };
  /** 当前电台变化。 */
  onStation: (station: Station) => void = (station: Station): void => {
  };
  /** 睡眠定时心跳：剩余秒数 + 总分钟数。 */
  onSleepTick: (left: number, minutes: number) => void = (left: number, minutes: number): void => {
  };

  private constructor() {
    this.player.onState = (state: PlayState, message: string): void => {
      this.handleState(state, message);
    };
  }

  static getInstance(): RadioService {
    return RadioService.instance;
  }

  // ============================== 生命周期 ==============================

  /**
   * 绑定 Ability 上下文并建立播控中心会话。整个进程只生效一次，
   * 重复调用（含页面重建）不会重复建会话。
   */
  attach(context: common.UIAbilityContext): void {
    if (this.ctx !== null) {
      return;
    }
    this.ctx = context;
    this.initSession();
  }

  /** Ability 真正销毁时释放播放器与长时任务。 */
  release(): void {
    this.stopSleepTimer();
    this.releaseBackgroundTask();
    this.player.release();
    if (this.session !== null) {
      this.session.deactivate().catch((): void => {
      });
      this.session = null;
    }
    this.ctx = null;
  }

  /**
   * 页面重新注册回调后，把当前状态补推一次，避免界面显示成初始值。
   * 注意不补推 onStation：onStation 的语义是「开始播这一台」，页面据此拉起频谱分析，
   * 单纯恢复界面不该触发拉流。页面需要当前台请直接读 currentStation()。
   */
  syncToPage(): void {
    this.onSleepTick(this.sleepLeft, this.sleepMinutes);
    this.onPlayState(this.lastState, this.lastMessage);
  }

  /** 当前电台。页面重建时用它对齐界面与实际在播的内容。 */
  currentStation(): Station | null {
    return this.current;
  }

  // ============================== 播控中心 ==============================

  private async initSession(): Promise<void> {
    const ctx = this.ctx;
    if (ctx === null || this.session !== null) {
      return;
    }
    try {
      const s: avSession.AVSession = await avSession.createAVSession(ctx, SESSION_TAG, 'audio');
      // 等待期间 Ability 可能已经销毁，这时不要再把会话挂回服务上。
      if (this.ctx !== ctx) {
        s.deactivate().catch((): void => {
        });
        return;
      }
      this.session = s;
      await s.activate();
      // API 24+：显式声明本会话允许后台播放。低于该版本会直接 reject，降级即可。
      try {
        await s.setBackgroundPlayMode(avSession.BackgroundPlayMode.ENABLE_BACKGROUND_PLAY);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'setBackgroundPlayMode unsupported');
      }
      this.setLaunchAbility();
      this.bindController(s);
      await this.pushMetadata();
      hilog.info(DOMAIN, TAG, 'av session ready');
    } catch (e) {
      this.session = null;
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'createAVSession failed: %{public}s', err.message);
    }
  }

  /** 通知栏 / 锁屏卡片点击后回到应用。 */
  private setLaunchAbility(): void {
    const ctx = this.ctx;
    const s = this.session;
    if (ctx === null || s === null) {
      return;
    }
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    wantAgent.getWantAgent(info).then((wa: WantAgent): void => {
      s.setLaunchAbility(wa).catch((err: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'setLaunchAbility failed: %{public}s', err.message);
      });
    }).catch((err: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'getWantAgent failed: %{public}s', err.message);
    });
  }

  /**
   * 取应用图标当媒体封面。电台数据里没有图片字段，用应用自己的图标最自然。
   * 只加载一次并缓存，后续切台直接复用同一个 PixelMap。
   */
  private async loadIcon(): Promise<image.PixelMap | null> {
    if (this.icon !== null) {
      return this.icon;
    }
    if (this.iconLoading) {
      return null;
    }
    const ctx = this.ctx;
    if (ctx === null) {
      return null;
    }
    this.iconLoading = true;
    try {
      const data: Uint8Array = await ctx.resourceManager.getMediaContent($r('app.media.app_icon'));
      const buf: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      const src: image.ImageSource = image.createImageSource(buf);
      const pm: image.PixelMap = await src.createPixelMap();
      src.release();
      this.icon = pm;
      hilog.info(DOMAIN, TAG, 'app icon loaded for media card');
      // 图标是异步拿到的，到位后把封面补上一次，否则先前推出去的 metadata 没有封面。
      this.pushMetadata().catch((): void => {
      });
      this.pushQueue();
      return pm;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'load app icon failed');
      return null;
    } finally {
      this.iconLoading = false;
    }
  }

  /** 锁屏卡片 / 控制中心 / 耳机按键的回调。 */
  private bindController(s: avSession.AVSession): void {
    try {
      s.on('play', (): void => {
        this.resume();
      });
      s.on('pause', (): void => {
        this.pause();
      });
      s.on('stop', (): void => {
        this.stop();
      });
      s.on('playNext', (): void => {
        this.cutStation(1);
      });
      s.on('playPrevious', (): void => {
        this.cutStation(-1);
      });
      // 卡片上直接点某一台时，itemId 是队列内序号，用映射表还原成电台。
      s.on('skipToQueueItem', (itemId: number): void => {
        const st: Station | undefined = this.queueMap.get(itemId);
        if (st !== undefined) {
          this.playStation(st);
        }
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'bind controller failed');
    }
  }

  /**
   * 把当前台附近的电台推给播控中心，卡片上才会出现上一台 / 下一台可选。
   * setMediaCenterControlType 是 API 26 才有的接口，本工程 compatibleSdk 为 24 用不了，
   * 因此改用「给系统一份队列」这条兼容路径。
   *
   * 两个实测出来的坑：
   * 1. 队列项的 description 里不能带 mediaImage —— 一张 512×512 的 PixelMap 约 1MB，
   *    乘上条目数直接超出 Parcel 上限，系统一律回 "item number is out of range"。
   *    封面只放在顶层 AVMetadata 上。
   * 2. itemId 必须是队列内序号 [1, N]，不能直接用电台 id。
   */
  private pushQueue(): void {
    const s = this.session;
    if (s === null || this.current === null) {
      return;
    }
    const list: Station[] = this.queue;
    if (list.length === 0) {
      return;
    }
    let at: number = 0;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === this.current.id) {
        at = i;
        break;
      }
    }
    const windows: number[] = [QUEUE_WINDOW, 10, 4, 2];
    let index: number = 0;
    const attempt = (): void => {
      if (index >= windows.length) {
        hilog.warn(DOMAIN, TAG, 'setAVQueueItems rejected at every window size');
        return;
      }
      const half: number = windows[index];
      index += 1;
      const start: number = Math.max(0, at - half);
      const end: number = Math.min(list.length, at + half + 1);
      const items: avSession.AVQueueItem[] = [];
      const map: Map<number, Station> = new Map<number, Station>();
      for (let i = start; i < end; i++) {
        const st: Station = list[i];
        // itemId 用队列内序号（从 1 开始），必须是 [1, N] 内的值
        const itemId: number = i - start + 1;
        const desc: avSession.AVMediaDescription = {
          assetId: st.id.toString(),
          title: st.name,
          artist: this.regionOf(st),
          albumTitle: '网络电台',
          subtitle: st.genre
        };
        const item: avSession.AVQueueItem = { itemId: itemId, description: desc };
        items.push(item);
        map.set(itemId, st);
      }
      s.setAVQueueItems(items).then((): void => {
        hilog.info(DOMAIN, TAG, 'setAVQueueItems ok, %{public}d items', items.length);
        this.queueMap = map;
      }).catch((err: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'setAVQueueItems rejected (size %{public}d): %{public}s',
          items.length, err.message);
        attempt();
      });
    };
    attempt();
  }

  /** 直播流没有时长，metadata 只给台名与地区，时长/进度一律不填。 */
  private async pushMetadata(): Promise<void> {
    const s = this.session;
    if (s === null) {
      return;
    }
    const st: Station | null = this.current;
    const meta: avSession.AVMetadata = {
      assetId: st === null ? 'radio' : st.id.toString(),
      title: st === null ? '网络收音机' : st.name,
      artist: st === null ? 'Radio' : this.regionOf(st),
      album: '网络电台',
      description: st === null ? '' : st.genre
    };
    const icon: image.PixelMap | null = await this.loadIcon();
    if (icon !== null) {
      meta.mediaImage = icon;
    }
    try {
      await s.setAVMetadata(meta);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setAVMetadata failed');
    }
  }

  private regionOf(st: Station): string {
    if (st.countryCode !== 'CN') {
      return st.country;
    }
    if (st.province.length > 0 && st.city.length > 0) {
      return st.province + ' · ' + st.city;
    }
    if (st.province.length > 0) {
      return st.province;
    }
    return st.country;
  }

  private syncSessionState(state: PlayState): void {
    const s = this.session;
    if (s === null) {
      return;
    }
    let ps: avSession.PlaybackState = avSession.PlaybackState.PLAYBACK_STATE_IDLE;
    if (state === PlayState.Playing) {
      ps = avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    } else if (state === PlayState.Paused) {
      ps = avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    } else if (state === PlayState.Loading) {
      ps = avSession.PlaybackState.PLAYBACK_STATE_BUFFERING;
    } else if (state === PlayState.Stopped) {
      ps = avSession.PlaybackState.PLAYBACK_STATE_STOP;
    } else if (state === PlayState.Error) {
      ps = avSession.PlaybackState.PLAYBACK_STATE_ERROR;
    }
    const payload: avSession.AVPlaybackState = { state: ps, speed: 1.0 };
    s.setAVPlaybackState(payload).catch((err: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'setAVPlaybackState failed: %{public}s', err.message);
    });
  }

  // ============================== 长时任务 ==============================

  /**
   * 申请 AUDIO_PLAYBACK 长时任务，让进程在退到后台后不被挂起。
   * API 20 起，只要接了 AVSession，通知由 AVSession 发出，这里不会再多出一个通知。
   */
  private async acquireBackgroundTask(): Promise<void> {
    const ctx = this.ctx;
    if (ctx === null || this.bgActive) {
      return;
    }
    // 长时任务对应的 syscap 是 ContinuousTask（官方示例里写的 .Core 是旧版本遗留，
    // 在当前 SDK 上永远为 false，会让长时任务一次都申请不上）。
    if (!canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      hilog.warn(DOMAIN, TAG, 'continuous task unsupported on this device');
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: ctx.abilityInfo.bundleName,
          abilityName: ctx.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const wa: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, wa);
      this.bgActive = true;
      hilog.info(DOMAIN, TAG, 'continuous task acquired');
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}s', err.message);
    }
  }

  private async releaseBackgroundTask(): Promise<void> {
    if (!this.bgActive) {
      return;
    }
    const ctx = this.ctx;
    this.bgActive = false;
    if (ctx === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      hilog.info(DOMAIN, TAG, 'continuous task released');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stopBackgroundRunning failed');
    }
  }

  // ============================== 状态分发 ==============================

  private handleState(state: PlayState, message: string): void {
    this.lastState = state;
    this.lastMessage = message;
    this.onPlayState(state, message);
    this.syncSessionState(state);
    if (state === PlayState.Playing) {
      this.acquireBackgroundTask();
    } else if (state === PlayState.Stopped || state === PlayState.Error) {
      this.releaseBackgroundTask();
    }
  }

  // ============================== 播放控制 ==============================

  /** 播放某个电台：切台的同时把播控中心的台名一起换掉。 */
  playStation(station: Station): void {
    this.current = station;
    this.onStation(station);
    this.pushMetadata();
    this.pushQueue();
    this.player.play(station.url);
  }

  /** 只切换当前电台，不开播。用于页面恢复出上次收听的台。 */
  setCurrent(station: Station): void {
    this.current = station;
    this.pushMetadata();
    this.pushQueue();
  }

  /** 页面把当前筛选结果推过来，作为锁屏上一台 / 下一台的队列。 */
  setQueue(list: Station[]): void {
    this.queue = list;
    this.pushQueue();
  }

  setRandom(on: boolean): void {
    this.randomMode = on;
  }

  /** 切台：顺序或随机，和页面里原来的逻辑一致。 */
  cutStation(delta: number): void {
    const list: Station[] = this.queue.length > 0 ? this.queue : this.allStations();
    if (list.length === 0) {
      return;
    }
    let at: number = 0;
    if (this.current !== null) {
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === this.current.id) {
          at = i;
          break;
        }
      }
    }
    const next: number = this.randomMode
      ? Math.floor(Math.random() * list.length)
      : (at + delta + list.length) % list.length;
    this.playStation(list[next]);
  }

  private allStations(): Station[] {
    const out: Station[] = [];
    if (this.current !== null) {
      out.push(this.current);
    }
    return out;
  }

  /**
   * 播放 / 暂停切换。返回 true 表示在已有播放之间切换，
   * false 表示没有可恢复的实例、需要按当前台重新开播。
   */
  toggle(): boolean {
    if (this.player.toggle()) {
      return true;
    }
    if (this.current !== null) {
      this.playStation(this.current);
    }
    return false;
  }

  /** 确保处于播放态（锁屏「播放」键）。 */
  resume(): void {
    if (this.player.resume()) {
      return;
    }
    if (this.current !== null) {
      this.playStation(this.current);
    }
  }

  /** 确保处于暂停态（锁屏「暂停」键）。 */
  pause(): void {
    this.player.pause();
  }

  stop(): void {
    this.player.stop();
  }

  setVolume(level: number): void {
    this.player.setVolume(level);
  }

  setSoundProfile(index: number): void {
    this.player.setSoundProfile(index);
  }

  setFadePreset(index: number): void {
    this.player.setFadePreset(index);
  }

  setSystemEffect(on: boolean): void {
    this.player.setSystemEffect(on);
  }

  setUserGain(db: number): void {
    this.player.setUserGain(db);
  }

  setUserCurve(curve: number): void {
    this.player.setUserCurve(curve);
  }

  // ============================== 睡眠定时 ==============================

  /**
   * 睡眠定时放在服务侧而不是页面：退到后台、页面重建都不影响计时。
   * 用绝对时间戳，进程被挂起再恢复也不会算错。
   */
  setSleepMinutes(minutes: number): void {
    this.sleepMinutes = minutes;
    if (minutes <= 0) {
      this.sleepEnd = 0;
      this.sleepLeft = 0;
      this.stopSleepTimer();
    } else {
      this.sleepEnd = Date.now() + minutes * 60000;
      this.sleepLeft = minutes * 60;
      this.startSleepTimer();
    }
    this.onSleepTick(this.sleepLeft, this.sleepMinutes);
  }

  private startSleepTimer(): void {
    if (this.sleepTimer >= 0) {
      return;
    }
    this.sleepTimer = setInterval((): void => {
      this.tickSleep();
    }, 1000);
  }

  private stopSleepTimer(): void {
    if (this.sleepTimer >= 0) {
      clearInterval(this.sleepTimer);
      this.sleepTimer = -1;
    }
  }

  private tickSleep(): void {
    if (this.sleepEnd <= 0) {
      return;
    }
    const left: number = Math.max(0, Math.ceil((this.sleepEnd - Date.now()) / 1000));
    this.sleepLeft = left;
    if (left <= 0) {
      this.sleepEnd = 0;
      this.sleepMinutes = 0;
      this.stopSleepTimer();
      this.stop();
      // stop() 内部已经报过一次「已停止」，这里补成定时结束的文案。
      this.lastState = PlayState.Stopped;
      this.lastMessage = '睡眠定时结束';
      this.onPlayState(PlayState.Stopped, '睡眠定时结束');
    }
    this.onSleepTick(this.sleepLeft, this.sleepMinutes);
  }
}
