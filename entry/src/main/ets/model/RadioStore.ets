import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ALL_STATIONS } from './StationData';
import { Station, Scope } from './Station';

/** 一条收听记录：电台 id + 最后收听时刻（毫秒时间戳）。 */
export interface RecentEntry {
  id: number;
  at: number;
}

/** 归一化增益表最多保留多少台。超出的按最旧丢弃，避免偏好文件无限膨胀。 */
const NORM_GAIN_LIMIT: number = 300;
/** 最近播放最多保留多少条。 */
const RECENT_LIMIT: number = 50;

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
  /** 音量归一化开关。开着就必须走真实音频解析（要 PCM 才能测电平）。 */
  normalize: boolean = true;
  /** 每台电台的归一化修正增益，序列化成 "id:增益;id:增益"。 */
  normGains: string = '';
  /** 收听历史，序列化成 "id:时刻;id:时刻"，按时间从新到旧。 */
  recents: string = '';
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
  /** 归一化增益表：电台 id → 修正 dB。解析一次后常驻，避免每次播放都解字符串。 */
  private normGainMap: Map<number, number> = new Map<number, number>();
  /** 收听历史，按时间从新到旧。 */
  private recentList: RecentEntry[] = [];
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
      c.normalize = p.getSync('normalize', true) as boolean;
      c.normGains = p.getSync('normGains', '') as string;
      c.recents = p.getSync('recents', '') as string;
      this.migrateScope(p, c);
      this.normGainMap = this.parseNormGains(c.normGains);
      this.recentList = this.parseRecents(c.recents);
    } catch (e) {
      this.prefs = null;
    }
  }

  /**
   * 列表范围枚举加进了「最近播放」，后面的取值整体后移了一位。
   * 老版本存下来的 scope 是旧编号（1=收藏 2=国内 3=国际），不迁移的话
   * 老用户的收藏页会变成最近播放页、国内页会变成收藏页。
   */
  private migrateScope(p: preferences.Preferences, c: RadioConfig): void {
    if (p.getSync('scopeV2', false) as boolean) {
      return;
    }
    const old: number = c.scope;
    if (old === 1) {
      c.scope = Scope.Favorite;
    } else if (old === 2) {
      c.scope = Scope.Domestic;
    } else if (old === 3) {
      c.scope = Scope.International;
    } else {
      c.scope = Scope.All;
    }
    p.putSync('scopeV2', true);
    p.putSync('scope', c.scope);
    p.flushSync();
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
      p.putSync('normalize', c.normalize);
      p.putSync('normGains', c.normGains);
      p.putSync('recents', c.recents);
      // 异步落盘：切台等高频操作不阻塞 UI 线程（同步 flush 会卡住点击响应）
      p.flush().catch(() => {
      });
    } catch (e) {
      // 持久化失败不阻断收听
    }
  }

  /**
   * 只写一个 key 并异步落盘。
   * 归一化增益表和收听历史会被高频更新，走整份 save() 会把别的字段用
   * 内存里的旧值覆盖回去，所以这两处单独刷。
   */
  private flushKey(key: string, value: string): void {
    if (this.prefs === null) {
      return;
    }
    try {
      const p: preferences.Preferences = this.prefs;
      p.putSync(key, value);
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

  // ============================== 音量归一化 ==============================

  /** 解析 "id:增益;id:增益" 形式的归一化增益表。 */
  private parseNormGains(raw: string): Map<number, number> {
    const map: Map<number, number> = new Map<number, number>();
    if (raw.length === 0) {
      return map;
    }
    const parts: string[] = raw.split(';');
    for (let i = 0; i < parts.length; i++) {
      const seg: string = parts[i];
      const at: number = seg.indexOf(':');
      if (at <= 0) {
        continue;
      }
      const id: number = parseInt(seg.substring(0, at), 10);
      const db: number = parseFloat(seg.substring(at + 1));
      if (id > 0 && !isNaN(db)) {
        map.set(id, db);
      }
    }
    return map;
  }

  /** 某台电台的归一化修正增益（dB）。没测过就是 0。 */
  normGain(id: number): number {
    const v: number | undefined = this.normGainMap.get(id);
    return v === undefined ? 0 : v;
  }

  /** 记录某台电台的归一化修正增益。传 0 表示撤销修正。 */
  setNormGain(id: number, db: number): void {
    if (id <= 0) {
      return;
    }
    if (Math.abs(db) < 0.25) {
      this.normGainMap.delete(id);
    } else {
      this.normGainMap.set(id, db);
    }
    // 超量时丢掉最早插入的那些（Map 保持插入序），避免偏好文件无限膨胀。
    while (this.normGainMap.size > NORM_GAIN_LIMIT) {
      const oldest: number | undefined = this.normGainMap.keys().next().value;
      if (oldest === undefined) {
        break;
      }
      this.normGainMap.delete(oldest);
    }
    const parts: string[] = [];
    this.normGainMap.forEach((value: number, key: number): void => {
      parts.push(key.toString() + ':' + value.toString());
    });
    this.config.normGains = parts.join(';');
    this.flushKey('normGains', this.config.normGains);
  }

  // ============================== 最近播放 ==============================

  /** 解析 "id:时刻;id:时刻" 形式的收听历史。 */
  private parseRecents(raw: string): RecentEntry[] {
    const list: RecentEntry[] = [];
    if (raw.length === 0) {
      return list;
    }
    const parts: string[] = raw.split(';');
    for (let i = 0; i < parts.length; i++) {
      const seg: string = parts[i];
      const at: number = seg.indexOf(':');
      if (at <= 0) {
        continue;
      }
      const id: number = parseInt(seg.substring(0, at), 10);
      const time: number = parseInt(seg.substring(at + 1), 10);
      if (id > 0 && time > 0) {
        list.push({ id: id, at: time });
      }
    }
    return list;
  }

  /** 收听历史（按时间从新到旧）。返回的是副本，外部改动不会影响内部状态。 */
  recents(): RecentEntry[] {
    const out: RecentEntry[] = [];
    for (let i = 0; i < this.recentList.length; i++) {
      out.push({ id: this.recentList[i].id, at: this.recentList[i].at });
    }
    return out;
  }

  /** 收听历史条数。 */
  recentCount(): number {
    return this.recentList.length;
  }

  /** 记录一次收听。同一台重复收听只更新时间并提到最前面。 */
  pushRecent(id: number): void {
    if (id <= 0) {
      return;
    }
    const now: number = Date.now();
    const next: RecentEntry[] = [{ id: id, at: now }];
    for (let i = 0; i < this.recentList.length; i++) {
      const e: RecentEntry = this.recentList[i];
      if (e.id !== id && next.length < RECENT_LIMIT) {
        next.push({ id: e.id, at: e.at });
      }
    }
    this.recentList = next;
    const parts: string[] = [];
    for (let i = 0; i < next.length; i++) {
      parts.push(next[i].id.toString() + ':' + next[i].at.toString());
    }
    this.config.recents = parts.join(';');
    this.flushKey('recents', this.config.recents);
  }

  /** 清空收听历史。 */
  clearRecents(): void {
    this.recentList = [];
    this.config.recents = '';
    this.flushKey('recents', '');
  }

  /** 某个电台最后一次收听的时刻；没有记录返回 0。 */
  recentAt(id: number): number {
    for (let i = 0; i < this.recentList.length; i++) {
      if (this.recentList[i].id === id) {
        return this.recentList[i].at;
      }
    }
    return 0;
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
    // 「最近播放」不按静态台表遍历，而是按收听历史的时间顺序取，
    // 这样才是一份真正的时间线，而不是台表的一个子集。
    if (scope === Scope.Recent) {
      for (let i = 0; i < this.recentList.length; i++) {
        const st: Station | undefined = this.byId.get(this.recentList[i].id);
        if (st === undefined) {
          continue;
        }
        if (province !== '全部' && st.province !== province) {
          continue;
        }
        if (genre !== '全部' && st.genre !== genre) {
          continue;
        }
        if (kw.length > 0) {
          const hay: string = (st.name + st.city + st.province + st.genre + st.country).toLowerCase();
          if (hay.indexOf(kw) < 0) {
            continue;
          }
        }
        result.push(st);
      }
      return result;
    }
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
