import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { AICaptionComponent, AICaptionController, AICaptionOptions } from '@kit.SpeechKit';
import { CaptionLog, CaptionRecord } from '../model/CaptionLog';
import {
  Station, Scope, Palette, SCOPE_NAMES, VIZ_NAMES, THEME_NAMES, SLEEP_OPTIONS, themeColors
} from '../model/Station';
import { ALL_STATIONS } from '../model/StationData';
import { RadioStore } from '../model/RadioStore';
import { RadioPlayer, PlayState } from '../player/RadioPlayer';
import { SpectrumPainter } from '../view/SpectrumPainter';

/** 主页面：平板三栏（导航 / 电台列表 / 播放器），窄屏自动降级为单栏 + 底部页签。 */
@Entry
@Component
struct Index {
  @State windowWidth: number = 1200;
  @State topPad: number = 0;
  @State activePane: number = 0;
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
  @State playState: PlayState = PlayState.Idle;
  @State statusText: string = '准备就绪';
  @State volume: number = 60;
  @State vizStyle: number = 0;
  @State colorTheme: number = 0;
  @State randomMode: boolean = false;
  @State sleepMinutes: number = 0;
  @State sleepLeft: number = 0;
  @State settingsOpen: boolean = false;
  @State clock: string = '';
  @State captionOn: boolean = false;
  @State captionLogOpen: boolean = false;
  @State captionRecords: CaptionRecord[] = [];
  @State captionInput: string = '';

  private captionLog: CaptionLog = new CaptionLog();

  /** 系统 AI 字幕能力：端侧识别，无需任何云端密钥。 */
  private captionSupported: boolean = canIUse('SystemCapability.AI.AICaption');
  private captionController: AICaptionController = new AICaptionController();
  private captionOptions: AICaptionOptions = {
    initialOpacity: 0.86,
    onPrepared: (): void => {
      this.statusText = '字幕已就绪';
    },
    onError: (err: BusinessError): void => {
      this.captionOn = false;
      this.statusText = '字幕不可用：' + err.code.toString();
    }
  };

  private store: RadioStore = RadioStore.getInstance();
  private player: RadioPlayer = new RadioPlayer();
  private painter: SpectrumPainter = new SpectrumPainter();
  private renderSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.renderSettings);
  private canvasWidth: number = 520;
  private canvasHeight: number = 150;
  private animationTimer: number = -1;
  private secondTimer: number = -1;
  private sleepEnd: number = 0;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store.init(ctx);
    this.captionLog.init(ctx);
    this.captionRecords = this.captionLog.all();
    const cfg = this.store.config;
    this.current = this.store.findById(cfg.lastId);
    this.favorites = cfg.favorites.slice();
    this.volume = cfg.volume;
    this.vizStyle = cfg.vizStyle;
    this.colorTheme = cfg.colorTheme;
    this.randomMode = cfg.random;
    this.sleepMinutes = 0;
    this.scope = cfg.scope;
    this.province = cfg.province;
    this.genre = cfg.genre;
    this.provinceOptions = this.store.provinces();
    this.genreOptions = this.store.genres();
    this.player.onState = (state: PlayState, message: string): void => {
      this.playState = state;
      this.statusText = message;
    };
    this.player.setVolume(this.volume);
    this.applyFilter(true);
    this.observeWindow();
    this.updateClock();
    this.animationTimer = setInterval(() => {
      this.painter.tick(this.isPlaying());
      this.drawFrame();
    }, 160);
    this.secondTimer = setInterval(() => {
      this.updateClock();
      this.tickSleep();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.animationTimer >= 0) {
      clearInterval(this.animationTimer);
    }
    if (this.secondTimer >= 0) {
      clearInterval(this.secondTimer);
    }
    this.player.release();
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

  private tickSleep(): void {
    if (this.sleepEnd <= 0) {
      return;
    }
    const left: number = Math.max(0, Math.ceil((this.sleepEnd - Date.now()) / 1000));
    this.sleepLeft = left;
    if (left <= 0) {
      this.sleepEnd = 0;
      this.sleepMinutes = 0;
      this.player.stop();
      this.statusText = '睡眠定时结束';
      this.persist();
    }
  }

  private sleepLabel(): string {
    if (this.sleepLeft <= 0) {
      return '定时关闭';
    }
    const minutes: number = Math.floor(this.sleepLeft / 60);
    const seconds: number = this.sleepLeft % 60;
    return minutes.toString() + ':' + (seconds < 10 ? '0' : '') + seconds.toString() + ' 后关闭';
  }

  private drawFrame(): void {
    this.painter.draw(this.canvasCtx, this.canvasWidth, this.canvasHeight,
      this.vizStyle, this.colorTheme, this.isPlaying());
  }

  private applyFilter(skipSave: boolean = false): void {
    this.visible = this.store.filter(this.scope, this.keyword, this.province, this.genre);
    this.shownCount = 50;
    if (!skipSave) {
      this.persist();
    }
  }

  private persist(): void {
    const cfg = this.store.config;
    cfg.lastId = this.current.id;
    cfg.volume = this.volume;
    cfg.vizStyle = this.vizStyle;
    cfg.colorTheme = this.colorTheme;
    cfg.random = this.randomMode;
    cfg.sleepMinutes = 0;
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
    this.scope = Scope.All;
    this.scopeNames = SCOPE_NAMES.slice();
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

  private playStation(station: Station): void {
    this.current = station;
    this.persist();
    this.player.play(station.url);
  }

  private cutStation(delta: number): void {
    const queue: Station[] = this.visible.length > 0 ? this.visible : this.store.all;
    let at: number = -1;
    for (let i = 0; i < queue.length; i++) {
      if (queue[i].id === this.current.id) {
        at = i;
        break;
      }
    }
    if (at < 0) {
      at = 0;
    }
    const next: number = this.randomMode
      ? Math.floor(Math.random() * queue.length)
      : (at + delta + queue.length) % queue.length;
    this.playStation(queue[next]);
  }

  private neighborName(delta: number): string {
    const queue: Station[] = this.visible.length > 0 ? this.visible : this.store.all;
    for (let i = 0; i < queue.length; i++) {
      if (queue[i].id === this.current.id) {
        const at: number = (i + delta + queue.length) % queue.length;
        return queue[at].name;
      }
    }
    return queue.length > 0 ? queue[0].name : '—';
  }

  private togglePlayback(): void {
    if (!this.player.toggle()) {
      this.player.play(this.current.url);
    }
  }

  private toggleFav(station: Station): void {
    this.store.toggleFavorite(station.id);
    this.favorites = this.store.config.favorites.slice();
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
    this.sleepMinutes = minutes;
    if (minutes <= 0) {
      this.sleepEnd = 0;
      this.sleepLeft = 0;
    } else {
      this.sleepEnd = Date.now() + minutes * 60000;
      this.sleepLeft = minutes * 60;
    }
    this.persist();
  }

  private changeVolume(level: number): void {
    this.volume = Math.max(0, Math.min(100, Math.round(level)));
    this.player.setVolume(this.volume);
    this.persist();
  }

  private paneWidth(): string {
    return this.isWide() ? '33%' : '38%';
  }

  // ============================== 字幕记录 ==============================

  private openCaptionLog(): void {
    this.settingsOpen = false;
    this.captionRecords = this.captionLog.all();
    this.captionLogOpen = true;
  }

  private saveCaption(): void {
    this.captionRecords = this.captionLog.add(this.current.name, this.captionInput);
    this.captionInput = '';
  }

  private clearCaptions(): void {
    this.captionRecords = this.captionLog.clear();
  }

  private copyCaptions(): void {
    const text: string = this.captionLog.exportText();
    if (text.length === 0) {
      this.statusText = '暂无记录';
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.statusText = '已复制 ' + this.captionRecords.length.toString() + ' 条';
      });
    } catch (e) {
      this.statusText = '复制失败';
    }
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
        .width(370)
        .height('100%')
        .backgroundColor(Palette.SURFACE)
        .border({ width: { left: 1 }, color: Palette.BORDER })
      }

      // 系统 AI 字幕：isShown=true 时自动识别本应用正在播放的音频（API 18+），无需传 PCM。
      if (this.captionSupported && this.captionOn) {
        Column() {
          AICaptionComponent({
            isShown: this.captionOn,
            controller: this.captionController,
            options: this.captionOptions
          })
        }
        .width(this.isTablet() ? '40%' : '92%')
        .height(150)
        .position({ x: this.isTablet() ? '56%' : '4%', y: '66%' })
      }

      if (this.captionLogOpen) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#A6000000')
          .onClick(() => {
            this.captionLogOpen = false;
          })
        Column() {
          this.captionLogPane()
        }
        .width(this.isTablet() ? 460 : '92%')
        .height('86%')
        .backgroundColor(Palette.SURFACE)
        .borderRadius(20)
        .border({ width: 1, color: Palette.BORDER })
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
          .borderRadius(10)
        if (this.isWide()) {
          Text('收音机')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TEXT)
            .margin({ left: 10 })
        }
      }
      .width('100%')
      .padding({ left: this.isWide() ? 18 : 14, top: 22, bottom: 22 })

      this.navItem('全部电台', '▦', Scope.All)
      this.navItem('我的收藏', '★', Scope.Favorite)
      this.navItem('国内电台', '◉', Scope.Domestic)
      this.navItem('国际电台', '✦', Scope.International)

      Divider()
        .color(Palette.BORDER)
        .width('70%')
        .margin({ top: 16, bottom: 16 })

      this.navAction('收听设置', '⚙')

      Blank()
    }
    .width(this.isWide() ? 218 : 76)
    .height('100%')
    .backgroundColor(Palette.SURFACE)
    .border({ width: { right: 1 }, color: Palette.BORDER })
  }

  @Builder
  navItem(label: string, icon: string, index: number) {
    Row() {
      Text(icon)
        .fontSize(17)
        .fontColor(this.scope === index ? Palette.BLUE : Palette.TEXT_DIM)
        .width(24)
        .textAlign(TextAlign.Center)
      if (this.isWide()) {
        Text(label)
          .fontSize(14)
          .fontColor(this.scope === index ? Palette.TEXT : Palette.TEXT_DIM)
          .fontWeight(this.scope === index ? FontWeight.Medium : FontWeight.Normal)
          .margin({ left: 10 })
        Blank()
        if (index === Scope.Favorite) {
          Text(this.favorites.length.toString())
            .fontSize(11)
            .fontColor(this.scope === index ? Palette.BLUE : Palette.TEXT_FAINT)
        }
      }
    }
    .width('100%')
    .height(46)
    .padding({ left: this.isWide() ? 16 : 12, right: this.isWide() ? 16 : 12 })
    .borderRadius(12)
    .backgroundColor(this.scope === index ? '#182C44' : Color.Transparent)
    .margin({ left: this.isWide() ? 10 : 8, right: this.isWide() ? 10 : 8, bottom: 4 })
    .onClick(() => {
      this.setScope(index);
    })
  }

  @Builder
  navAction(label: string, icon: string) {
    Row() {
      Text(icon)
        .fontSize(17)
        .fontColor(Palette.TEXT_DIM)
        .width(24)
        .textAlign(TextAlign.Center)
      if (this.isWide()) {
        Text(label)
          .fontSize(14)
          .fontColor(Palette.TEXT_DIM)
          .margin({ left: 10 })
      }
    }
    .width('100%')
    .height(46)
    .padding({ left: this.isWide() ? 16 : 12 })
    .borderRadius(12)
    .margin({ left: this.isWide() ? 10 : 8, right: this.isWide() ? 10 : 8 })
    .onClick(() => {
      this.settingsOpen = true;
    })
  }

  // ============================== 中间列表 ==============================

  @Builder
  listPane() {
    Column() {
      Row() {
        Text('电台')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.TEXT)
        Blank()
        Text(this.clock)
          .fontSize(13)
          .fontColor(Palette.TEXT_DIM)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 14 })

      Row() {
        Text('⌕')
          .fontSize(18)
          .fontColor(Palette.TEXT_FAINT)
          .margin({ left: 12, right: 6 })
        TextInput({ placeholder: '搜索电台、城市或题材', text: this.searchText })
          .layoutWeight(1)
          .height(38)
          .fontSize(13)
          .fontColor(Palette.TEXT)
          .placeholderColor(Palette.TEXT_FAINT)
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => {
            this.searchText = value;
            this.keyword = value;
            this.applyFilter();
          })
        if (this.searchText.length > 0) {
          Text('×')
            .fontSize(20)
            .fontColor(Palette.TEXT_DIM)
            .margin({ right: 10 })
            .onClick(() => {
              this.clearSearch();
            })
        }
      }
      .width('100%')
      .height(44)
      .margin({ left: 16, right: 16, bottom: 12 })
      .borderRadius(12)
      .backgroundColor(Palette.SURFACE_2)

      Row() {
        ForEach(this.scopeNames, (name: string, index: number) => {
          Text(name)
            .fontSize(12)
            .fontColor(this.scope === index ? '#FFFFFF' : Palette.TEXT_DIM)
            .fontWeight(this.scope === index ? FontWeight.Medium : FontWeight.Normal)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(16)
            .backgroundColor(this.scope === index ? Palette.BLUE : Palette.SURFACE_2)
            .margin({ right: 6 })
            .onClick(() => {
              this.setScope(index);
            })
        }, (name: string) => name)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .margin({ bottom: 10 })

      Scroll() {
        Row() {
          ForEach(this.provinceOptions, (name: string) => {
            Text(name)
              .fontSize(12)
              .fontColor(this.province === name ? '#FFFFFF' : Palette.TEXT_DIM)
              .fontWeight(this.province === name ? FontWeight.Medium : FontWeight.Normal)
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(16)
              .backgroundColor(this.province === name ? Palette.BLUE : Palette.SURFACE_2)
              .margin({ right: 6 })
              .onClick(() => {
                this.setProvince(name);
              })
          }, (name: string) => name)
        }
        .padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ bottom: 8 })

      Scroll() {
        Row() {
          ForEach(this.genreOptions, (name: string) => {
            Text(name)
              .fontSize(12)
              .fontColor(this.genre === name ? '#FFFFFF' : Palette.TEXT_DIM)
              .fontWeight(this.genre === name ? FontWeight.Medium : FontWeight.Normal)
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(16)
              .backgroundColor(this.genre === name ? Palette.BLUE : Palette.SURFACE_2)
              .margin({ right: 6 })
              .onClick(() => {
                this.setGenre(name);
              })
          }, (name: string) => name)
        }
        .padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ bottom: 10 })

      Row() {
        Text('共 ' + this.visible.length.toString() + ' 台')
          .fontSize(12)
          .fontColor(Palette.TEXT_DIM)
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 8 })

      if (this.visible.length === 0) {
        Column() {
          Text('◌')
            .fontSize(40)
            .fontColor(Palette.BORDER)
          Text(this.scope === Scope.Favorite ? '还没有收藏的电台' : '没有找到匹配的电台')
            .fontSize(13)
            .fontColor(Palette.TEXT_DIM)
            .margin({ top: 10 })
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
        .padding({ left: 12, right: 12, bottom: 10 })
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
    .backgroundColor(Palette.BG)
  }

  @Builder
  stationRow(station: Station, index: number) {
    Row() {
      Text((index + 1).toString())
        .fontSize(11)
        .fontColor(Palette.TEXT_FAINT)
        .width(30)
        .textAlign(TextAlign.Center)
      Column() {
        Text(station.name)
          .fontSize(14)
          .fontWeight(this.isCurrent(station.id) ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.isCurrent(station.id) ? Palette.BLUE : Palette.TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Text(station.countryCode === 'CN' ? station.province : station.country)
            .fontSize(10)
            .fontColor(Palette.TEXT_DIM)
          Text(' · ')
            .fontSize(10)
            .fontColor(Palette.TEXT_FAINT)
          Text(station.genre)
            .fontSize(10)
            .fontColor(Palette.TEXT_DIM)
        }
        .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.isCurrent(station.id) && this.isPlaying()) {
        Text('▶')
          .fontSize(11)
          .fontColor(Palette.GREEN)
          .margin({ right: 8 })
      }
      Text(this.isFav(station.id) ? '★' : '☆')
        .fontSize(17)
        .fontColor(this.isFav(station.id) ? Palette.GOLD : Palette.TEXT_FAINT)
        .width(30)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.toggleFav(station);
        })
    }
    .width('100%')
    .height(60)
    .padding({ left: 8, right: 8 })
    .borderRadius(12)
    .backgroundColor(this.isCurrent(station.id) ? '#182C44' : Palette.SURFACE)
    .onClick(() => {
      this.playStation(station);
    })
  }

  // ============================== 右侧播放器 ==============================

  @Builder
  playerPane() {
    Scroll() {
      Column() {
        Row() {
          Blank()
          Row() {
            Text('●')
              .fontSize(10)
              .fontColor(this.stateColor())
              .margin({ right: 6 })
            Text(this.statusText)
              .fontSize(12)
              .fontColor(this.stateColor())
          }
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor(Palette.SURFACE_2)
          .margin({ right: 10 })
          Text('⚙')
            .fontSize(19)
            .fontColor(Palette.TEXT_DIM)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.settingsOpen = true;
            })
        }
        .width('100%')
        .padding({ top: 20, bottom: 16 })

        Column() {
          Row() {
            Text('LIVE')
              .fontSize(10)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.isPlaying() ? '#0B1017' : Palette.TEXT_DIM)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(5)
              .backgroundColor(this.isPlaying() ? Palette.GREEN : Palette.SURFACE_2)
            Text(this.current.countryCode === 'CN' ? this.current.province : this.current.country)
              .fontSize(11)
              .fontColor(Palette.TEXT_DIM)
              .margin({ left: 10 })
            Text('·')
              .fontSize(11)
              .fontColor(Palette.TEXT_FAINT)
              .margin({ left: 6, right: 6 })
            Text(this.current.genre)
              .fontSize(11)
              .fontColor(Palette.TEXT_DIM)
            Blank()
            Text(this.isFav(this.current.id) ? '★' : '☆')
              .fontSize(22)
              .fontColor(this.isFav(this.current.id) ? Palette.GOLD : Palette.TEXT_FAINT)
              .onClick(() => {
                this.toggleFav(this.current);
              })
          }
          .width('100%')

          Text(this.current.name)
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TEXT)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 18, bottom: 16 })

          Canvas(this.canvasCtx)
            .width('100%')
            .height(150)
            .backgroundColor('#0E1723')
            .borderRadius(12)
            .onReady(() => {
              this.drawFrame();
            })
            .onAreaChange((oldValue: Area, newValue: Area) => {
              this.canvasWidth = newValue.width as number;
              this.canvasHeight = newValue.height as number;
              this.drawFrame();
            })

          Row() {
            this.controlButton('◀', 46, false)
            Column() {
              Text(this.isPlaying() ? '❚❚' : '▶')
                .fontSize(26)
                .fontColor('#0B1017')
                .textAlign(TextAlign.Center)
            }
            .width(72)
            .height(72)
            .borderRadius(36)
            .backgroundColor(this.isPlaying() ? Palette.GREEN : Palette.BLUE)
            .justifyContent(FlexAlign.Center)
            .margin({ left: 16, right: 16 })
            .onClick(() => {
              this.togglePlayback();
            })
            this.controlButton('▶', 46, false)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 14, bottom: 16 })

          Row() {
            Text('随机')
              .fontSize(11)
              .fontColor(this.randomMode ? Palette.GOLD : Palette.TEXT_DIM)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .backgroundColor(this.randomMode ? '#3A2E12' : Palette.SURFACE_2)
              .onClick(() => {
                this.randomMode = !this.randomMode;
                this.persist();
              })
            Text(this.sleepLabel())
              .fontSize(11)
              .fontColor(this.sleepLeft > 0 ? Palette.GOLD : Palette.TEXT_DIM)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .backgroundColor(Palette.SURFACE_2)
              .margin({ left: 10 })
              .onClick(() => {
                this.settingsOpen = true;
              })
            Blank()
            Text('重试')
              .fontSize(11)
              .fontColor(Palette.TEXT_DIM)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .backgroundColor(Palette.SURFACE_2)
              .onClick(() => {
                this.player.play(this.current.url);
              })
          }
          .width('100%')
          .margin({ bottom: 18 })

          Row() {
            Text('音量')
              .fontSize(12)
              .fontColor(Palette.TEXT_DIM)
              .width(36)
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
                this.player.setVolume(this.volume);
                if (mode === SliderChangeMode.End) {
                  this.persist();
                }
              })
            Text(this.volume.toString())
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Palette.TEXT)
              .width(38)
              .textAlign(TextAlign.End)
          }
          .width('100%')
        }
        .width('100%')
        .padding(22)
        .borderRadius(22)
        .backgroundColor(Palette.SURFACE)
        .border({ width: 1, color: Palette.BORDER })

        Row() {
          this.neighborCard('上一台', '◀', this.neighborName(-1), -1)
          this.neighborCard('下一台', '▶', this.neighborName(1), 1)
        }
        .width('100%')
        .margin({ top: 14 })
      }
      .width('100%')
      .padding({
        left: this.isWide() ? 26 : 18,
        right: this.isWide() ? 26 : 18,
        bottom: 22
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  /** 竖屏播放器：整屏垂直布局，内容自顶部依次排布，频谱占满剩余高度。 */
  @Builder
  portraitPlayerPane() {
    Column() {
      Row() {
        Row() {
          Text('●')
            .fontSize(10)
            .fontColor(this.stateColor())
            .margin({ right: 6 })
          Text(this.statusText)
            .fontSize(12)
            .fontColor(this.stateColor())
        }
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .borderRadius(16)
        .backgroundColor(Palette.SURFACE_2)
        Blank()
        Text('⚙')
          .fontSize(19)
          .fontColor(Palette.TEXT_DIM)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.settingsOpen = true;
          })
      }
      .width('100%')
      .margin({ top: 8, bottom: 20 })

      Row() {
        Text('LIVE')
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isPlaying() ? '#0B1017' : Palette.TEXT_DIM)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(5)
          .backgroundColor(this.isPlaying() ? Palette.GREEN : Palette.SURFACE_2)
        Text(this.current.countryCode === 'CN' ? this.current.province : this.current.country)
          .fontSize(12)
          .fontColor(Palette.TEXT_DIM)
          .margin({ left: 10 })
        Text('·')
          .fontSize(12)
          .fontColor(Palette.TEXT_FAINT)
          .margin({ left: 6, right: 6 })
        Text(this.current.genre)
          .fontSize(12)
          .fontColor(Palette.TEXT_DIM)
        Blank()
        Text(this.isFav(this.current.id) ? '★' : '☆')
          .fontSize(24)
          .fontColor(this.isFav(this.current.id) ? Palette.GOLD : Palette.TEXT_FAINT)
          .onClick(() => {
            this.toggleFav(this.current);
          })
      }
      .width('100%')

      Text(this.current.name)
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TEXT)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 18, bottom: 18 })

      Canvas(this.canvasCtx)
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#0E1723')
        .borderRadius(18)
        .onReady(() => {
          this.drawFrame();
        })
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.canvasWidth = newValue.width as number;
          this.canvasHeight = newValue.height as number;
          this.drawFrame();
        })

      Row() {
        this.controlButton('◀', 46, false)
        Column() {
          Text(this.isPlaying() ? '❚❚' : '▶')
            .fontSize(26)
            .fontColor('#0B1017')
            .textAlign(TextAlign.Center)
        }
        .width(72)
        .height(72)
        .borderRadius(36)
        .backgroundColor(this.isPlaying() ? Palette.GREEN : Palette.BLUE)
        .justifyContent(FlexAlign.Center)
        .margin({ left: 16, right: 16 })
        .onClick(() => {
          this.togglePlayback();
        })
        this.controlButton('▶', 46, false)
      }
      .width('100%')
      .height(72)
      .justifyContent(FlexAlign.Center)
      .margin({ top: 20, bottom: 18 })

      Row() {
        Text('随机')
          .fontSize(12)
          .fontColor(this.randomMode ? Palette.GOLD : Palette.TEXT_DIM)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(16)
          .backgroundColor(this.randomMode ? '#3A2E12' : Palette.SURFACE_2)
          .onClick(() => {
            this.randomMode = !this.randomMode;
            this.persist();
          })
        Text(this.sleepLabel())
          .fontSize(12)
          .fontColor(this.sleepLeft > 0 ? Palette.GOLD : Palette.TEXT_DIM)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(16)
          .backgroundColor(Palette.SURFACE_2)
          .margin({ left: 10 })
          .onClick(() => {
            this.settingsOpen = true;
          })
        Blank()
        Text('重试')
          .fontSize(12)
          .fontColor(Palette.TEXT_DIM)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(16)
          .backgroundColor(Palette.SURFACE_2)
          .onClick(() => {
            this.player.play(this.current.url);
          })
      }
      .width('100%')
      .margin({ bottom: 18 })

      Row() {
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
            this.player.setVolume(this.volume);
            if (mode === SliderChangeMode.End) {
              this.persist();
            }
          })
        Text(this.volume.toString())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TEXT)
          .width(40)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ bottom: 16 })

      Row() {
        this.neighborCard('上一台', '◀', this.neighborName(-1), -1)
        this.neighborCard('下一台', '▶', this.neighborName(1), 1)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ left: 18, right: 18, top: 8, bottom: 18 })
  }

  @Builder
  controlButton(symbol: string, size: number, primary: boolean) {
    Text(symbol)
      .fontSize(19)
      .fontColor(Palette.TEXT)
      .width(size)
      .height(size)
      .borderRadius(size / 2)
      .backgroundColor(Palette.CARD)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.cutStation(symbol === '◀' ? -1 : 1);
      })
  }

  @Builder
  neighborCard(label: string, symbol: string, name: string, delta: number) {
    Column() {
      Row() {
        Text(symbol)
          .fontSize(10)
          .fontColor(Palette.BLUE)
        Text(label)
          .fontSize(10)
          .fontColor(Palette.TEXT_FAINT)
          .margin({ left: 5 })
      }
      Text(name)
        .fontSize(12)
        .fontColor(Palette.TEXT_DIM)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 6 })
    }
    .layoutWeight(1)
    .padding(12)
    .margin({ right: delta < 0 ? 6 : 0, left: delta > 0 ? 6 : 0 })
    .borderRadius(12)
    .backgroundColor(Palette.SURFACE)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.cutStation(delta);
    })
  }

  /** 字幕记录本：粘贴 / 输入字幕内容并落盘，支持查看、复制全部与清空。 */
  @Builder
  captionLogPane() {
    Column() {
      Row() {
        Text('字幕记录')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.TEXT)
        Blank()
        Text('关闭')
          .fontSize(13)
          .fontColor(Palette.BLUE)
          .onClick(() => {
            this.captionLogOpen = false;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 14 })

      TextInput({ placeholder: '粘贴或输入字幕内容', text: this.captionInput })
        .fontSize(13)
        .fontColor(Palette.TEXT)
        .placeholderColor(Palette.TEXT_FAINT)
        .backgroundColor(Palette.SURFACE_2)
        .height(42)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
        .width('100%')
        .margin({ left: 20, right: 20 })
        .onChange((value: string) => {
          this.captionInput = value;
        })

      Row() {
        Text('保存')
          .fontSize(12)
          .fontColor('#FFFFFF')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(9)
          .backgroundColor(Palette.BLUE)
          .onClick(() => {
            this.saveCaption();
          })
        Text('复制全部')
          .fontSize(12)
          .fontColor(Palette.TEXT_DIM)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(9)
          .backgroundColor(Palette.SURFACE_2)
          .margin({ left: 8 })
          .onClick(() => {
            this.copyCaptions();
          })
        Blank()
        Text('清空')
          .fontSize(12)
          .fontColor(Palette.TEXT_FAINT)
          .onClick(() => {
            this.clearCaptions();
          })
      }
      .width('100%')
      .margin({ top: 12, bottom: 12 })
      .padding({ left: 20, right: 20 })

      Scroll() {
        Column() {
          if (this.captionRecords.length === 0) {
            Text('暂无记录')
              .fontSize(12)
              .fontColor(Palette.TEXT_FAINT)
              .margin({ top: 40 })
          }
          ForEach(this.captionRecords.slice().reverse(), (rec: CaptionRecord) => {
            Column() {
              Text(rec.time + '  ' + rec.station)
                .fontSize(10)
                .fontColor(Palette.TEXT_FAINT)
              Text(rec.text)
                .fontSize(13)
                .fontColor(Palette.TEXT)
                .width('100%')
                .margin({ top: 5 })
            }
            .width('100%')
            .padding(12)
            .borderRadius(10)
            .backgroundColor(Palette.SURFACE_2)
            .alignItems(HorizontalAlign.Start)
            .margin({ bottom: 8 })
          }, (rec: CaptionRecord) => rec.time + rec.text)
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
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
          Row() {
            Text('字幕记录')
              .fontSize(13)
              .fontColor(Palette.TEXT)
            Blank()
            Text(this.captionRecords.length.toString() + ' 条 ›')
              .fontSize(12)
              .fontColor(Palette.BLUE)
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor(Palette.SURFACE_2)
          .margin({ bottom: 18 })
          .onClick(() => {
            this.openCaptionLog();
          })

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
      this.tabItem('电台', '▦', 0)
      this.tabItem('播放', '▶', 1)
      this.tabItem('设置', '⚙', 2)
    }
    .width('100%')
    .height(64)
    .backgroundColor(Palette.SURFACE)
    .border({ width: { top: 1 }, color: Palette.BORDER })
  }

  @Builder
  tabItem(label: string, icon: string, index: number) {
    Column() {
      Text(icon)
        .fontSize(17)
        .fontColor(this.activePane === index ? Palette.BLUE : Palette.TEXT_DIM)
      Text(label)
        .fontSize(10)
        .fontColor(this.activePane === index ? Palette.BLUE : Palette.TEXT_DIM)
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.activePane = index;
    })
  }
}
