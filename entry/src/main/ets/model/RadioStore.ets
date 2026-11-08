import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ALL_STATIONS } from './StationData';
import { Station, Scope } from './Station';

/** 需要持久化的收听偏好。所有字段都用独立 key 保存，避免运行时解析 JSON。 */
export class RadioConfig {
  lastId: number = 1;
  volume: number = 60;
  favorites: number[] = [];
  vizStyle: number = 0;
  /** 频谱数据来源：0 模拟动画，1 真实音频分析。 */
  vizMode: number = 0;
  colorTheme: number = 0;
  random: boolean = false;
  soundPreset: number = 0;
  fadePreset: number = 2;
  systemEffect: boolean = true;
  userGain: number = 0;
  userCurve: number = 0;
  sleepMinutes: number = 0;
  scope: number = 0;
  province: string = '全部';
  genre: string = '全部';
}

/**
 * 电台仓库：静态数据 + 多维筛选 + 偏好持久化。
 * 全量 1856 台来自 E6 版 radio.db，编译期静态打包，列表不依赖网络。
 */
export class RadioStore {
  private static instance: RadioStore = new RadioStore();
  private prefs: preferences.Preferences | null = null;
  private byId: Map<number, Station> = new Map<number, Station>();
  private provinceCache: string[] = [];
  private genreCache: string[] = [];
  readonly all: Station[] = ALL_STATIONS;
  config: RadioConfig = new RadioConfig();

  private constructor() {
    for (let i = 0; i < this.all.length; i++) {
      this.byId.set(this.all[i].id, this.all[i]);
    }
  }

  static getInstance(): RadioStore {
    return RadioStore.instance;
  }

  init(context: common.UIAbilityContext): void {
    try {
      this.prefs = preferences.getPreferencesSync(context, { name: 'radio_settings' });
      const p: preferences.Preferences = this.prefs;
      const c: RadioConfig = this.config;
      c.lastId = p.getSync('lastId', 1) as number;
      c.volume = p.getSync('volume', 60) as number;
      c.favorites = this.parseIds(p.getSync('favorites', '') as string);
      c.vizStyle = p.getSync('vizStyle', 0) as number;
      c.vizMode = p.getSync('vizMode', 0) as number;
      c.colorTheme = p.getSync('colorTheme', 0) as number;
      this.migrateViz(p, c);
      c.random = p.getSync('random', false) as boolean;
      c.soundPreset = p.getSync('soundPreset', 0) as number;
      c.fadePreset = p.getSync('fadePreset', 2) as number;
      c.systemEffect = p.getSync('systemEffect', true) as boolean;
      c.userGain = p.getSync('userGain', 0) as number;
      c.userCurve = p.getSync('userCurve', 0) as number;
      c.sleepMinutes = p.getSync('sleepMinutes', 0) as number;
      c.scope = p.getSync('scope', 0) as number;
      c.province = p.getSync('province', '全部') as string;
      c.genre = p.getSync('genre', '全部') as string;
    } catch (e) {
      this.prefs = null;
    }
  }

  /**
   * 频谱样式/配色枚举升级到 E6 九样式版后的一次性迁移：
   * 旧 4 样式（频谱柱/LED/声波/电平表）映射到新 1/2/4/8；旧配色 2=赛博 3=琥珀 顺位后移。
   */
  private migrateViz(p: preferences.Preferences, c: RadioConfig): void {
    if (p.getSync('vizStyleV2', false) as boolean) {
      return;
    }
    const oldToNew: number[] = [1, 2, 4, 8];
    if (c.vizStyle >= 0 && c.vizStyle < oldToNew.length) {
      c.vizStyle = oldToNew[c.vizStyle];
    }
    if (c.colorTheme === 2) {
      c.colorTheme = 3;
    } else if (c.colorTheme === 3) {
      c.colorTheme = 4;
    }
    p.putSync('vizStyleV2', true);
    p.flushSync();
  }

  save(): void {
    if (this.prefs === null) {
      return;
    }
    try {
      const p: preferences.Preferences = this.prefs;
      const c: RadioConfig = this.config;
      p.putSync('lastId', c.lastId);
      p.putSync('volume', c.volume);
      p.putSync('favorites', c.favorites.join(','));
      p.putSync('vizStyle', c.vizStyle);
      p.putSync('vizMode', c.vizMode);
      p.putSync('colorTheme', c.colorTheme);
      p.putSync('random', c.random);
      p.putSync('soundPreset', c.soundPreset);
      p.putSync('fadePreset', c.fadePreset);
      p.putSync('systemEffect', c.systemEffect);
      p.putSync('userGain', c.userGain);
      p.putSync('userCurve', c.userCurve);
      p.putSync('sleepMinutes', c.sleepMinutes);
      p.putSync('scope', c.scope);
      p.putSync('province', c.province);
      p.putSync('genre', c.genre);
      // 异步落盘：切台等高频操作不阻塞 UI 线程（同步 flush 会卡住点击响应）
      p.flush().catch(() => {
      });
    } catch (e) {
      // 持久化失败不阻断收听
    }
  }

  private parseIds(raw: string): number[] {
    const ids: number[] = [];
    if (raw.length === 0) {
      return ids;
    }
    const parts: string[] = raw.split(',');
    for (let i = 0; i < parts.length; i++) {
      const n: number = parseInt(parts[i], 10);
      if (n > 0 && ids.indexOf(n) < 0) {
        ids.push(n);
      }
    }
    return ids;
  }

  findById(id: number): Station {
    const found: Station | undefined = this.byId.get(id);
    if (found === undefined) {
      return this.all[0];
    }
    return found;
  }

  isFavorite(id: number): boolean {
    return this.config.favorites.indexOf(id) >= 0;
  }

  toggleFavorite(id: number): boolean {
    const favs: number[] = this.config.favorites;
    const at: number = favs.indexOf(id);
    const next: number[] = [];
    for (let i = 0; i < favs.length; i++) {
      next.push(favs[i]);
    }
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(id);
    }
    this.config.favorites = next;
    this.save();
    return at < 0;
  }

  /** 聚合出省市筛选项，按电台数量降序。 */
  provinces(): string[] {
    if (this.provinceCache.length > 0) {
      return this.provinceCache;
    }
    const counts: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < this.all.length; i++) {
      const s: Station = this.all[i];
      if (s.countryCode !== 'CN' || s.province.length === 0) {
        continue;
      }
      counts.set(s.province, (counts.get(s.province) ?? 0) + 1);
    }
    const names: string[] = [];
    counts.forEach((value: number, key: string) => {
      names.push(key);
    });
    names.sort((a: string, b: string): number => (counts.get(b) ?? 0) - (counts.get(a) ?? 0));
    this.provinceCache = ['全部'].concat(names);
    return this.provinceCache;
  }

  /** 聚合出题材筛选项，按电台数量降序。 */
  genres(): string[] {
    if (this.genreCache.length > 0) {
      return this.genreCache;
    }
    const counts: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < this.all.length; i++) {
      const g: string = this.all[i].genre;
      if (g.length === 0) {
        continue;
      }
      counts.set(g, (counts.get(g) ?? 0) + 1);
    }
    const names: string[] = [];
    counts.forEach((value: number, key: string) => {
      names.push(key);
    });
    names.sort((a: string, b: string): number => (counts.get(b) ?? 0) - (counts.get(a) ?? 0));
    this.genreCache = ['全部'].concat(names);
    return this.genreCache;
  }

  /** 多维筛选，返回新的数组（切台队列也复用这个结果）。 */
  filter(scope: number, keyword: string, province: string, genre: string): Station[] {
    const kw: string = keyword.trim().toLowerCase();
    const favs: number[] = this.config.favorites;
    const result: Station[] = [];
    for (let i = 0; i < this.all.length; i++) {
      const s: Station = this.all[i];
      if (scope === Scope.Favorite && favs.indexOf(s.id) < 0) {
        continue;
      }
      if (scope === Scope.Domestic && s.countryCode !== 'CN') {
        continue;
      }
      if (scope === Scope.International && s.countryCode === 'CN') {
        continue;
      }
      if (province !== '全部' && s.province !== province) {
        continue;
      }
      if (genre !== '全部' && s.genre !== genre) {
        continue;
      }
      if (kw.length > 0) {
        const hay: string = (s.name + s.city + s.province + s.genre + s.country).toLowerCase();
        if (hay.indexOf(kw) < 0) {
          continue;
        }
      }
      result.push(s);
    }
    return result;
  }
}
