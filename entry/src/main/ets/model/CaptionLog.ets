import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** 一条字幕记录。 */
export interface CaptionRecord {
  time: string;
  station: string;
  text: string;
}

/** 最多保留的条数，超出后丢弃最旧的一条。 */
const MAX_RECORDS: number = 300;

/**
 * 字幕记录本：用 preferences 逐条持久化，避免整段长文本触发单值长度限制。
 * 每条含时间、当时收听的台名与字幕正文，重启应用后仍可查看。
 */
export class CaptionLog {
  private prefs: preferences.Preferences | null = null;

  init(context: common.UIAbilityContext): void {
    try {
      this.prefs = preferences.getPreferencesSync(context, { name: 'radio_caption_log' });
    } catch (e) {
      this.prefs = null;
    }
  }

  private count(): number {
    if (this.prefs === null) {
      return 0;
    }
    const n: number = this.prefs.getSync('n', 0) as number;
    return Math.max(0, Math.min(MAX_RECORDS, n));
  }

  all(): CaptionRecord[] {
    const out: CaptionRecord[] = [];
    if (this.prefs === null) {
      return out;
    }
    const n: number = this.count();
    for (let i = 0; i < n; i++) {
      const raw: string = this.prefs.getSync('r_' + i.toString(), '') as string;
      const parts: string[] = raw.split('\t');
      if (parts.length >= 3) {
        out.push({ time: parts[0], station: parts[1], text: parts[2] });
      }
    }
    return out;
  }

  /** 追加一条，返回最新列表。文本中的换行/制表符会被折叠，避免破坏存储格式。 */
  add(station: string, text: string): CaptionRecord[] {
    const clean: string = text.replace(/\n/g, ' ').replace(/\t/g, ' ').trim();
    if (this.prefs === null || clean.length === 0) {
      return this.all();
    }
    const p: preferences.Preferences = this.prefs;
    const d: Date = new Date();
    const hh: number = d.getHours();
    const mm: number = d.getMinutes();
    const ss: number = d.getSeconds();
    const time: string = (hh < 10 ? '0' : '') + hh.toString() + ':' +
      (mm < 10 ? '0' : '') + mm.toString() + ':' + (ss < 10 ? '0' : '') + ss.toString();
    const line: string = time + '\t' + station.replace(/\t/g, ' ') + '\t' + clean;
    const n: number = this.count();
    if (n >= MAX_RECORDS) {
      for (let i = 1; i < MAX_RECORDS; i++) {
        p.putSync('r_' + (i - 1).toString(), p.getSync('r_' + i.toString(), '') as string);
      }
      p.putSync('r_' + (MAX_RECORDS - 1).toString(), line);
    } else {
      p.putSync('r_' + n.toString(), line);
      p.putSync('n', n + 1);
    }
    p.flushSync();
    return this.all();
  }

  clear(): CaptionRecord[] {
    if (this.prefs === null) {
      return [];
    }
    const p: preferences.Preferences = this.prefs;
    const n: number = this.count();
    for (let i = 0; i < n; i++) {
      p.deleteSync('r_' + i.toString());
    }
    p.putSync('n', 0);
    p.flushSync();
    return [];
  }

  /** 导出为纯文本，便于复制到备忘录或分享。 */
  exportText(): string {
    const records: CaptionRecord[] = this.all();
    let out: string = '';
    for (let i = 0; i < records.length; i++) {
      const r: CaptionRecord = records[i];
      out += '[' + r.time + '] ' + r.station + '  ' + r.text + '\n';
    }
    return out;
  }
}
