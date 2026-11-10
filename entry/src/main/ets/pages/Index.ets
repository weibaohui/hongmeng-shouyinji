import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AICaptionComponent, AICaptionController, AICaptionOptions } from '@kit.SpeechKit';
import {
  Station, Scope, Palette, SCOPE_NAMES, VIZ_NAMES, THEME_NAMES, SLEEP_OPTIONS, themeColors
} from '../model/Station';
import { ALL_STATIONS } from '../model/StationData';
import { RadioStore } from '../model/RadioStore';
import {
  PlayState, SOUND_NAMES, SOUND_HINTS, SOUND_EFFECTS, FADE_NAMES
} from '../player/RadioPlayer';
import { RadioService } from '../player/RadioService';
import { SpectrumPainter } from '../view/SpectrumPainter';
import { SpectrumAnalyzer } from '../player/SpectrumAnalyzer';

/** 取异常文本：连取错误信息都可能再抛一次，这里必须绝对安全。 */
function safeErrorText(e: Object): string {
  try {
    const err = e as Error;
    const name: string = err.name ?? 'Error';
    const msg: string = err.message ?? '';
    return name + ': ' + msg;
  } catch (e2) {
    return 'unprintable';
  }
}

/** 起流阶段最多等这么久（毫秒）：超过说明这次连接没能立起来。 */
const ANALYSIS_START_TIMEOUT_MS: number = 6000;
/** 已经跑起来之后，多久没有新频段就算卡死（毫秒）。 */
const ANALYSIS_STALL_TIMEOUT_MS: number = 2500;
/** 连续自愈多少次仍拿不到数据，就退回模拟模式，保证画面不会永远定住。 */
const ANALYSIS_MAX_RECOVER: number = 3;

/** 主页面：平板三栏（导航 / 电台列表 / 播放器），窄屏自动降级为单栏 + 底部页签。 */
@Entry
@Component
struct Index {
  @State windowWidth: number = 1200;
  @State topPad: number = 0;
  @State activePane: number = 1;
  @State scope: number = Scope.All;
  @State keyword: string = '';
  @State searchText: string = '';
  @State province: string = '全部';
  @State genre: string = '全部';
  @State provinceOptions: string[] = [];
  @State genreOptions: string[] = [];
  @State scopeNames: string[] = SCOPE_NAMES.slice();
  @State visible: Station[] = [];
  @State shownCount: number = 50;
  @State favorites: number[] = [];
  @State current: Station = ALL_STATIONS[0];
  /**
   * 上一台 / 下一台的预览名。
   * 这两个值显式存成 @State，而不是在 @Builder 里直接调 neighborName() 现算：
   * 后台切台（锁屏卡片切台）时，@Builder 的参数是父级渲染那一刻的快照，
   * ArkUI 的局部更新不会重新求值，标题会变而这两张卡停在旧台名。
   */
  @State neighborPrevName: string = '—';
  @State neighborNextName: string = '—';
  @State playState: PlayState = PlayState.Idle;
  @State statusText: string = '准备就绪';
  @State volume: number = 60;
  @State vizStyle: number = 0;
  /** 频谱数据来源：0 模拟动画，1 真实音频分析。 */
  @State vizMode: number = 0;
  /** 真实模式的状态提示，供设置面板显示。 */
  @State vizHint: string = '';
  @State colorTheme: number = 0;
  @State randomMode: boolean = false;
  @State sleepMinutes: number = 0;
  @State sleepLeft: number = 0;
  @State settingsOpen: boolean = false;
  @State filterOpen: boolean = false;
  @State scopeCounts: number[] = [0, 0, 0, 0];
  @State clock: string = '';
  @State captionOn: boolean = false;
  @State soundPreset: number = 0;
  @State fadePreset: number = 2;
  @State systemEffect: boolean = true;
  @State userGain: number = 0;
  @State userCurve: number = 0;
  @State soundNames: string[] = SOUND_NAMES.slice();
  @State fadeNames: string[] = FADE_NAMES.slice();

  /** 系统 AI 字幕能力：端侧识别，无需任何云端密钥。 */
  private captionSupported: boolean = canIUse('SystemCapability.AI.AICaption');
  private captionController: AICaptionController = new AICaptionController();
  private captionOptions: AICaptionOptions = {
    // 组件自带底板默认半透明，会和我们的字幕卡叠成两层；置 0 只留文字，底色由卡片统一给
    initialOpacity: 0,
    fontColor: '#E8EFF8',
    onPrepared: (): void => {
      this.statusText = '字幕已就绪';
    },
    onError: (err: BusinessError): void => {
      hilog.info(0x3202, 'RadioDiag', 'caption error %{public}d', err.code);
      this.captionOn = false;
      this.statusText = '字幕不可用：' + err.code.toString();
    }
  };

  private store: RadioStore = RadioStore.getInstance();
  /** 播放服务：播放器归它所有，页面只是订阅者，退到后台不会因为页面销毁而停播。 */
  private service: RadioService = RadioService.getInstance();
  private painter: SpectrumPainter = new SpectrumPainter();
  /** 真实频谱：原生拉流解码 + FFT，不采集麦克风。 */
  private analyzer: SpectrumAnalyzer = new SpectrumAnalyzer();
  private renderSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.renderSettings);
  private canvasWidth: number = 520;
  private canvasHeight: number = 150;
  /**
   * 动画循环用的定时器。
   * 这里刻意不用 setInterval：字幕组件（系统动态组件）被销毁时，ArkUI 会把页面上的
   * 70ms 定时器连锅端掉，画面就此永远停在最后一帧——实测「开字幕→关字幕」必现。
   * 改成每帧自己排下一帧的 setTimeout 链，再由 1 秒的心跳看门狗兜底重排，
   * 动画就不再可能停死。
   */
  private animTimer: number = -1;
  private secondTimer: number = -1;
  /** 心跳看门狗：负责发现动画循环停摆并把它重新拉起来。 */
  private watchdogTimer: number = -1;
  /** 最近一帧成功绘制的时间。 */
  private lastFrameAt: number = 0;
  /** 页面是否在前台。退到后台时不再重拉分析流，避免白耗流量与电量。 */
  private pageVisible: boolean = true;
  /** 看门狗告警是否已经报过，避免同一次停摆反复刷日志。 */
  private stallWarned: boolean = false;
  /** 真实频谱的最新数据版本与到达时刻，用来判断画面是不是「断供」了。 */
  private lastBandSeq: number = -1;
  private lastBandAt: number = 0;
  private realBands: number[] = [];
  /** 最近一次起流的时刻：用来识别「连接一直没立起来」。 */
  private analysisStartAt: number = 0;
  /** 最近一次收到新频段的时刻：用来识别「跑到一半卡死」。 */
  private lastSeqAt: number = 0;
  /** 连续自愈次数；超过上限仍拿不到数据就退回模拟模式，保证画面不会永远定住。 */
  private recoverCount: number = 0;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store.init(ctx);
    const cfg = this.store.config;
    // 页面重建时以服务侧正在播的台为准，避免界面和实际播放对不上。
    const playing: Station | null = this.service.currentStation();
    this.current = playing !== null ? playing : this.store.findById(cfg.lastId);
    this.favorites = cfg.favorites.slice();
    this.computeScopeCounts();
    this.volume = cfg.volume;
    this.vizStyle = cfg.vizStyle;
    this.vizMode = cfg.vizMode;
    this.colorTheme = cfg.colorTheme;
    this.randomMode = cfg.random;
    this.soundPreset = cfg.soundPreset;
    this.fadePreset = cfg.fadePreset;
    this.systemEffect = cfg.systemEffect;
    this.userGain = cfg.userGain;
    this.userCurve = cfg.userCurve;
    this.scope = cfg.scope;
    this.province = cfg.province;
    this.genre = cfg.genre;
    this.provinceOptions = this.store.provinces();
    this.genreOptions = this.store.genres();
    // 绑定播放服务：建立播控中心会话，并把页面订阅接到服务状态上。
    this.service.attach(ctx);
    this.service.onPlayState = (state: PlayState, message: string): void => {
      this.playState = state;
      this.statusText = message;
      if (state === PlayState.Stopped || state === PlayState.Error) {
        // 睡眠定时到点、播放出错等收尾场景，频谱的第二条流要一起停掉。
        this.analyzer.stop();
      }
    };
    this.service.onStation = (station: Station): void => {
      // 切台既可能来自页面，也可能来自锁屏卡片，统一在这里收口。
      this.current = station;
      this.refreshNeighborNames(station);
      this.painter.reseedRandom();
      this.persist();
      if (this.vizMode === 1 && this.pageVisible) {
        // 旧台的频段立刻清掉，新流连上之前先按静音画，不要残留上一家的波形
        this.beginAnalysis(station.url);
      }
    };
    this.service.onSleepTick = (left: number, minutes: number): void => {
      this.sleepLeft = left;
      this.sleepMinutes = minutes;
    };
    this.service.setCurrent(this.current);
    this.service.setSoundProfile(this.soundPreset);
    this.service.setFadePreset(this.fadePreset);
    this.service.setSystemEffect(this.systemEffect);
    this.service.setUserGain(this.userGain);
    this.service.setUserCurve(this.userCurve);
    this.service.setVolume(this.volume);
    this.service.setRandom(this.randomMode);
    this.applyFilter(true);
    this.observeWindow();
    this.updateClock();
    this.painter.setTheme(this.colorTheme);
    this.painter.setStyle(this.vizStyle);
    this.painter.setRealMode(this.vizMode === 1);
    this.lastFrameAt = Date.now();
    this.startAnimLoop();
    // 心跳看门狗：动画循环万一被系统掐掉，这里负责重新拉起来。
    this.watchdogTimer = setInterval(() => {
      const idle: number = Date.now() - this.lastFrameAt;
      if (idle > 1500) {
        if (!this.stallWarned) {
          this.stallWarned = true;
          hilog.warn(0x3202, 'RadioDiag', 'anim loop stalled %{public}d ms, restart', idle);
        }
        this.stopAnimLoop();
        this.startAnimLoop();
      }
    }, 1000);
    this.secondTimer = setInterval(() => {
      this.updateClock();
    }, 1000);
    // 页面注册晚于服务状态时，把当前状态补推一次。
    this.service.syncToPage();
  }

  aboutToDisappear(): void {
    this.analyzer.stop();
    this.stopAnimLoop();
    if (this.secondTimer >= 0) {
      clearInterval(this.secondTimer);
    }
    if (this.watchdogTimer >= 0) {
      clearInterval(this.watchdogTimer);
    }
    // 播放器归服务所有，这里只解绑回调：页面销毁不能把后台播放一起停掉。
    this.service.onPlayState = (state: PlayState, message: string): void => {
    };
    this.service.onStation = (station: Station): void => {
    };
    this.service.onSleepTick = (left: number, minutes: number): void => {
    };
  }

  /** 切到后台就断开分析用的第二条流，避免在后台白耗流量与电量。 */
  onPageHide(): void {
    this.pageVisible = false;
    this.analyzer.stop();
    this.resetRealBands();
  }

  /** 回到前台且还在播放时重新接上，失败会自动回退模拟模式。 */
  onPageShow(): void {
    this.pageVisible = true;
    if (this.vizMode === 1 && this.isPlaying()) {
      this.startAnalysis();
    }
  }

  private observeWindow(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(ctx).then((win: window.Window) => {
      const rect: window.Rect = win.getWindowProperties().windowRect;
      this.windowWidth = this.getUIContext().px2vp(rect.width);
      const avoid: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.topPad = this.getUIContext().px2vp(avoid.topRect.height);
      win.on('windowSizeChange', (size: window.Size) => {
        this.windowWidth = this.getUIContext().px2vp(size.width);
      });
    }).catch(() => {
      this.windowWidth = 1200;
    });
  }

  private isWide(): boolean {
    return this.windowWidth >= 1000;
  }

  private isTablet(): boolean {
    return this.windowWidth >= 680;
  }

  private isPlaying(): boolean {
    return this.playState === PlayState.Playing;
  }

  private stateColor(): string {
    switch (this.playState) {
      case PlayState.Playing:
        return Palette.GREEN;
      case PlayState.Loading:
        return Palette.BLUE;
      case PlayState.Error:
        return Palette.RED;
      default:
        return Palette.TEXT_DIM;
    }
  }

  private updateClock(): void {
    const d: Date = new Date();
    const h: number = d.getHours();
    const m: number = d.getMinutes();
    this.clock = (h < 10 ? '0' : '') + h.toString() + ':' + (m < 10 ? '0' : '') + m.toString();
  }

  private sleepLabel(): string {
    if (this.sleepLeft <= 0) {
      return '定时关闭';
    }
    const minutes: number = Math.floor(this.sleepLeft / 60);
    const seconds: number = this.sleepLeft % 60;
    return minutes.toString() + ':' + (seconds < 10 ? '0' : '') + seconds.toString() + ' 后关闭';
  }

  /** 启动动画循环：每帧结束后自己排下一帧。 */
  private startAnimLoop(): void {
    if (this.animTimer >= 0) {
      return;
    }
    this.animTimer = setTimeout(() => {
      this.animTimer = -1;
      this.animStep();
      this.startAnimLoop();
    }, 70);
  }

  private stopAnimLoop(): void {
    if (this.animTimer >= 0) {
      clearTimeout(this.animTimer);
      this.animTimer = -1;
    }
  }

  /** 一帧：拉数据 → 推进动画 → 画到画布。异常必须自己吞掉，否则整条循环会被掐断。 */
  private animStep(): void {
    let step: string = 'poll';
    try {
      this.pollAnalysis();
      step = 'tick';
      this.painter.tick(this.isPlaying());
      step = 'draw';
      this.drawFrame();
      this.lastFrameAt = Date.now();
      this.stallWarned = false;
    } catch (e) {
      hilog.error(0x3202, 'RadioDiag', 'anim error at %{public}s: %{public}s', step, safeErrorText(e));
    }
  }

  private drawFrame(): void {
    // 样式与配色都由 painter 持有：绘制只传画布尺寸与播放态，避免定时器读到旧的 @State 快照
    this.painter.draw(this.canvasCtx, this.canvasWidth, this.canvasHeight, this.isPlaying());
  }

  private applyFilter(skipSave: boolean = false): void {
    this.visible = this.store.filter(this.scope, this.keyword, this.province, this.genre);
    this.shownCount = 50;
    // 锁屏卡片上的上一台 / 下一台走同一份队列，行为和页面里的按钮一致。
    this.service.setQueue(this.visible.length > 0 ? this.visible : this.store.all);
    this.refreshNeighborNames(this.current);
    if (!skipSave) {
      this.persist();
    }
  }

  private persist(): void {
    const cfg = this.store.config;
    cfg.lastId = this.current.id;
    cfg.volume = this.volume;
    cfg.vizStyle = this.vizStyle;
    cfg.vizMode = this.vizMode;
    cfg.colorTheme = this.colorTheme;
    cfg.random = this.randomMode;
    cfg.soundPreset = this.soundPreset;
    cfg.fadePreset = this.fadePreset;
    cfg.systemEffect = this.systemEffect;
    cfg.userGain = this.userGain;
    cfg.userCurve = this.userCurve;
    cfg.sleepMinutes = this.sleepMinutes;
    cfg.scope = this.scope;
    cfg.province = this.province;
    cfg.genre = this.genre;
    this.store.save();
  }

  private setScope(next: number): void {
    this.scope = next;
    this.scopeNames = SCOPE_NAMES.slice();
    this.applyFilter();
  }

  private setProvince(next: string): void {
    this.province = next;
    this.provinceOptions = this.provinceOptions.slice();
    this.applyFilter();
  }

  private setGenre(next: string): void {
    this.genre = next;
    this.genreOptions = this.genreOptions.slice();
    this.applyFilter();
  }

  private clearSearch(): void {
    this.searchText = '';
    this.keyword = '';
    this.applyFilter();
  }

  /** 页面内点选电台（用户主动操作）：收起筛选、竖屏切到播放页，再交给服务开播。 */
  private playStation(station: Station): void {
    this.filterOpen = false;
    // 竖屏从电台页点选后直接进播放页，不必再手动切页签。
    if (!this.isTablet() && this.activePane === 0) {
      this.activePane = 1;
    }
    this.service.playStation(station);
  }

  /** 上一台 / 下一台。服务侧按同一份队列计算，锁屏卡片与页面按钮行为一致。 */
  private cutStation(delta: number): void {
    this.service.cutStation(delta);
  }

  /**
   * 上一台 / 下一台的台名。
   * 显式传入当前台，不回读 this.current：ArkUI V1 里 @State 赋值后在同一同步块内
   * 再读这个属性可能仍拿到旧对象，算出来的名字恰好和原来一样，系统就认为没变化，
   * 于是标题变了而这两张卡停在旧台名（后台切台时尤其明显）。
   */
  private neighborName(cur: Station, delta: number): string {
    const queue: Station[] = this.visible.length > 0 ? this.visible : this.store.all;
    for (let i = 0; i < queue.length; i++) {
      if (queue[i].id === cur.id) {
        const at: number = (i + delta + queue.length) % queue.length;
        return queue[at].name;
      }
    }
    return queue.length > 0 ? queue[0].name : '—';
  }

  /** 重新计算上一台 / 下一台的预览名。当前台或列表变化后都要调一次。 */
  private refreshNeighborNames(cur: Station): void {
    this.neighborPrevName = this.neighborName(cur, -1);
    this.neighborNextName = this.neighborName(cur, 1);
  }

  private togglePlayback(): void {
    const wasPlaying: boolean = this.isPlaying();
    // 服务在无可恢复实例时会按当前台重新开播，这里只负责频谱的起停。
    this.service.toggle();
    if (wasPlaying) {
      this.analyzer.stop();
    } else if (this.vizMode === 1) {
      this.startAnalysis();
    }
  }

  // ============================== 真实频谱 ==============================

  /** 清空真实频段：切台/切换数据源时调用，画面立即回到静音而不是残留旧波形。 */
  private resetRealBands(): void {
    this.realBands = [];
    this.lastBandSeq = -1;
    this.lastBandAt = 0;
    this.painter.setRealBands([]);
  }

  /**
   * 对指定流重新起一次分析（切台与自愈共用）。
   * 一定要先 stop 再 start：SpectrumAnalyzer 对同一个地址会「复用现有会话」，
   * 不先 stop 的话这里等于什么都没做，卡死的会话永远换不掉。
   */
  private beginAnalysis(url: string): void {
    this.analyzer.stop();
    this.resetRealBands();
    this.lastBandSeq = -1;
    this.analysisStartAt = Date.now();
    this.lastSeqAt = Date.now();
    this.analyzer.start(url);
    this.updateVizHint('正在解析音频流…');
  }

  private startAnalysis(): void {
    if (this.vizMode !== 1) {
      return;
    }
    if (!this.isPlaying()) {
      this.updateVizHint('播放后开始实时解析');
      return;
    }
    this.beginAnalysis(this.current.url);
  }

  /**
   * 分析流自愈。
   *
   * 原生分析器一旦卡死（常驻线程被死等、或网络读不返回），它报上来的状态既不是失败
   * 也不是空闲，而是永远停在「正在解析」——ArkTS 侧看着一切正常，画面却再也不会动。
   * 所以这里不依赖状态码，而是盯住「数据版本号有没有继续涨」：
   * 涨了就正常，不涨就是卡死，主动重连；反复重连仍拿不到数据就退回模拟模式，
   * 至少让画面继续动，不至于永远定格。
   */
  private recoverAnalysis(reason: string): void {
    if (this.recoverCount >= ANALYSIS_MAX_RECOVER) {
      hilog.warn(0x3202, 'RadioDiag', 'analysis unresponsive, fallback to simulation');
      this.analyzer.stop();
      this.painter.setRealMode(false);
      this.resetRealBands();
      this.vizMode = 0;
      this.persist();
      this.updateVizHint('实时解析无响应，已回退模拟');
      return;
    }
    this.recoverCount += 1;
    hilog.warn(0x3202, 'RadioDiag', 'analysis recovered (%{public}d): %{public}s', this.recoverCount, reason);
    this.beginAnalysis(this.current.url);
    this.updateVizHint(reason);
  }

  /**
   * 每 70ms 与动画同帧轮询：拿到新一帧频段就喂给绘制器，解析失败则回退模拟模式。
   * 这里刻意不做「没在播放就 stop」——切台缓冲期 playState 会短暂离开 Playing，
   * 一旦顺手停掉分析器，新台又要重新连流，表现就是切台卡住、频谱定格好几秒。
   */
  private pollAnalysis(): void {
    if (this.vizMode !== 1) {
      return;
    }
    // 退到后台后不再重拉分析流：onPageHide 已经把第二条流断开了，
    // 这里再拉起来等于白耗流量与电量。
    if (!this.pageVisible) {
      return;
    }
    if (!this.isPlaying()) {
      return;
    }
    if (!this.analyzer.isActive()) {
      this.startAnalysis();
      return;
    }
    const status: number = this.analyzer.status();
    if (status < 0) {
      const reason: string = this.analyzer.message();
      this.analyzer.stop();
      this.painter.setRealMode(false);
      this.resetRealBands();
      this.vizMode = 0;
      this.persist();
      this.updateVizHint(reason + '，已回退模拟');
      return;
    }
    const now: number = Date.now();
    const seq: number = this.analyzer.seq();
    if (seq !== this.lastBandSeq) {
      this.lastBandSeq = seq;
      this.lastSeqAt = now;
      // 数据重新流动，说明上一次自愈成功了，计数归零
      this.recoverCount = 0;
      const bands: number[] = this.analyzer.bands();
      if (bands.length > 0) {
        this.lastBandAt = now;
        this.realBands = bands.slice();
        this.painter.setRealBands(this.realBands);
        this.updateVizHint('实时解析中 · 不走麦克风');
      }
      return;
    }
    if (status === 1) {
      // 正在起流。超过时限还没出帧，说明这次连接根本没立起来（原生侧可能已经卡死）。
      if (now - this.analysisStartAt > ANALYSIS_START_TIMEOUT_MS) {
        this.recoverAnalysis('音频流长时间无响应，正在重连…');
        return;
      }
      this.updateVizHint('正在解析音频流…');
      return;
    }
    // 已经在跑却没有新频段：要么在等网络补货，要么分析链路已经卡死。
    if (now - this.lastSeqAt > ANALYSIS_STALL_TIMEOUT_MS) {
      this.recoverAnalysis('实时解析中断，正在重连…');
      return;
    }
    // 网络流偶尔断供几百毫秒：让柱体缓缓落底，比原地定格自然得多
    if (this.realBands.length > 0 && now - this.lastBandAt > 300) {
      const decayed: number[] = [];
      for (let i = 0; i < this.realBands.length; i++) {
        decayed.push(this.realBands[i] * 0.92);
      }
      this.realBands = decayed;
      this.painter.setRealBands(decayed);
    }
  }

  private updateVizHint(text: string): void {
    if (this.vizHint !== text) {
      this.vizHint = text;
    }
  }

  private setVizMode(mode: number): void {
    this.vizMode = mode;
    this.painter.setRealMode(mode === 1);
    if (mode === 1) {
      this.resetRealBands();
      this.startAnalysis();
      if (!this.isPlaying()) {
        this.updateVizHint('播放后开始实时解析');
      }
    } else {
      this.analyzer.stop();
      this.resetRealBands();
      this.updateVizHint('');
    }
    this.persist();
    this.drawFrame();
  }

  private toggleFav(station: Station): void {
    this.store.toggleFavorite(station.id);
    this.favorites = this.store.config.favorites.slice();
    this.computeScopeCounts();
    if (this.scope === Scope.Favorite) {
      this.applyFilter();
    }
  }

  private isFav(id: number): boolean {
    return this.favorites.indexOf(id) >= 0;
  }

  private isCurrent(id: number): boolean {
    return this.current.id === id;
  }

  private startSleep(minutes: number): void {
    // 定时器在服务侧计时：退到后台、锁屏都不会漏掉截止时间。
    this.service.setSleepMinutes(minutes);
    this.persist();
  }

  private changeVolume(level: number): void {
    this.volume = Math.max(0, Math.min(100, Math.round(level)));
    this.service.setVolume(this.volume);
    this.persist();
  }

  /** 各范围的电台数量：只在数据/收藏变化时重算，避免每次渲染遍历 2105 条。 */
  private computeScopeCounts(): void {
    const all: Station[] = this.store.all;
    let domestic: number = 0;
    for (let i = 0; i < all.length; i++) {
      if (all[i].countryCode === 'CN') {
        domestic++;
      }
    }
    this.scopeCounts = [all.length, this.favorites.length, domestic, all.length - domestic];
  }

  private scopeCount(index: number): string {
    return this.scopeCounts[index].toString();
  }

  private filterSummary(): string {
    const p: string = this.province === '全部' ? '' : this.province;
    const g: string = this.genre === '全部' ? '' : this.genre;
    if (p.length === 0 && g.length === 0) {
      return '全部省市 · 全部题材';
    }
    return p.length > 0 && g.length > 0 ? p + ' · ' + g : (p.length > 0 ? p : g);
  }

  private hasFilter(): boolean {
    return this.province !== '全部' || this.genre !== '全部';
  }

  private resetFilters(): void {
    this.province = '全部';
    this.genre = '全部';
    this.provinceOptions = this.provinceOptions.slice();
    this.genreOptions = this.genreOptions.slice();
    this.applyFilter();
  }

  /** 次级控制里的定时按钮：0/15/30/60/90 循环，不必进设置面板。 */
  private cycleSleep(): void {
    let at: number = 0;
    for (let i = 0; i < SLEEP_OPTIONS.length; i++) {
      if (SLEEP_OPTIONS[i] === this.sleepMinutes) {
        at = i;
        break;
      }
    }
    this.startSleep(SLEEP_OPTIONS[(at + 1) % SLEEP_OPTIONS.length]);
  }

  private sleepShortLabel(): string {
    return this.sleepLeft <= 0 ? '定时' : Math.floor(this.sleepLeft / 60).toString() + ' 分';
  }

  private toggleCaption(): void {
    if (!this.captionSupported) {
      return;
    }
    this.captionOn = !this.captionOn;
    this.statusText = this.captionOn ? '正在开启字幕' : '字幕已关闭';
  }

  private stationSubtitle(): string {
    const region: string = this.current.countryCode === 'CN' ? this.current.province : this.current.country;
    return region + ' · ' + this.current.genre;
  }

  /** 宽版 33% 与导航 16% 保持设计稿比例；紧凑三栏按 38%。 */
  /** 导航/页签图标：按名称与选中态选矢量资源，避免用文字符号充当图标。 */
  private navIcon(kind: string, active: boolean): Resource {
    if (kind === 'grid') {
      return active ? $r('app.media.ic_grid_blue') : $r('app.media.ic_grid_dim');
    }
    if (kind === 'heart') {
      return active ? $r('app.media.ic_heart_blue') : $r('app.media.ic_heart_dim');
    }
    if (kind === 'radio') {
      return active ? $r('app.media.ic_radio_blue') : $r('app.media.ic_radio_dim');
    }
    if (kind === 'globe') {
      return active ? $r('app.media.ic_globe_blue') : $r('app.media.ic_globe_dim');
    }
    if (kind === 'list') {
      return active ? $r('app.media.ic_list_blue') : $r('app.media.ic_list_dim');
    }
    return active ? $r('app.media.ic_settings_blue') : $r('app.media.ic_settings_dim');
  }

  private quickIcon(kind: string): Resource {
    if (kind === 'sleep') {
      return $r('app.media.ic_sleep_dim');
    }
    if (kind === 'random') {
      return $r('app.media.ic_shuffle_dim');
    }
    return $r('app.media.ic_caption_dim');
  }

  private paneWidth(): string {
    return this.isWide() ? '33%' : '38%';
  }

  private setSoundPreset(index: number): void {
    this.soundPreset = index;
    this.soundNames = SOUND_NAMES.slice();
    this.systemEffect = (index >= 0 && index < SOUND_EFFECTS.length) ? SOUND_EFFECTS[index] : true;
    this.service.setSoundProfile(index);
    this.persist();
  }

  private soundHint(): string {
    const i: number = this.soundPreset;
    const base: string = (i >= 0 && i < SOUND_HINTS.length) ? SOUND_HINTS[i] : '';
    const g: number = this.userGain;
    const extra: string = g === 0 ? '' : ' · 微调 ' + (g > 0 ? '+' : '') + g.toString() + 'dB';
    return base + extra;
  }

  private gainLabel(): string {
    return (this.userGain > 0 ? '+' : '') + this.userGain.toString() + 'dB';
  }

  private curveLabel(): string {
    return this.userCurve === 0 ? '跟随' : this.userCurve.toFixed(1);
  }

  private setFadePreset(index: number): void {
    this.fadePreset = index;
    this.fadeNames = FADE_NAMES.slice();
    this.service.setFadePreset(index);
    this.persist();
  }

  private setSystemEffect(on: boolean): void {
    this.systemEffect = on;
    this.service.setSystemEffect(on);
    this.persist();
  }

  // ============================== 页面骨架 ==============================

  build() {
    Stack({ alignContent: Alignment.End }) {
      Column() {
        if (this.isTablet()) {
          Row() {
            this.navRail()
            Column() {
              this.listPane()
            }
            .width(this.paneWidth())
            .height('100%')
            .border({ width: { right: 1 }, color: Palette.BORDER })
            Column() {
              this.playerPane()
            }
            .layoutWeight(1)
            .height('100%')
          }
          .width('100%')
          .height('100%')
        } else {
          Column() {
            if (this.activePane === 0) {
              Column() {
                this.listPane()
              }
              .layoutWeight(1)
            } else if (this.activePane === 1) {
              Column() {
                this.portraitPlayerPane()
              }
              .layoutWeight(1)
            } else {
              Column() {
                this.settingsPane()
              }
              .layoutWeight(1)
            }
            this.bottomTabs()
          }
          .width('100%')
          .height('100%')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Palette.BG)
      .padding({ top: this.topPad })

      if (this.settingsOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#A6000000')
          .onClick(() => {
            this.settingsOpen = false;
          })
        Column() {
          this.settingsPane()
        }
        .width(400)
        .height('100%')
        .backgroundColor(Palette.SURFACE)
        .border({ width: { left: 1 }, color: Palette.BORDER })
      }

    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG)
  }

  // ============================== 左侧导航 ==============================

  @Builder
  navRail() {
    Column() {
      Row() {
        Image($r('app.media.app_icon'))
          .width(38)
          .height(38)
          .borderRadius(11)
        if (this.isWide()) {
          Text('收音机')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TEXT)
            .letterSpacing(1)
            .margin({ left: 12 })
        }
      }
      .width('100%')
      .height(64)
      .padding({ left: this.isWide() ? 8 : 0 })
      .margin({ top: 24 })

      Column({ space: 8 }) {
        this.navItem('全部电台', 'grid', Scope.All)
        this.navItem('我的收藏', 'heart', Scope.Favorite)
        this.navItem('国内电台', 'radio', Scope.Domestic)
        this.navItem('国际电台', 'globe', Scope.International)
      }
      .width('100%')
      .margin({ top: 24 })

      Blank()
      this.navAction('收听设置', 'settings')
    }
    .width(this.isWide() ? 200 : 76)
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 24 })
    .backgroundColor(Palette.SURFACE)
    .border({ width: { right: 1 }, color: Palette.BORDER })
  }

  @Builder
  navItem(label: string, kind: string, index: number) {
    Stack({ alignContent: Alignment.Start }) {
      Row() {
        Image(this.navIcon(kind, this.scope === index))
          .width(20)
          .height(20)
        if (this.isWide()) {
          Text(label)
            .fontSize(17)
            .fontColor(this.scope === index ? Palette.TEXT : Palette.TEXT_DIM)
            .margin({ left: 12 })
          Blank()
          Text(this.scopeCount(index))
            .fontSize(12)
            .fontColor(Palette.TEXT_FAINT)
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .height(56)
      .padding({ left: 14, right: 14 })
      .borderRadius(12)
      .backgroundColor(this.scope === index ? '#182C44' : Color.Transparent)
      .onClick(() => {
        this.setScope(index);
      })
      // 选中态左侧指示条：3×24，贴 item 左缘，上下各内缩 16
      if (this.scope === index) {
        Column()
          .width(3)
          .height(24)
          .borderRadius(2)
          .backgroundColor(Palette.BLUE)
      }
    }
    .width('100%')
    .height(56)
  }

  @Builder
  navAction(label: string, kind: string) {
    Row() {
      Image(this.navIcon(kind, false))
        .width(20)
        .height(20)
      if (this.isWide()) {
        Text(label)
          .fontSize(17)
          .fontColor(Palette.TEXT_DIM)
          .margin({ left: 12 })
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 14, right: 14 })
    .borderRadius(12)
    .onClick(() => {
      this.settingsOpen = true;
    })
  }

  // ============================== 中间列表 ==============================

  @Builder
  listPane() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row() {
          Image($r('app.media.ic_search_faint'))
            .width(19)
            .height(19)
            .margin({ right: 10 })
          TextInput({ placeholder: '搜索电台 / 省市 / 题材', text: this.searchText })
            .layoutWeight(1)
            .height(48)
            .fontSize(15)
            .fontColor(Palette.TEXT)
            .placeholderColor(Palette.TEXT_FAINT)
            .backgroundColor(Color.Transparent)
            .padding({ left: 0, right: 0 })
            .onChange((value: string) => {
              this.searchText = value;
              this.keyword = value;
              this.applyFilter();
            })
          if (this.searchText.length > 0) {
            Image($r('app.media.ic_close_faint'))
              .width(44)
              .height(44)
              .padding(14)
              .objectFit(ImageFit.Contain)
              .onClick(() => {
                this.clearSearch();
              })
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: this.searchText.length > 0 ? 2 : 16 })
        .borderRadius(24)
        .backgroundColor(Palette.SURFACE_2)
        .margin({ top: 24 })

        Row() {
          Row() {
            Image(this.filterOpen ? $r('app.media.ic_filter_blue') : $r('app.media.ic_filter_dim'))
              .width(18)
              .height(18)
            Text('筛选')
              .fontSize(15)
              .fontColor(this.filterOpen ? Palette.BLUE : Palette.TEXT_DIM)
              .margin({ left: 8, right: 8 })
            Image(this.filterOpen ? $r('app.media.ic_chevron_blue') : $r('app.media.ic_chevron_dim'))
              .width(16)
              .height(16)
              .margin({ left: 2 })
              .rotate({ angle: this.filterOpen ? 180 : 0 })
          }
          .height(48)
          .padding({ left: 16, right: 16 })
          .borderRadius(12)
          .backgroundColor(this.filterOpen ? '#182C44' : Palette.SURFACE_2)
          .onClick(() => {
            this.filterOpen = !this.filterOpen;
          })
          Text(this.filterSummary())
            .fontSize(14)
            .fontColor(Palette.TEXT_FAINT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .margin({ left: 10 })
        }
        .width('100%')
        .height(48)
        .margin({ top: 24 })

        if (this.hasFilter()) {
          Row() {
            if (this.province !== '全部') {
              this.filterTag(this.province, 'province')
            }
            if (this.genre !== '全部') {
              this.filterTag(this.genre, 'genre')
            }
          }
          .width('100%')
          .margin({ top: 12 })
        }

        Row() {
          Text('共 ')
            .fontSize(14)
            .fontColor(Palette.TEXT_DIM)
          Text(this.visible.length.toString())
            .fontSize(14)
            .fontWeight(600)
            .fontColor(Palette.TEXT)
            .margin({ left: 4, right: 4 })
          Text(' 台')
            .fontSize(14)
            .fontColor(Palette.TEXT_DIM)
        }
        .width('100%')
        .height(40)
        .margin({ top: 12 })

        if (this.visible.length === 0) {
          Column() {
            Image($r('app.media.ic_radio_border'))
              .width(44)
              .height(44)
            Text(this.scope === Scope.Favorite ? '还没有收藏的电台' : '没有找到匹配的电台')
              .fontSize(15)
              .fontColor(Palette.TEXT_DIM)
              .margin({ top: 14 })
            Text('清除筛选')
              .fontSize(14)
              .fontColor(Palette.BLUE)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .borderRadius(10)
              .backgroundColor(Palette.SURFACE_2)
              .margin({ top: 14 })
              .onClick(() => {
                this.resetFilters();
                this.clearSearch();
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 4 }) {
            ForEach(this.visible.slice(0, this.shownCount), (item: Station, index: number) => {
              ListItem() {
                this.stationRow(item, index)
              }
            }, (item: Station) => item.id.toString())
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ bottom: 16 })
          .scrollBar(BarState.Auto)
          .cachedCount(8)
          .onReachEnd(() => {
            if (this.shownCount < this.visible.length) {
              this.shownCount = Math.min(this.visible.length, this.shownCount + 50);
            }
          })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 24, right: 24 })

      if (this.filterOpen) {
        Column() {
          Column() {
            Text('省市')
            .fontSize(13)
            .fontColor(Palette.TEXT_FAINT)
            .width('100%')
            .margin({ bottom: 10 })
          Scroll() {
            Row() {
              ForEach(this.provinceOptions, (name: string) => {
                Text(name)
                  .fontSize(14)
                  .fontColor(this.province === name ? '#FFFFFF' : Palette.TEXT_DIM)
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .borderRadius(18)
                  .backgroundColor(this.province === name ? Palette.BLUE : Palette.SURFACE_2)
                  .margin({ right: 6 })
                  .onClick(() => {
                    this.setProvince(name);
                  })
              }, (name: string) => name)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .height(44)
          .margin({ bottom: 18 })

          Text('题材')
            .fontSize(13)
            .fontColor(Palette.TEXT_FAINT)
            .width('100%')
            .margin({ bottom: 10 })
          Scroll() {
            Row() {
              ForEach(this.genreOptions, (name: string) => {
                Text(name)
                  .fontSize(14)
                  .fontColor(this.genre === name ? '#FFFFFF' : Palette.TEXT_DIM)
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .borderRadius(18)
                  .backgroundColor(this.genre === name ? Palette.BLUE : Palette.SURFACE_2)
                  .margin({ right: 6 })
                  .onClick(() => {
                    this.setGenre(name);
                  })
              }, (name: string) => name)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .height(44)

          Row() {
            Text('重置')
              .fontSize(14)
              .fontColor(Palette.TEXT_DIM)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .onClick(() => {
                this.resetFilters();
              })
            Blank()
            Text('完成')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#0B1017')
              .padding({ left: 20, right: 20, top: 8, bottom: 8 })
              .borderRadius(10)
              .backgroundColor(Palette.BLUE)
              .onClick(() => {
                this.filterOpen = false;
              })
          }
          .width('100%')
          .margin({ top: 16 })
          .padding({ top: 14 })
          .border({ width: { top: 1 }, color: Palette.BORDER })
        }
        .width('100%')
        .padding(18)
          .borderRadius(16)
          .backgroundColor(Palette.SURFACE)
          .border({ width: 1, color: Palette.BORDER })
          .shadow({ radius: 20, color: 'rgba(0,0,0,0.45)', offsetX: 0, offsetY: 18 })
        }
        .width('100%')
        .position({ x: 0, y: 152 })
        .padding({ left: 24, right: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG)
  }

  @Builder
  filterTag(label: string, key: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(Palette.BLUE)
      Image($r('app.media.ic_close_blue'))
        .width(13)
        .height(13)
        .margin({ left: 6 })
    }
    .height(34)
    .padding({ left: 12, right: 10 })
    .borderRadius(17)
    .backgroundColor('#182C44')
    .margin({ right: 8 })
    .onClick(() => {
      if (key === 'province') {
        this.setProvince('全部');
      } else {
        this.setGenre('全部');
      }
    })
  }

  @Builder
  stationRow(station: Station, index: number) {
    Row() {
      // 当前行左侧指示条：3×22 绿色，非当前行透明度归零但保留占位，避免行内元素抖动
      Column()
        .width(3)
        .height(22)
        .borderRadius(2)
        .backgroundColor(Palette.GREEN)
        .opacity(this.isCurrent(station.id) ? 1 : 0)
        .margin({ right: 10 })
      Text((index + 1).toString())
        .fontSize(13)
        .fontColor(Palette.TEXT_FAINT)
        .width(26)
        .textAlign(TextAlign.Center)
      Column() {
        Text(station.name)
          .fontSize(15)
          .fontColor(this.isCurrent(station.id) ? Palette.BLUE : Palette.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Text(station.countryCode === 'CN' ? station.province : station.country)
            .fontSize(13)
            .fontColor(Palette.TEXT_DIM)
          Text(' · ')
            .fontSize(13)
            .fontColor(Palette.TEXT_FAINT)
          Text(station.genre)
            .fontSize(13)
            .fontColor(Palette.TEXT_DIM)
        }
        .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      Image(this.isFav(station.id) ? $r('app.media.ic_starf_gold') : $r('app.media.ic_star_faint'))
        .width(44)
        .height(44)
        .padding(12)
        .objectFit(ImageFit.Contain)
        .margin({ left: 10 })
        .onClick(() => {
          this.toggleFav(station);
        })
    }
    .width('100%')
    .height(60)
    .padding({ left: 12, right: 12 })
    .borderRadius(12)
    .backgroundColor(this.isCurrent(station.id) ? '#182C44' : Palette.SURFACE)
    .onClick(() => {
      this.playStation(station);
    })
  }

  // ============================== 播放器：横竖屏共用组件 ==============================

  /** 当前台信息条：台名 / 地区·题材 / 播放态 / LIVE / 收藏，横竖屏常驻字段完全一致。 */
  @Builder
  nowPlayingHeader(compact: boolean) {
    if (compact) {
      Column() {
        Text(this.current.name)
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.TEXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row() {
          Text(this.stationSubtitle())
            .fontSize(14)
            .fontColor(Palette.TEXT_DIM)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          this.stateBadge()
          this.liveTag()
          this.favoriteStar(22)
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .height(100)
    } else {
      Row() {
        Column() {
          Text(this.current.name)
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TEXT)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.stationSubtitle())
            .fontSize(14)
            .fontColor(Palette.TEXT_DIM)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 8 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row() {
          this.stateBadge()
          this.liveTag()
          this.favoriteStar(22)
        }
        .margin({ left: 16 })
      }
      .width('100%')
      .height(80)
    }
  }

  @Builder
  stateBadge() {
    Row() {
      Column()
        .width(8)
        .height(8)
        .borderRadius(4)
        .backgroundColor(this.stateColor())
        .margin({ right: 6 })
      Text(this.statusText)
        .fontSize(14)
        .fontColor(this.stateColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .height(36)
    .padding({ left: 12, right: 12 })
    .borderRadius(20)
    .backgroundColor(Palette.SURFACE_2)
    .margin({ right: 8 })
  }

  @Builder
  liveTag() {
    Text('LIVE')
      .fontSize(12)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.isPlaying() ? '#0B1017' : Palette.TEXT_DIM)
      .padding({ left: 8, right: 8, top: 5, bottom: 5 })
      .borderRadius(6)
      .backgroundColor(this.isPlaying() ? Palette.GREEN : Palette.SURFACE_2)
      .margin({ right: 8 })
  }

  @Builder
  favoriteStar(size: number) {
    Image(this.isFav(this.current.id) ? $r('app.media.ic_starf_gold') : $r('app.media.ic_star_faint'))
      .width(44)
      .height(44)
      .padding((44 - size) / 2)
      .objectFit(ImageFit.Contain)
      .onClick(() => {
        this.toggleFav(this.current);
      })
  }

  @Builder
  spectrumCanvas() {
    Canvas(this.canvasCtx)
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('#0E1723')
      .borderRadius(16)
      .onReady(() => {
        this.drawFrame();
      })
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.canvasWidth = newValue.width as number;
        this.canvasHeight = newValue.height as number;
        this.drawFrame();
      })
  }

  /** 只在播放失败时浮出，不再常驻占位置。 */
  @Builder
  errorBanner() {
    Row() {
      Image($r('app.media.ic_retry_red'))
        .width(18)
        .height(18)
        .margin({ right: 12 })
      Text(this.statusText)
        .fontSize(14)
        .fontColor(Palette.RED)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('重试')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#0B1017')
        .padding({ left: 18, right: 18, top: 8, bottom: 8 })
        .borderRadius(9)
        .backgroundColor(Palette.RED)
        .onClick(() => {
          this.service.playStation(this.current);
        })
    }
    .width('100%')
    .height(48)
    .padding({ left: 16, right: 12 })
    .borderRadius(12)
    .backgroundColor('#26F2637B')
  }

  @Builder
  primaryControls() {
    Row() {
      this.controlButton(-1, 48)
      Column() {
        Image(this.isPlaying() ? $r('app.media.ic_pause_dark') : $r('app.media.ic_play_dark'))
          .width(28)
          .height(28)
          .objectFit(ImageFit.Contain)
      }
      .width(72)
      .height(72)
      .borderRadius(36)
      .backgroundColor(this.isPlaying() ? Palette.GREEN : Palette.BLUE)
      .justifyContent(FlexAlign.Center)
      .margin({ left: 24, right: 24 })
      .onClick(() => {
        this.togglePlayback();
      })
      this.controlButton(1, 48)
    }
    .width('100%')
    .height(72)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 三个快捷开关各自独立成 Builder、不接收参数：直接读 @State，
   * 避免 @Builder 参数被缓存后出现「已开启但按钮仍显示未开启」的不刷新问题。
   */
  @Builder
  sleepQuick() {
    Row() {
      Image($r('app.media.ic_sleep_dim'))
        .width(16)
        .height(16)
        .margin({ right: 6 })
      Text(this.sleepShortLabel())
        .fontSize(14)
        .fontColor(this.sleepLeft > 0 ? Palette.GOLD : Palette.TEXT_DIM)
        .maxLines(1)
    }
    .height(40)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 12, right: 12 })
    .borderRadius(12)
    .backgroundColor(this.sleepLeft > 0 ? '#3A2E12' : Palette.SURFACE_2)
    .margin({ left: 8 })
    .onClick(() => {
      this.cycleSleep();
    })
  }

  @Builder
  randomQuick() {
    Row() {
      Image($r('app.media.ic_shuffle_dim'))
        .width(16)
        .height(16)
        .margin({ right: 6 })
      Text('随机')
        .fontSize(14)
        .fontColor(this.randomMode ? Palette.GOLD : Palette.TEXT_DIM)
        .maxLines(1)
    }
    .height(40)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 12, right: 12 })
    .borderRadius(12)
    .backgroundColor(this.randomMode ? '#3A2E12' : Palette.SURFACE_2)
    .margin({ left: 8 })
    .onClick(() => {
      this.randomMode = !this.randomMode;
      this.service.setRandom(this.randomMode);
      this.persist();
    })
  }

  @Builder
  captionQuick() {
    Row() {
      Image($r('app.media.ic_caption_dim'))
        .width(16)
        .height(16)
        .margin({ right: 6 })
      Text(this.captionOn ? '字幕开' : '字幕')
        .fontSize(14)
        .fontColor(this.captionOn ? Palette.GOLD : Palette.TEXT_DIM)
        .maxLines(1)
    }
    .height(40)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 12, right: 12 })
    .borderRadius(12)
    .backgroundColor(this.captionOn ? '#3A2E12' : Palette.SURFACE_2)
    .margin({ left: 8 })
    .onClick(() => {
      this.toggleCaption();
    })
  }

  /** 横屏一行放得下；竖屏窄栏拆成音量行 + 快捷行。 */
  @Builder
  secondaryControls(oneLine: boolean) {
    if (oneLine) {
      Row() {
        Image($r('app.media.ic_volume_dim'))
          .width(19)
          .height(19)
          .margin({ right: 10 })
        Slider({
          value: this.volume,
          min: 0,
          max: 100,
          step: 1,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .selectedColor(Palette.BLUE)
          .trackColor(Palette.SURFACE_2)
          .blockColor('#FFFFFF')
          .onChange((value: number, mode: SliderChangeMode) => {
            this.volume = Math.round(value);
            this.service.setVolume(this.volume);
            if (mode === SliderChangeMode.End) {
              this.persist();
            }
          })
        Text(this.volume.toString())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT)
          .width(44)
          .textAlign(TextAlign.End)
        this.sleepQuick()
        this.randomQuick()
        this.captionQuick()
      }
      .width('100%')
      .height(64)
    } else {
      Column({ space: 12 }) {
        Row() {
          Image($r('app.media.ic_volume_dim'))
            .width(19)
            .height(19)
            .margin({ right: 10 })
          Slider({
            value: this.volume,
            min: 0,
            max: 100,
            step: 1,
            style: SliderStyle.OutSet
          })
            .layoutWeight(1)
            .selectedColor(Palette.BLUE)
            .trackColor(Palette.SURFACE_2)
            .blockColor('#FFFFFF')
            .onChange((value: number, mode: SliderChangeMode) => {
              this.volume = Math.round(value);
              this.service.setVolume(this.volume);
              if (mode === SliderChangeMode.End) {
                this.persist();
              }
            })
          Text(this.volume.toString())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.TEXT)
            .width(44)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .height(44)
        Row() {
          this.sleepQuick()
          this.randomQuick()
          this.captionQuick()
          Blank()
        }
        .width('100%')
        .height(44)
      }
      .width('100%')
      .height(100)
    }
  }

  @Builder
  neighborCards() {
    Row() {
      this.neighborCard('上一台', '◀', this.neighborPrevName, -1)
      this.neighborCard('下一台', '▶', this.neighborNextName, 1)
    }
    .width('100%')
    .height(80)
  }

  @Builder
  playerPane() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column({ space: 20 }) {
        this.nowPlayingHeader(false)
        this.spectrumCanvas()
        if (this.playState === PlayState.Error) {
          this.errorBanner()
        }
        this.primaryControls()
        this.secondaryControls(true)
        this.neighborCards()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 24 })

      // 字幕停靠在播放栏底部：只覆盖上下台卡片一行，主控制与次级控制始终可点
      if (this.captionSupported && this.captionOn) {
        Column() {
          this.captionBar()
        }
        .margin({ right: 20, bottom: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG)
  }

  /** 竖屏播放页：信息条 / 频谱 / 主控制 / 次级控制 / 上下台，自顶部依次排布。 */
  @Builder
  portraitPlayerPane() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column({ space: 16 }) {
        this.nowPlayingHeader(true)
        this.spectrumCanvas()
        if (this.playState === PlayState.Error) {
          this.errorBanner()
        }
        this.primaryControls()
        this.secondaryControls(false)
        this.neighborCards()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 20 })

      // 字幕停靠在播放页底部（底部页签之上），不遮挡上方任何可点控件
      if (this.captionSupported && this.captionOn) {
        Column() {
          this.captionBar()
        }
        .margin({ bottom: 20 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG)
  }

  /** 系统 AI 字幕条：自带标题与关闭按钮，避免字幕出现后无法退出。 */
  @Builder
  captionBar() {
    Column() {
      Row() {
        Text('实时字幕')
          .fontSize(12)
          .fontColor(Palette.TEXT_FAINT)
        Blank()
        Image($r('app.media.ic_close_dim'))
          .width(32)
          .height(32)
          .padding(9)
          .objectFit(ImageFit.Contain)
          .onClick(() => {
            this.toggleCaption();
          })
      }
      .width('100%')
      .height(34)
      .padding({ left: 14, right: 4 })

      AICaptionComponent({
        isShown: this.captionOn,
        controller: this.captionController,
        options: this.captionOptions
      })
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 8, right: 8, bottom: 8 })
    }
    .width(this.isTablet() ? 460 : '92%')
    .height(96)
    .backgroundColor(Palette.SURFACE)
    .borderRadius(14)
    .border({ width: 1, color: Palette.BORDER })
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.5)', offsetX: 0, offsetY: 10 })
    .clip(true)
  }

  @Builder
  controlButton(delta: number, size: number) {
    Image(delta < 0 ? $r('app.media.ic_prev_white') : $r('app.media.ic_next_white'))
      .width(size)
      .height(size)
      .padding(size / 4)
      .objectFit(ImageFit.Contain)
      .borderRadius(size / 2)
      .backgroundColor(Palette.CARD)
      .onClick(() => {
        this.cutStation(delta);
      })
  }

  @Builder
  neighborCard(label: string, symbol: string, name: string, delta: number) {
    Column() {
      Row() {
        Image(symbol === '◀' ? $r('app.media.ic_prev_blue') : $r('app.media.ic_next_blue'))
          .width(13)
          .height(13)
        Text(label)
          .fontSize(13)
          .fontColor(Palette.TEXT_FAINT)
          .margin({ left: 6 })
      }
      Text(name)
        .fontSize(15)
        .fontColor(Palette.TEXT_DIM)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 8 })
    }
    .layoutWeight(1)
    .height(80)
    .padding(16)
    .margin({ right: delta < 0 ? 8 : 0, left: delta > 0 ? 8 : 0 })
    .borderRadius(12)
    .backgroundColor(Palette.CARD)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.cutStation(delta);
    })
  }

  // ============================== 设置 ==============================

  @Builder
  settingsPane() {
    Column() {
      Row() {
        Text('收听设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.TEXT)
        Blank()
        Text('完成')
          .fontSize(13)
          .fontColor(Palette.BLUE)
          .onClick(() => {
            this.settingsOpen = false;
            if (!this.isTablet()) {
              this.activePane = 1;
            }
          })
      }
      .width('100%')
      .padding({ left: 22, right: 22, top: 22, bottom: 16 })

      Scroll() {
        Column() {
          Text('音效')
            .fontSize(13)
            .fontColor(Palette.TEXT)
            .width('100%')
            .margin({ bottom: 8 })

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.soundNames, (name: string, index: number) => {
              Text(name)
                .fontSize(11)
                .fontColor(this.soundPreset === index ? '#FFFFFF' : Palette.TEXT_DIM)
                .padding({ left: 11, right: 11, top: 8, bottom: 8 })
                .borderRadius(9)
                .backgroundColor(this.soundPreset === index ? Palette.BLUE : Palette.SURFACE_2)
                .margin({ right: 6, bottom: 6 })
                .onClick(() => {
                  this.setSoundPreset(index);
                })
            }, (name: string) => name)
          }
          .width('100%')
          .margin({ bottom: 8 })

          Text(this.soundHint())
            .fontSize(11)
            .fontColor(Palette.TEXT_FAINT)
            .width('100%')
            .margin({ bottom: 12 })

          Row() {
            Text('响度')
              .fontSize(12)
              .fontColor(Palette.TEXT_DIM)
              .width(40)
            Slider({
              value: this.userGain,
              min: -12,
              max: 12,
              step: 1,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(Palette.BLUE)
              .trackColor(Palette.SURFACE_2)
              .blockColor('#FFFFFF')
              .onChange((value: number, mode: SliderChangeMode) => {
                this.userGain = Math.round(value);
                this.service.setUserGain(this.userGain);
                if (mode === SliderChangeMode.End) {
                  this.persist();
                }
              })
            Text(this.gainLabel())
              .fontSize(12)
              .fontColor(Palette.TEXT)
              .width(48)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .margin({ bottom: 6 })

          Row() {
            Text('柔和')
              .fontSize(12)
              .fontColor(Palette.TEXT_DIM)
              .width(40)
            Slider({
              value: this.userCurve,
              min: 0,
              max: 2.4,
              step: 0.1,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(Palette.BLUE)
              .trackColor(Palette.SURFACE_2)
              .blockColor('#FFFFFF')
              .onChange((value: number, mode: SliderChangeMode) => {
                this.userCurve = Math.round(value * 10) / 10;
                this.service.setUserCurve(this.userCurve);
                if (mode === SliderChangeMode.End) {
                  this.persist();
                }
              })
            Text(this.curveLabel())
              .fontSize(12)
              .fontColor(Palette.TEXT)
              .width(48)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .margin({ bottom: 14 })

          Row() {
            Text('切台渐变')
              .fontSize(13)
              .fontColor(Palette.TEXT)
              .margin({ right: 10 })
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.fadeNames, (name: string, index: number) => {
                Text(name)
                  .fontSize(11)
                  .fontColor(this.fadePreset === index ? '#FFFFFF' : Palette.TEXT_DIM)
                  .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                  .borderRadius(9)
                  .backgroundColor(this.fadePreset === index ? Palette.BLUE : Palette.SURFACE_2)
                  .margin({ right: 6, bottom: 6 })
                  .onClick(() => {
                    this.setFadePreset(index);
                  })
              }, (name: string) => name)
            }
            .layoutWeight(1)
          }
          .width('100%')
          .margin({ bottom: 14 })

          Row() {
            Text('系统音效')
              .fontSize(13)
              .fontColor(Palette.TEXT)
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.systemEffect })
              .selectedColor(Palette.BLUE)
              .onChange((isOn: boolean) => {
                this.setSystemEffect(isOn);
              })
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor(Palette.SURFACE_2)
          .margin({ bottom: 18 })

          Row() {
            Text('频谱来源')
              .fontSize(13)
              .fontColor(Palette.TEXT)
            Blank()
            Text('模拟')
              .fontSize(12)
              .fontColor(this.vizMode === 0 ? '#FFFFFF' : Palette.TEXT_DIM)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.vizMode === 0 ? Palette.BLUE : Palette.SURFACE_2)
              .onClick(() => {
                this.setVizMode(0);
              })
            Text('真实')
              .fontSize(12)
              .fontColor(this.vizMode === 1 ? '#FFFFFF' : Palette.TEXT_DIM)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.vizMode === 1 ? Palette.BLUE : Palette.SURFACE_2)
              .margin({ left: 8 })
              .onClick(() => {
                this.setVizMode(1);
              })
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor(Palette.SURFACE_2)
          .margin({ bottom: 6 })

          if (this.vizMode === 1) {
            Text(this.vizHint.length > 0 ? this.vizHint : '从电台音频流实时解析，不采集麦克风')
              .fontSize(11)
              .fontColor(Palette.TEXT_FAINT)
              .width('100%')
              .margin({ bottom: 10 })
          }

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(VIZ_NAMES, (name: string, index: number) => {
              Text(name)
                .fontSize(11)
                .fontColor(this.vizStyle === index ? '#FFFFFF' : Palette.TEXT_DIM)
                .padding({ left: 11, right: 11, top: 8, bottom: 8 })
                .borderRadius(9)
                .backgroundColor(this.vizStyle === index ? Palette.BLUE : Palette.SURFACE_2)
                .margin({ right: 6, bottom: 6 })
                .onClick(() => {
                  this.vizStyle = index;
                  this.painter.setStyle(index);
                  this.persist();
                  this.drawFrame();
                })
            }, (name: string) => name)
          }
          .width('100%')
          .margin({ bottom: 18 })

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(THEME_NAMES, (name: string, index: number) => {
              Row() {
                Row() {
                  ForEach(themeColors(index), (color: string) => {
                    Column()
                      .width(6)
                      .height(12)
                      .backgroundColor(color)
                  }, (color: string, i: number) => color + i.toString())
                }
                .margin({ right: 7 })
                Text(name)
                  .fontSize(11)
                  .fontColor(this.colorTheme === index ? Palette.TEXT : Palette.TEXT_DIM)
              }
              .padding({ left: 8, right: 10, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.colorTheme === index ? '#1B3350' : Palette.SURFACE_2)
              .border({ width: 1, color: this.colorTheme === index ? Palette.BLUE : Color.Transparent })
              .margin({ right: 6, bottom: 6 })
              .onClick(() => {
                this.colorTheme = index;
                this.painter.setTheme(index);
                this.persist();
                this.drawFrame();
              })
            }, (name: string) => name)
          }
          .width('100%')
          .margin({ bottom: 18 })

          Row() {
            ForEach([0, 20, 40, 60, 80, 100], (level: number) => {
              Text(level.toString())
                .fontSize(11)
                .fontColor(this.volume === level ? '#FFFFFF' : Palette.TEXT_DIM)
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .borderRadius(9)
                .backgroundColor(this.volume === level ? Palette.BLUE : Palette.SURFACE_2)
                .margin({ right: 6 })
                .onClick(() => {
                  this.changeVolume(level);
                })
            }, (level: number) => level.toString())
          }
          .width('100%')
          .margin({ bottom: 18 })

          Row() {
            Text('随机切台')
              .fontSize(13)
              .fontColor(Palette.TEXT)
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.randomMode })
              .selectedColor(Palette.BLUE)
              .onChange((isOn: boolean) => {
                this.randomMode = isOn;
                this.service.setRandom(isOn);
                this.persist();
              })
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor(Palette.SURFACE_2)
          .margin({ bottom: 18 })

          if (this.captionSupported) {
            Row() {
              Text('实时字幕')
                .fontSize(13)
                .fontColor(Palette.TEXT)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.captionOn })
                .selectedColor(Palette.BLUE)
                .onChange((isOn: boolean) => {
                  this.captionOn = isOn;
                  this.statusText = isOn ? '正在开启字幕' : '字幕已关闭';
                })
            }
            .width('100%')
            .padding(14)
            .borderRadius(12)
            .backgroundColor(Palette.SURFACE_2)
            .margin({ bottom: 18 })
          }

          Row() {
            ForEach(SLEEP_OPTIONS, (minutes: number) => {
              Text(minutes === 0 ? '关闭' : minutes.toString() + ' 分')
                .fontSize(11)
                .fontColor(this.sleepMinutes === minutes ? '#FFFFFF' : Palette.TEXT_DIM)
                .padding({ left: 11, right: 11, top: 8, bottom: 8 })
                .borderRadius(9)
                .backgroundColor(this.sleepMinutes === minutes ? Palette.BLUE : Palette.SURFACE_2)
                .margin({ right: 6 })
                .onClick(() => {
                  this.startSleep(minutes);
                })
            }, (minutes: number) => minutes.toString())
          }
          .width('100%')
          .margin({ bottom: 18 })

          Column()
            .width('100%')
            .height(24)
        }
        .width('100%')
        .padding({ left: 22, right: 22 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.SURFACE)
  }

  // ============================== 窄屏底部页签 ==============================

  @Builder
  bottomTabs() {
    Row() {
      this.tabItem('电台', 'list', 0)
      this.tabItem('播放', 'radio', 1)
      this.tabItem('设置', 'settings', 2)
    }
    .width('100%')
    .height(96)
    .backgroundColor(Palette.SURFACE)
    .border({ width: { top: 1 }, color: Palette.BORDER })
  }

  @Builder
  tabItem(label: string, kind: string, index: number) {
    Column() {
      Image(this.navIcon(kind, this.activePane === index))
        .width(22)
        .height(22)
      Text(label)
        .fontSize(14)
        .fontColor(this.activePane === index ? Palette.BLUE : Palette.TEXT_DIM)
        .margin({ top: 6 })
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.activePane = index;
    })
  }
}
