# 收音机 / 广播收听类应用：功能与交互调研

> 调研时间：2026-11-10
> 方法：web_search / web_fetch 实检索 + App Store 与开发者自述功能核验 + 公开 API 实测 + 官方文档
> 信源分三档：**① 官方/权威**（央广、央广网、中国日报网、车质网、Apple 官方文档、App Store 开发者自述、Wikipedia、项目官方仓库）；**② 媒体转载**（中华网科技、新浪、少数派、Rolling Stone 等）；**③ 下载站/SEO 站**（仅用于判断"某 App 存在某功能"这一存在性事实，其性能数字与评测结论一律不采信）。已在正文中剔除的内容农场与 AI 生成的伪评测站不再列出。
>
> 本项目现状（对照基线）：三栏界面（导航/列表/播放器）、真实频谱可视化（NDK 拉流解码 + FFT）、AI 实时字幕（`AICaptionComponent` 端侧）、后台播放（AVSession + 长时任务）、锁屏播控卡片、睡眠定时、12 档端侧音效预设、端侧听感调节、收藏夹、地区/题材筛选、搜索；**2105 个电台静态内置、离线可用**。

---

## 0. 三条最值得强调的判断

1. **最接近本项目形态、也最该作为对标标杆的产品，是 `theradio.app`（收音机: FM全球直播）与 `radiodad.app`。**
   前者几乎把"频谱可视化 + 设备端实时字幕 + 歌曲历史 + 均衡器 + 睡眠定时 + 锁屏控制 + 小组件"打包成一个付费产品；后者把"端侧实时字幕 + 句对句翻译 + Shazam 式曲目识别 + 端侧 LLM 选台"做成核心差异。
   **结论：本项目"真实频谱 + AI 实时字幕"这组合已经被市场验证过，值得继续加码（原文/译文、歌曲历史、章节），而不是转向别的方向。**

2. **AI 在音频里的落地形态高度趋同于三条线：对话、按需生成、空间化；最被低估的是"字幕从展示升级为可检索、可对话的索引"。**
   喜马拉雅"AI 听中问"（问一句、生成大纲、定位时间轴）、Radio Dad "Ask Dad"（自然语言选台 + 转写全文句子检索）、小宇宙（时间戳评论 + 热度柱 + 可导出文稿）本质是同一件事：**给线性音频加一根"内容轴"**。本项目已有实时字幕，是离这个形态最近的产品。

3. **平板的机会在"多窗口 + 大屏 + 系统级卡片"，不在"把手机 App 放大"。**
   Radio Dad 明确把 3D 地球探索留在手机、CarPlay 里只留 Favorites/Recents/Now Playing；网易云鸿蒙版用跨端续播 + 桌面歌词 + HiCar 分屏重做多端；云听车载用组件化首页（42+9 布局）解决"车企定制 + 用户个性化 + 运营热更"三重诉求。
   **结论：本项目应该按"桌面 / 窗口 / 全屏 / 锁屏"四态分别设计，而不是一套布局缩放。**

---

## 1. 功能全景

### 1.1 目录、选台与台单治理

| 功能名 | 哪些产品有 | 具体怎么做的 | 来源 |
|---|---|---|---|
| 全球电台目录（3 万–10 万级） | Radio Garden 4 万+、Radio Browser 5.8 万+、TuneIn 10 万+/197 国、radio.net 6 万+、myTuner 5 万+/200 国、Radio Dad 5 万+/230+ 国、theradio.app 5 万+ | 多数走 Radio Browser 社区目录 | [Radio Garden](https://radio.garden/settings/radio-garden) · [Wikipedia](https://en.wikipedia.org/wiki/Radio_Garden) · [TuneIn](https://apps.apple.com/us/app/tunein-radio-music-sports/id418987775) · [radio.net](https://apps.apple.com/us/app/radio-net-am-fm-radio-tuner/id402206359) · [myTuner](https://apps.apple.com/us/app/mytuner-radio-live-stations/id520502858) · [Radio Dad](https://radiodad.app/stations) · [theradio.app](https://apps.apple.com/cn/app/radio-live-uk-world-fm/id6762442559) |
| 开放目录 API + CC0 数据 | Radio Browser / Radio Dad | 免 key JSON API，多镜像；字段含 `votes`、`clickcount`、`clicktrend`、`lastcheckok`、`lastchecktime`、`codec`、`bitrate`、`hls`、`ssl_error`、`geo_lat/geo_long`、`geo_distance`、`has_extended_info` | [API 实测](https://all.api.radio-browser.info/json/stations/topclick/2) · [字段列表](https://de1.api.radio-browser.info/json/stations/bycountrycodeexact/US?limit=1) · [Radio Dad /about](https://radiodad.app/about) |
| **死链治理**（"哪个台还活着"变成数据） | Radio Browser 生态 | `lastcheckok=1` 过滤死链；`ssl_error` 提示 HTTPS 故障；`geo_distance` 支持"离我最近的台" | 同上 |
| 地理发现落地页（111 国 / 22 体裁） | Radio Dad | 每页直接浏览器开播，无需 App；中国 1885 台、德国 4324、美国 8179 | [Radio Dad /stations](https://radiodad.app/stations) |
| 3D 地球选台（spin-to-tune） | Radio Garden、Radio Dad | 绿点=城市（按台数定大小），十字准星对准即播；Radio Garden 用 3Dglobe + MapLibre + Who's On First | [Radio Garden /about](https://radio.garden/settings/radio-garden) · [Radio Dad /about](https://radiodad.app/about) |
| 广播档案（时间胶囊） | Internet Archive、Radio Garden 的 History/Jingles | 存档历史广播与台标音 | [archive.org/details/radioprograms](https://archive.org/details/radioprograms) · [Radio Garden](https://radio.garden/settings/radio-garden) |
| 全国台分层 + 首字母索引 | 蔚来收音机、云听 | 本地台/全国台两 Tab + A–Z 索引；云听覆盖 22 套国家台 + 253 套省级台 | [车质网·ET9](https://m.12365auto.com/scbg/20250530/548690_3.shtml) · [央广传媒集团](http://www.cnrmg.cn/xwzx1/jtyw/20251030/t20251030_527413354.html) |
| 地理定位聚合本地台 | 喜马拉雅车载、蜻蜓、云听车载、理想、蔚来 | 定位后自动切到所在城市电台；蜻蜓"定位+类型+地区"三级选台 | [央广传媒集团](http://www.cnrmg.cn/xwzx1/jtyw/20251030/t20251030_527413354.html) · [理想社区](https://www.lixiang.com/community/detail/article/2648872.html) |
| 收藏夹 / 历史 / 一键收听 | 几乎全部 | Radio Garden 收藏存 localStorage（无账号无云同步）；theradio.app 无限收藏 + iCloud 同步 | 同上各产品页 |

### 1.2 播放、播控与"错过了怎么办"

| 功能名 | 哪些产品有 | 具体怎么做的 | 来源 |
|---|---|---|---|
| **直播回看 / Take Control** | Global Player、Audacy、radio.net | Global Player：点播放条进入控制，可跳过、回退直播；Audacy：体育新闻直播 rewind 到开头 | [Global Player](https://apps.apple.com/us/app/global-player-radio-podcasts/id1142951331) · [Audacy](https://apps.apple.com/us/app/audacy-radio-sports-talk/id323701765) · [radio.net](https://apps.apple.com/us/app/radio-net-am-fm-radio-tuner/id402206359) |
| **Catch-up（近 7 天回听/下载）** | Global Player、radio.net | "Missed a broadcast? Then simply catch up!" | 同上 |
| **直播中的章节（chapters）** | Audacy | 直播流按话题分段，直接跳到关心的那段 | [Audacy](https://apps.apple.com/us/app/audacy-radio-sports-talk/id323701765) |
| 24 小时回听 / 时移 | 蜻蜓FM、喜马拉雅 | 蜻蜓"广播内容 24 小时回听"；喜马拉雅直播频道有日历式日期选择器回看过去 7 天 | [蜻蜓FM](https://www.ianfen.com/down/161428.html) · [喜马拉雅](https://m.k73.com/down/android/192267.html) |
| 用户自录直播回放 | 喜马拉雅 | 直播中点"录制"存个人云端保留 30 天 | [喜马拉雅](https://m.k73.com/down/android/192267.html) |
| 章节标记 + 跳过静音 | 喜马拉雅回放页 | 倍速、跳过静音片段、章节标记 | 同上 |
| **电台闹钟**（用真实 FM 台叫醒） | TuneIn | 闹钟设定为某个真实电台频率，叫醒你的是那个台 | [TuneIn](https://apps.apple.com/us/app/tunein-radio-music-sports/id418987775) |
| 电台闹钟 / 睡眠定时 | 蜻蜓FM、小宇宙、网易云鸿蒙、theradio.app | "广播当起床闹铃"；网易云鸿蒙"播客定时关闭"；theradio.app 睡眠定时 + 电台闹钟 | [蜻蜓车载版](https://www.downyu.com/downinfo/144115.html) · [中国商报网](https://www.zgswcn.com/news.html?aid=378409) · [theradio.app](https://apps.apple.com/cn/app/radio-live-uk-world-fm/id6762442559) |
| **高级睡眠定时**（渐降音量/渐减速/摇一摇重置） | AntennaPod、Pocket Casts、radio.net | AntennaPod 高级定时：摇一摇重置、逐渐降音量、逐渐减速 | [AntennaPod Wiki](https://github.com/Hjinwen/AntennaPod/wiki/About-AntennaPod) · [Pocket Casts](https://apps.apple.com/us/app/pocket-casts-podcast-player/id414834813) |
| **ICy "正在播放"元数据** | theradio.app、myTuner、radio.net、RadioRec | 流内 ICY 标题解析，实时显示当前歌曲于封面/标题栏 | [theradio.app](https://apps.apple.com/cn/app/radio-live-uk-world-fm/id6762442559) · [myTuner](https://apps.apple.com/us/app/mytuner-radio-live-stations/id520502858) |
| **歌曲历史（带时间戳，可点按搜索）** | theradio.app、RadION | theradio.app：电台播报的每首歌都带时间戳记录，点按即可上网搜索；RadION 的"收集 Scrap"：一键收藏当前曲目名/歌手/采集时间 | [theradio.app](https://apps.apple.com/cn/app/radio-live-uk-world-fm/id6762442559) · [RadiON](https://baike.baidu.com/item/RadiON网上广播/16088590) |
| **流媒体录制**（存到"文件"App） | theradio.app、RadioRec、复古收音机类 App、蜻蜓 | theradio.app 付费版：把任何广播保存到"文件"；RadioRec：精确到分钟/按星期几的计划录制，MP3 或 FLAC，并把 ICY 元数据写入 ID3 | [theradio.app](https://apps.apple.com/cn/app/radio-live-uk-world-fm/id6762442559) · [RadioRec 介绍](https://gtc-trading.com/audio/62728-radiorec.html) |
| **音量归一化（sound check）** | RadioRec | 内置响度检测，跨台自动归一化音量 | 同上 |
| 响度处理 / 静音压缩 | Pocket Casts、Podbean、Player FM | Volume boost、Trim silence、自定义跳过片头片尾 | [Podbean](https://apps.apple.com/us/app/podbean-podcast-app-player/id973361050) · [Player FM](https://apps.apple.com/us/app/player-fm-podcast-app/id940558467) |
| 像/不像 + 滑动跳过 | Global Player、AccuRadio | 对直播流里的歌 like/dislike、跳过不限次数，用滑动完成定制 | [Global Player](https://apps.apple.com/us/app/global-player-radio-podcasts/id1142951331) · [AccuRadio](https://apps.apple.com/us/app/accuradio-curated-music-radio/id351425453) |
| 广播自动化（DJ 向，可编排节目单） | RADIO Player Pro (Radiosoft) | 按日期时间自动启停、jingle 自动插播、可视化交叉淡化、DTMF 掉线自动切备用源、静音检测、多主持人 Profile、HTTP 远程改单 | [Softpedia](https://www.softpedia.com/get/Multimedia/Audio/Audio-Players/RADIO-Player-Pro.shtml) · [mysoftreview](http://mysoftreview.com/buy/315135/) |
| UGC 自办电台 | Mixlr | 用户自建直播节目，同步到社交直播，可录成播客分发 | [Mixlr](https://mixlr.en.uptodown.com/android) |
| 向主播说话（Talkback） | iHeartRadio | 直播中按键与主播连线 | [iHeart](https://apps.apple.com/us/app/iheart-radio-music-podcasts/id290638154) |

### 1.3 发现、推荐与"说什么"

| 功能名 | 哪些产品有 | 具体怎么做的 | 来源 |
|---|---|---|---|
| **自然语言选台（LLM 检索）** | Radio Dad（Ask Dad） | "jazz from Osaka" 直接出结果；整段对话留在设备本地 | [Radio Dad](https://radiodad.app/) |
| **一句话建私人频道** | 喜马拉雅 AI 频道、Yoodio | 喜马拉雅："创建一个科技前沿资讯频道"，AI 实时更新该频道；Yoodio："70 年代埃塞俄比亚爵士" | [中国日报网](https://ex.chinadaily.com.cn/exchange/partners/82/rss/channel/cn/columns/snl9a7/stories/WS686b8049a3106af2b3c72d00.html) · [Yoodio](https://apps.apple.com/us/app/yoodio-ai-radio-with-live-djs/id6743950965) |
| **AI DJ / 生成式电台主持** | Yoodio、Podcast App（AI Digest）、Spotify AI DJ、Andon Labs AI 电台 | Yoodio：命名人格化 DJ（Aya/Flash/Joey Cotillard），曲间生成解说+天气+生活建议；Andon Labs 让 ChatGPT/Gemini/Claude/Grok 各自主持一台电台 | [Yoodio](https://apps.apple.com/us/app/yoodio-ai-radio-with-live-djs/id6743950965) · [Podcast App](https://apps.apple.com/us/app/podcast-app/id1199070742) · [AI 电台主持实验](http://www.ai-jarvis.eu/ai-radio-host-experiment-chatgpt-gemini-and-claude-reveals-bizarre-behavior) |
| **AI 主播人格化** | 来福电台 | 15 位中文 + 2 位英文 AI 主播各有独立人设；内容按需现场生成；可打断、提问；用随主播说话节奏跃动的球强化"人"感；靠长记忆做 DTU | [天脉网](https://www.dtm.com.cn/news/202602/190883.html) · [小宇宙·来福解读](https://www.xiaoyuzhoufm.com/episode/69bf93ed2d318777c91e70af) |
| **真实电台的 AI DJ 落地** | DJ Tori (KFMW Rock 108)、AI Ashley (KBFF)、Sarah (SONiC)、Cleo/Layla | 声音克隆播报（RadioGPT/Futuri）、混编路况；每小时从社交媒体选本地热点 + 艺人冷知识播报 | [Rolling Stone](https://www.rollingstone.com/music/music-features/ai-is-replacing-radio-disc-jockeys-1235463028/) |
| YouTube Labs「AI music hosts」 | YouTube | 电台流中插故事/冷知识/评论，可按小时或全天静音 | [Rolling Stone](https://www.rollingstone.com/music/music-features/ai-is-replacing-radio-disc-jockeys-1235463028/) |
| **AI 听中问（边听边问）** | 喜马拉雅"小雅" | 播放页内实时对话：要当前章节核心概要、结构化大纲、定位内容大纲与时间轴、针对情节追问；底座 ASR/NLP + DeepSeek + RAG + 长文本理解 | [中国日报网](https://ex.chinadaily.com.cn/exchange/partners/82/rss/channel/cn/columns/snl9a7/stories/WS686b8049a3106af2b3c72d00.html) · [中华网](https://digi.china.com/articles/20250725/202507251704972.html) |
| ReAct + 全局 Memory 座舱智能体 | 喜马拉雅 × 鸿蒙智行 | 整合全站行为数据生成自然语言画像；多模态信号（行为/环境/乘客特征）动态推荐；主动开口而非等点 | [中国日报网·HDC2025](https://ex.chinadaily.com.cn/exchange/partners/82/rss/channel/cn/columns/snl9a7/stories/WS6863a9efa3106af2b3c71f23.html) |
| 人工策展（而非算法） | AccuRadio、Audacy | AccuRadio 975+ 条人工策展 + "Five-Star Radio"（只放你打五星的歌） | [AccuRadio](https://apps.apple.com/us/app/accuradio-curated-music-radio/id351425453) · [Audacy](https://apps.apple.com/us/app/audacy-radio-sports-talk/id323701765) |
| 社区投票排序 | Radio Browser 生态、Radio Player Pro 开源版 | `votes` / `clickcount` / `clicktrend` 决定"热门" | [API](https://all.api.radio-browser.info/json/stations/topclick/2) · [KernFerm README](https://github.com/KernFerm/Radio-Player-Pro/blob/main/README.MD) |
| **搜索框"零输入可用"** | 云听车载 | 未输入时铺热门底纹词与搜索热词，**点击直接播放**（不进结果页） | [央广传媒集团](http://www.cnrmg.cn/xwzx1/jtyw/20251030/t20251030_527413354.html) |
| 联想词分层 / 搜索无结果补位 / 播放中推荐联动 | 云听车载 | 常听内容优先并标"一键直达"；搜"科幻小说"无结果自动推《流浪地球》；听《庆余年》实时推同作者《赘婿》且不退出播放页 | 同上 |
| 每日人工精选 / 往日精选 | 小宇宙 | 每天人工精选 3 期 + 往日精选补旧账 | [百度百科·小宇宙](https://baike.baidu.com/item/%e5%b0%8f%e5%ae%87%e5%ae%99/49717858) |

### 1.4 车载、跨端与语音

| 功能名 | 哪些产品有 | 具体怎么做的 | 来源 |
|---|---|---|---|
| **CarPlay 音频 App 类别** | radio.net、myTuner、TuneIn、Radio Dad | Apple 为音频 App 提供独立 entitlement 与模板；**最多 4 个音频 App 同时可播**；支持 Widgets 与 Live Activities | [Apple CarPlay 开发者指南](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf) · [Apple CarPlay](https://developer.apple.com/carplay/) |
| **CarPlay 信息架构分工** | Radio Dad | 车里只给 Favorites / Recents / Now Playing；3D 地球探索留在手机 | [Radio Dad 车载页](https://radiodad.app/learn/best-carplay-radio-app) |
| **无 CarPlay 兜底：Driving Mode** | Radio Dad | 大按钮 + 高对比 + 夜间深色；蓝牙连上车自动启动 | 同上 |
| 跨设备/跨车机覆盖 | TuneIn、radio.net、myTuner | TuneIn：CarPlay + 特斯拉/奔驰兼容车机 + Alexa + Google Home；radio.net：CarPlay + AirPlay + Chromecast | [TuneIn](https://apps.apple.com/us/app/tunein-radio-music-sports/id418987775) · [radio.net](https://apps.apple.com/us/app/radio-net-am-fm-radio-tuner/id402206359) |
| **跨端续播** | 网易云鸿蒙、云听、喜马拉雅小雅OS | 同账号进度/收藏/历史全维度同步；车机是显示与控制终端，算力与网络仍在手机 | [中国商报网](https://www.zgswcn.com/news.html?aid=378409) · [央广传媒集团](http://www.cnrmg.cn/xwzx1/jtyw/20251030/t20251030_527413354.html) |
| **桌面歌词 / HiCar 分屏歌词 / 任务流转** | 网易云鸿蒙 | 不在播放页也能看歌词；HiCar 切应用不打断音乐；歌词分屏 | [中国商报网](https://www.zgswcn.com/news.html?aid=378409) |
| **组件化可定制车机首页** | 云听车载 3.6 | 5 类组件统一尺寸与交互；"页面样式+组件"自由组合出 **42+9 种布局**；节日主题 + 车企品牌专属（背景图/7 种顶部样式/6 种栏目样式） | [央广传媒集团](http://www.cnrmg.cn/xwzx1/jtyw/20251030/t20251030_527413354.html) |
| **驾驶安全优先布局** | 云听车载 3.6 | 核心功能集中在**左侧导航栏**（主驾不用弯腰侧身）+ 竖滑切换；改版后**视线离开路面时间缩短 50%** | 同上 |
| **应急广播 + 车路云协同** | 云听车联网 × 中国交通广播(湖南) × 湖南高速 | 应急态经国家应急广播中心以**弹窗 + 语音播报**触达，弹窗可关、历史进"消息中心"留档；AI 大模型分析路况生成"减速慢行/谨慎通过/绕行建议" | [央广网](https://www.cnr.cn/yggg/ygdt/20250509/t20250509_527163834.shtml) · [央广传媒集团](http://www.cnrmg.cn/xwzx1/jtyw/20251030/t20251030_527413354.html) |
| 车载"网络电台"替代真 FM | 比亚迪/蔚来/小鹏 | 界面仍是收音机图标，信号走蜂窝网；隧道/山区/流量耗尽即沉默；理想公开数据称 FM 在音视频应用日活里排中位且工作日用得更多 | [什么值得买](https://post.smzdm.com/p/am9xqkod) |
| 真 FM 保留 + 听歌识曲 | 理想车机、小米汽车 | 理想郑州暴雨后从纠结砍 FM 到拍板"该上就上"；小米汽车收音机支持 FM/AM | 同上 · [理想社区](https://www.lixiang.com/community/detail/article/2648872.html) |
| 收音机数轴/刻度调频 | 蔚来 | 点右上角数轴进带刻度的频道界面，左右滑动调频；评测称"整个操作略有繁琐" | [车质网·ES6](https://m.12365auto.com/scbg/20200908/437660_3.shtml) |
| 收藏台桌面卡片 + 拖拽排序 | 理想车机 FM | 桌面卡片带快捷区域键（只展示前 3 个）；收藏台可长按卡片拖拽排序 | [理想 ONE 车机说明](https://k.sina.cn/article_7880068201_1d5b04c6901901xhde.html) |
| 甩动转屏（副驾→中控） | 理想、爱奇艺车机版 | 副驾娱乐屏的视频可按住卡片向中控屏方向甩动转移 | [理想 ONE 车机说明](https://k.sina.cn/article_7880068201_1d5b04c6901901xhde.html) |
| 乘客点歌 | 酷我音乐 × 曹操出行 | 乘客端智控屏进入点歌页；不点歌则"场景歌单"自动匹配 | [中国青年网](https://fun.youth.cn/yl24xs/202311/t20231108_14895197.htm) |
| 点火即播 / 无缝续播硬件 | 喜马拉雅随车听 | 2015-07 发布，198 元，点烟器插入式 8–24V 宽压；通电即自动唤醒 App 并从上次位置续播；旋钮遥控手机端播放/暂停/切曲；内置短路保护延长寿命 3 倍 | [快懂百科·随车听](https://www.baike.com/wikiid/9194880891491081355) · [91单机网实测](https://www.91danji.com/news/az35256.html) |
| 音箱"一触即播"（NFC） | 喜马拉雅 Miniboom Aplus | 手机 NFC 轻触音箱即唤醒 App 播预设或最近收听 | [中华网科技](https://m.tech.china.com/articles/20250930/202509301742989.html) |
| 内容技能输出第三方硬件 | 小雅OS | 把内容能力封装成"内容技能"输出给科大讯飞、云知声、腾讯车联、小米、百度、海尔、华为等；30+ 种点播方式、100+ 收听技能 | [环球网](https://3w.huanqiu.com/a/f27b59/9CaKrnKnekE) |
| 语音助手播电台 | Alexa / Google Home / Siri | Alexa 通过 skill 播直播电台，已扩展到 350+ 印度电台 | [Digital Radio Choice](https://www.digitalradiochoice.com/smart-speakers/amazon-alexa/) · [Business Today](https://www.businesstoday.in/storyprint/318509) |
| 小组件 / 手表 / 通知三件套 | Radio Dad、AntennaPod、Pocket Casts | Radio Dad 桌面小组件一键回到上次电台；AntennaPod 桌面小组件 + 系统通知 + 耳机/蓝牙控制 | [Radio Dad](https://radiodad.app/) · [AntennaPod Wiki](https://github.com/Hjinwen/AntennaPod/wiki/About-AntennaPod) |
| Siri 快捷指令 / 深度链接 | theradio.app | "嘿 Siri，播放我的收藏电台"；深链分享电台，点击即进入播放状态 | [theradio.app](https://apps.apple.com/cn/app/radio-live-uk-world-fm/id6762442559) |

### 1.5 字幕、空间音频与无障碍

| 功能名 | 哪些产品有 | 具体怎么做的 | 来源 |
|---|---|---|---|
| **端侧实时字幕 + 实时翻译** | Radio Dad | 一边播一边逐行写出；"原文在上、译文在下"句对句；转写 30+ 语言、翻译约 20 种；**全部跑在设备上**，音频不上传、不录制、不经服务器 | [Radio Dad 字幕页](https://radiodad.app/learn/radio-with-live-captions-translation) |
| **设备端实时字幕** | theradio.app | 付费版"实时字幕 — 在设备上对正在播放的内容进行字幕转录"；设备支持时音频在设备内处理 | [theradio.app](https://apps.apple.com/cn/app/radio-live-uk-world-fm/id6762442559) |
| **实时文稿（卡拉OK式滚动）** | 小宇宙 | 播放页"文稿"按钮，文字实时滚动高亮，可复制、导出 TXT；离线也能看已下载单集文稿 | [安智市场](https://market.goapk.com/pkg/xiaoyuzhoufm) · [少数派](https://sspai.com/post/118207) |
| **时间戳评论 + 进度条热度柱** | 小宇宙 | 评论自动锚定当前播放时间点，点击跳转；进度条按点赞热度堆"小柱子"，高能片段一眼可见 | [安卓谷](https://www.apkgu.com/android/xyzapp) · [跑跑车](https://www.paopaoche.net/app/2370953.html) |
| **评论热力图 / 逐字文稿可搜索** | 第三方"光锥"（小宇宙网页版） | 把带时间戳评论画成进度条密度热力图；逐字文稿可搜索跳转；章节时间也画成进度条刻度 | [少数派·光锥](https://sspai.com/post/118207) |
| **可搜索的自动转写 + 编辑精选图表** | Apple Podcasts | 自动生成转写，转写全文可搜索，点击图表跳转 | [Apple 创作者文档](https://podcasters.apple.com/support/823-podcast-transcripts) |
| 音频 → 带字幕短视频 | 小宇宙 | "视频片段智能转换功能，可将音频转化为带字幕的短视频进行分享" | [百度百科·小宇宙](https://baike.baidu.com/item/%e5%b0%8f%e5%ae%87%e5%ae%99/49717858) |
| 同声传译 | 小宇宙 PLUS | 部分外语节目提供同声传译 | [跑跑车](https://www.paopaoche.net/app/2370953.html) |
| **空间音频：个性化 HRTF + 头动追踪** | 喜马拉雅、华为 Audio Vivid、Cleer Arc 5 | 喜马拉雅移动端杜比全景声 + Audio Vivid 菁彩声，3300+ 小时/27000+ 集，**个性化 HRTF** 与**头动追踪**；Cleer Arc 5 把卷积运算放耳机端，延迟压到 10ms 内 | [国企网](https://www.cnsoe.com.cn/cjsy/content_121947.html) · [中国日报网](https://ex.chinadaily.com.cn/exchange/partners/82/rss/channel/cn/columns/snl9a7/stories/WS6863a9efa3106af2b3c71f23.html) · [CSDN](https://vcloud.csdn.net/6ad17c6c536f457592b03df9.html) |
| 车载空间音频上混 | 马栏山音视频实验室 | 基于国产 Audio Vivid 标准，实时智能上混把普通双声道扩展为 15+ 声道 | [图扬科技](http://www.tome-sz.com/hynews_view.aspx?id=1082&nid=1&typeid=50046) |
| 适老化大字版 | 懒人听书大字版 | 独立精简 App：大字体/大图标/高对比、**每个按钮点击有语音提示**、语音搜索、无广告；砍掉个性化推荐与云同步以降低老旧机负载 | [51WAN](https://www.51wan.com/azsoft/lrtsdzb/) |
| 极简 / 亲子 / 夜间模式 | 喜马拉雅、懒人听书 | 极简模式去掉直播与商城只留订阅+播放；夜间模式降亮度可与定时关闭叠加；亲子模式过滤未成年人内容 | [喜马拉雅](https://m.k73.com/down/android/192267.html) |
| 家长 AI 声音分身 | 喜马拉雅奇奇学 | "AI 换声·爸妈分身"：家长录一段声音，孩子听到**由自己声音讲述**的 3 万+ 故事 | [网易新闻](https://c.m.163.com/news/a/KET2J9FG0525ETL1.html) |
| 声音 IP 资产化 | 喜马拉雅"珠峰"音频大模型 | 全国首个通过网信办生成式 AI 服务的音频生成类大模型；授权用单田芳评书腔调制作 100+ 张专辑 | [北青网](https://news.ynet.com/2025/11/04/3953612t70.html) |

### 1.6 界面语言、拟物与隐私

| 功能名 | 哪些产品有 | 具体怎么做的 | 来源 |
|---|---|---|---|
| **稳定伪频率 + 调频刻度盘** | OpenRadio（Atlas Tuner）、Sleek（Analog Broadcast Warmth） | 每台分配 87.5–108.0 稳定伪频率；超大等宽频率读数（如 94.3 MHz）；横向刻度尺 + 固定中心指针；节目卡做成旋钮式预设键；点阵网罩纹理；播放时 4–5 条均衡器柱动效；**仅在有声音时才动** | [OpenRadio 设计文档](https://github.com/raj-khan/openradio/blob/main/docs/design.md) · [Sleek Radio App UI](https://sleek.design/ko/templates/radio-app) |
| 指针兼作进度指示器 | Sleek | 炭黑 + 陈旧奶白 + **单一焦橙强调色**（只留给 LIVE 指示与调谐动作）；发丝级琥珀分割线代替阴影卡片；调谐指针同时是回放进度指示器 | 同上 |
| **机械咔嗒反馈 + 信号强度灯** | 复古收音机类 App | 旋钮滑动调频做机械触感反馈 + 信号强度指示灯 + 频率刻度盘 + 开机声/换台电波杂音 + 主题皮肤（木壳/金属旋钮） | [复古收音机](https://www.77xz.com/softs08/107471.html) |
| **台间白噪音 + Magic Eye（AI 内容透明指示）** | "The Spirit of Radio"（ACM IMX'26） | 复古木壳收音机里**故意合成台间白噪音**（既是氛围也是"这是哪个带"的认知标记）；O-LED 复刻的 "Magic Eye" 绿=人工内容、红=AI 生成，作为**非文本的 AI 透明度信号** | [ACM DL](https://dl.acm.org/doi/10.1145/3788851.3815017) |
| **死链也要有叙事** | Radio Dad | 404 页做成"108.0 · DEAD AIR —— 你调过头了"；整站用电台频率（87.5 THE STUDIO / 92.9 / 108.0 DEAD AIR）作章节标题；字体 Fraunces + Inter + JetBrains Mono 混排 | [Radio Dad /about](https://radiodad.app/about) |
| **"反功能"写成明规则** | Radio Dad | "Rule 1: The globe has no search. You spin like everyone else. That's the sport."；并把"没有账号、没有广告、没有追踪"写成三条明规则 | 同上 |
| 全站动效尊重系统偏好 / 高对比 | Radio Garden | `prefers-reduced-motion` 全量降级 + `prefers-color-scheme` + `[data-increased-contrast]` 高对比变量组 | [radio.garden 源码](https://radio.garden/) |
| 平板专用布局：更大地球 + 双栏 + 分屏不强制全屏 | Radio Dad on iPad | 更大的 spin-to-tune 地球；空间够时 Discover 与 Podcasts 两栏；支持四方向；**Split View / Slide Over / Stage Manager 下不强制全屏**，可边听边看笔记 | [Radio Dad iPad 页](https://radiodad.app/learn/radio-on-ipad) |
| 隐私作为差异化战场 | Radio Dad vs Radio Garden | Radio Garden 的 App Store 隐私标签列出"用于第三方广告与分析"的数据；Radio Dad 主打无账号、无广告、无追踪 | [Radio Dad 对比页](https://radiodad.app/learn/radio-garden-alternative) · [Radio Garden /about](https://radiodad.app/settings/radio-garden) |
| 收听数据年度化 | 小宇宙 | 累计时长/节目数沉淀，年底"年度收听报告"成社交货币 | [百度百科·小宇宙](https://baike.baidu.com/item/%e5%b0%8f%e5%ae%87%e5%ae%99/49717858) |

---

## 2. 最具启发性的 12 个创新点

**① theradio.app：把"老口袋收音机做不到的一百件事"打包成订阅**
谁做的：MOBILE ALCHEMY LTD（2026）。
怎么做的：免费用 Radio Browser 5 万+目录（免 key），按流派/国家（带国旗与台数）/语言（200+ 国、600+ 语言）浏览；实时搜索；后台播放 + 锁屏与控制中心全控；ICY "正在播放"元数据显示在封面上；**歌曲历史带时间戳、点按即上网搜索**；睡眠定时器；主屏/锁屏小组件；Siri 快捷指令；深链分享。付费版解锁：无限收藏、广播闹钟、**流媒体录制到"文件"App**、**设备端实时字幕**、**10 段 EQ + 预设**、**封面上的实时 FFT 条频谱可视化**、iCloud 同步。
为什么算创新：**它的功能清单几乎逐条命中本项目的现有能力**，说明"频谱可视化 + 设备端字幕 + 歌曲历史"这套组合在市场上被验证为可收费的核心价值。
可借鉴：把"频谱 + 字幕"从酷炫功能升级为付费锚点；并立刻补上"正在播放 + 歌曲历史"。
来源：[App Store](https://apps.apple.com/cn/app/radio-live-uk-world-fm/id6762442559) · [FoxData 功能摘录](https://foxdata.com/cn/app-marketing-analytics/6762442559/as/HK/%E6%94%B6%E9%9F%B3%E6%A9%9F-fm%E5%85%A8%E7%90%83%E7%9B%B4%E6%92%AD)

**② Radio Dad「地球即播放器」：十字准星对准即播，零点击**
怎么做的：3D 地球上每个真实发射台在各自坐标上；拖动地球让准星停在某个台，那个台就开始播；配 "Zap" 手势——像拨旋钮一样甩到下一个台。作者明写"地球没有搜索框，你转，它才好玩"。
为什么算创新：把"搜索列表"彻底替换为"空间探索"，产品从工具变成玩具。
可借鉴：平板中栏可做"地理发现"模式，与频谱形成"听感可视化 + 地理可视化"双轴。
来源：[Radio Dad /about](https://radiodad.app/about)

**③ Radio Dad「Road Trip」：选两个国家 → 真实公路路线 → 沿途逐国切台**
怎么做的：规划两国首都之间的真实驾车路线，每穿越一个国界就切到当地电台。
为什么算创新：把"地理位置"从静态筛选变成**叙事性播放列表**，天然适合分享。
可借鉴："城市漫游"模式——选两个城市，生成一条听感路线。
来源：[跨国收听页](https://radiodad.app/learn/listen-to-radio-from-other-countries)

**④ Radio Dad「端侧实时字幕 + 实时翻译」：给"永不停播"的广播补上字幕**
怎么做的：逐行写出台词；"原文在上、译文在下"句对句；转写 30+ 语言、翻译约 20 种；**音频不出设备**。
为什么算创新：业界长期认为"直播流没法做字幕"（不暂停、不落盘），它用端侧模型打开了这个禁区，顺手解决"外语新闻听不懂"和"口播听不清"两个刚需。
可借鉴：本项目已有实时字幕，可立刻对标升级 ①原文/译文双行对照 ②按句对齐高亮 ③词级点击跳转 ④"只显示译文"省屏模式。
来源：[Radio Dad 字幕页](https://radiodad.app/learn/radio-with-live-captions-translation)

**⑤ 喜马拉雅「AI 听中问」：把单向收听变成双向对话**
怎么做的：播放页直接与 AI 实时对话：要当前章节核心概要、结构化大纲、**定位内容大纲与时间轴**、针对情节追问；底座 ASR/NLP + DeepSeek + RAG + 长文本理解，音频流与文本解析并行压延迟。
为什么算创新：精准命中长音频三大痛点——抓不住重点、特定信息定位耗时、复杂概念需即时解读；"生成大纲"还是音频独有能力（视频做不到）。
可借鉴：本项目字幕天然可叠加"问一句 / 跳到相关片段 / 生成大纲"三件事。
来源：[中国日报网](https://ex.chinadaily.com.cn/exchange/partners/82/rss/channel/cn/columns/snl9a7/stories/WS686b8049a3106af2b3c72d00.html) · [中华网](https://digi.china.com/articles/20250725/202507251704972.html)

**⑥ 小宇宙「时间戳评论 + 热度条」：把线性音频变成可索引的时间轴**
怎么做的：评论自动锚定当前播放时间点，点击跳转；进度条按点赞热度堆出"小柱子"，高能片段一眼可见。
为什么算创新：把音频的**线性时间**变成可索引、可参与、可分享的空间——纯音频格式独有的交互资产。
可借鉴：字幕行上叠加"高能标记"（本地启发式：字幕标点密度/说话人切换频次），点击跳转 + 分享带时间戳的卡片。
来源：[安卓谷](https://www.apkgu.com/android/xyzapp) · [少数派·光锥](https://sspai.com/post/118207)

**⑦ Global Player「对直播做控制」：跳过、回退、喜欢/不喜欢**
怎么做的：点播放条进入 "Take Control"，可跳过不喜欢的歌（不限次数）、回退直播、对曲目 like/dislike，用滑动完成定制。
为什么算创新：传统电台不可跳歌，这里把点播电台的交互嫁接到直播上，实质是把广播变成"半可控"。
可借鉴：实时流 + 缓冲窗口回退 30–60 秒，配合"不喜欢→换一首"手势。
来源：[Global Player](https://apps.apple.com/us/app/global-player-radio-podcasts/id1142951331)

**⑧ Audacy「直播中的章节 + 回到开头」**
怎么做的：把体育/新闻直播切成按话题的 chapters，可直接跳到你关心的那段；可把直播 rewind 回节目开头。
为什么算创新：给线性广播加上"章节轴"，让"找人"从时间顺序变成内容索引。
可借鉴：端侧 AI 对直播流做自动话题切章，字幕侧栏直接跳转。
来源：[Audacy](https://apps.apple.com/us/app/audacy-radio-sports-talk/id323701765)

**⑨ 喜马拉雅随车听「点火即播」：用 198 元小盒子绕过车机生态壁垒**
怎么做的：点烟器插入式（8–24V 宽压）；通电即自动唤醒 App 并从上次位置续播；旋钮遥控手机端播放/暂停/切曲；FM 发射芯片信噪比 65dB、谐波失真 <0.03。
为什么算创新：**它不和车机厂商争屏幕，而是伪装成一台 FM 电台接入原车音响**——内容平台做车端最聪明的姿势。
可借鉴：内容方进别人硬件生态，"伪装成既有设备"往往比谈判更快。
来源：[快懂百科·随车听](https://www.baike.com/wikiid/9194880891491081355) · [91单机网实测](https://www.91danji.com/news/az35256.html)

**⑩ TuneIn「闹钟用真实 FM 台叫醒」**
怎么做的：闹钟不是 app 内音频，而是指定某个真实电台频率，叫醒你的是那个台。
为什么算创新：把"网络电台"最不可替代的资产（内容真实性、24/7 存在）用作闹钟，而不是当成一个音乐库。
可借鉴：闹钟从"定时停止"反向变成"定时开始"，且可以选择台。
来源：[TuneIn](https://apps.apple.com/us/app/tunein-radio-music-sports/id418987775)

**⑪ Cloud「组件化首页」：一个机制同时满足车企定制 + 用户个性化 + 运营热更**
怎么做的：5 类组件统一尺寸与交互；"页面样式 + 组件"自由组合出 **42+9 种组合布局**；节日主题（世界杯直出"赛事直播"入口）+ 车企品牌专属（背景图/7 种顶部样式/6 种栏目样式）。
为什么算创新：一个机制覆盖三方诉求，这是固定版面做不到的。
可借鉴：平板端做"卡片工位"（电台列表卡/节目单卡/频谱卡/收藏卡/路况卡），允许用户与运营双向配置。
来源：[央广传媒集团](http://www.cnrmg.cn/xwzx1/jtyw/20251030/t20251030_527413354.html)

**⑫ "The Spirit of Radio"（ACM IMX'26）：台间白噪音 + Magic Eye = 把网络的不确定性转译成 FM 语言**
怎么做的：复古木壳收音机里**故意合成台间白噪音**——既是氛围，也是"我在哪个带"的认知标记；O-LED 复刻的 "Magic Eye" 绿=人工内容、红=AI 生成，作为**非文本的 AI 透明度信号**。
为什么算创新：它把"转台"这件小事做成了**触觉 + 听觉 + 视觉三通道的仪式**，并且顺手解决了"AI 内容要不要标注"的伦理问题。
可借鉴：本项目换台时可播一段极短台间音 + haptic 咔嗒 + 频谱短暂收缩/雪花，把"网络电台"包装成"收音机"；并用一颗小指示灯区分"真人内容/AI 生成"。
来源：[ACM DL](https://dl.acm.org/doi/10.1145/3788851.3815017)

---

## 3. 界面与交互设计的 12 条借鉴点

**① 稳定伪频率 + 固定中心指针的刻度盘**（OpenRadio / Sleek）
每台分配 87.5–108.0 稳定伪频率 → 频率用等宽大号数字 → 横向刻度尺 + 固定中心指针 → 指针兼作播放进度条。**这是"网络收音机"品类最省力的视觉签名**。 [OpenRadio](https://github.com/raj-khan/openradio/blob/main/docs/design.md) · [Sleek](https://sleek.design/ko/templates/radio-app)

**② 单一强调色 + 发丝级分割线**（Sleek）
炭黑底 + 陈旧奶白字 + **只留一个焦橙强调色**（只给 LIVE 指示与调谐动作）；用发丝级琥珀分割线代替厚重的阴影卡片。频谱类动效在暗色下才是主角，本项目已是深色主题，只需把强调色收成单一。

**③ 机械咔嗒 + 信号强度灯**（复古收音机类 App）
旋钮拖动调频配 haptic 咔嗒；信号强度条表达**码率/缓冲状态**，把网络的不确定性翻译成听众熟悉的 FM 语言。 [复古收音机](https://www.77xz.com/softs08/107471.html)

**④ 频谱的"仅在有声音时才动"**（OpenRadio）
动效由实际音频能量驱动而非定时器，空闲时静止；并整体尊重 `prefers-reduced-motion`。本项目已有真实 FFT，天然具备这个条件。

**⑤ 死链也要有叙事**（Radio Dad）
404 页做成"108.0 · DEAD AIR —— 你调过头了"；整站用频率（87.5 THE STUDIO / 92.9 / 108.0 DEAD AIR）作章节标题。错误态也可以成为品牌资产。 [Radio Dad](https://radiodad.app/about)

**⑥ "反功能"写成明规则**（Radio Dad）
"地球没有搜索框"是刻意的产品态度，就该写明理由，而不是每次被提需求就加个搜索框。写进设计文档能减少内部反复。

**⑦ 左侧锚定的驾驶位布局 + 竖滑切换**（云听车载 3.6）
核心功能集中在左侧导航栏，主驾不用弯腰侧身；改版后**视线离开路面时间缩短 50%**。平板横屏同理：高频操作（频谱、频道列表、字幕）贴左手侧。 [央广传媒集团](http://www.cnrmg.cn/xwzx1/jtyw/20251030/t20251030_527413354.html)

**⑧ 搜索框的"零输入可用"**（云听车载）
未输入时铺热门底纹词与搜索热词，**点击直接播放**。把"直接收听"提到第一层，"搜索"降级为可选动作。本项目搜索页默认态不应是空输入框。

**⑨ 弹窗可关闭 + 消息中心留档**（云听车载应急广播）
打断最小化：预警弹窗点"我知道了"即关，不打断当前播放；历史进"消息中心"随时可查。

**⑩ 进度条升级为"复合信息控件"**（小宇宙 + 少数派"光锥"）
进度条上同时画：章节刻度、评论/高能热度柱、文稿高亮行指示器、频谱镜像。这是**纯音频格式独有的信息密度优势**，也是本项目"真实频谱 + 实时字幕"最该被兑现的地方。 [少数派](https://sspai.com/post/118207)

**⑪ "最近播放"作为一等公民**（myTuner / radio.net / Radio Dad）
"最近收听电台"与"正在播的曲目"必须是首屏元素，而不是藏在二级页。Radio Dad 的 CarPlay 第一屏就是 Favorites / Recents / Now Playing。

**⑫ 平板专用布局 + 分屏不强制全屏**（Radio Dad on iPad）
更大的地球 + 空间够时双栏 + 支持四方向 + **Split View / Slide Over 下不强制全屏**，可以边听边看笔记。手机版放大 ≠ 平板版。

---

## 4. 对本项目的落地建议

> 按"落地性价比"排序。难度：低＝1–2 天；中＝1–2 周；高＝需模型/图形投入或外部数据源。

### 第一梯队：低难度、立刻可做、感知强

| # | 建议 | 落地要点 | 难度 | 预期价值 |
|---|---|---|---|---|
| 1 | **给每个电台分配稳定伪频率，做成可滑选的调频刻度盘** | 87.5–108.0 稳定映射（按现有列表顺序或哈希固定，永不变）；频率用等宽大号数字；横向刻度尺 + 固定中心指针；指针兼作播放进度条；换台配 haptic 咔嗒 | 低 | **高**——直接确立"网络收音机"的品类辨识度，是本项目最该先做的一件视觉事 |
| 2 | **接 ICY 元数据，显示"正在播放"** | `AVPlayer` 侧监听 ICY 标题（部分流需 `AVMediaMetadata` 轮询），解析出歌手/曲目；显示在播放器标题栏与锁屏卡片 | 中 | **高**——补齐"我现在到底在听什么"这一根本空白；theradio.app / myTuner 都把它当核心 |
| 3 | **搜索页默认态改为"此刻热听"底纹词墙** | 未输入时铺 20–30 个热门台名/题材词，**点击直接播放**（不进结果页），输入后联想词分层（常听优先并标"一键直达"） | 低 | **高**——几乎零成本，直接提升首屏可用性 |
| 4 | **"此刻开始听"一键复播上次那台** | 锁屏卡片/桌面服务卡片/冷启动首屏都提供"继续听"入口（目前已有"记忆上次收听电台"，把它抬到首屏显眼位置） | 低 | 中高 |
| 5 | **隐私与端侧作为显式卖点** | 字幕/听感调节全本地、零账号、无遥测；在"关于"页写明"字幕不上传、音频不出设备" | 低 | 中高——海外电台 App 的隐私标签正是被诟病点，可反向做差异化（[Radio Dad 对比页](https://radiodad.app/learn/radio-garden-alternative)） |
| 6 | **适老化/无障碍模式提到一等公民** | 三档字号 + 极简模式（只留播放与电台列表）+ **控件点击语音提示** + 语音搜索 + 高对比配色 + "只留 5 个常用台" | 低 | **高**——银发是听书主力人群；抄懒人听书大字版"独立精简包"思路 |
| 7 | **端侧音效预设升级为"场景音效包"** | 现有 12 档基础上叠加 4–6 个场景包（驾驶/人声播报/助眠白噪/会议/老人耳背），每包 = EQ + 人声增强 + 动态范围压缩 + 混响量 + 语速；播放页显示当前包名 | 低 | **高**——纯端侧、零成本、立刻可感知 |

### 第二梯队：中难度、构成能力差

| # | 建议 | 落地要点 | 难度 | 预期价值 |
|---|---|---|---|---|
| 8 | **进度条升级为复合信息控件** | 在频谱/进度条上叠加：AI 生成的**章节刻度**、**高能片段标记**（本地启发式：字幕标点密度/说话人切换频次）、**文稿高亮行指示器**；点击标记直接跳播 | 中 | **高**——复用已有字幕管线，边际成本低，显著提升长内容可控性 |
| 9 | **字幕升级为"原文/译文对照 + 只译文"模式** | 端侧翻译；句对句对齐；字幕区可折叠为单行浮条省屏 | 中 | **高**——直接放大"外语台"与"口播听不清"两类刚需（对标 [Radio Dad](https://radiodad.app/learn/radio-with-live-captions-translation)） |
| 10 | **节目单（EPG）第三栏 + 追更预约** | 聚合各台 XMLTV/站点节目单；"正在播 / 接下来"时间轴 + 当前档高亮；开启后到点提醒并自动接续；无节目单时用 ICY 曲目名兜底 | 中 | **高**——补齐"直播电台"与"点播 App"的能力差（蜻蜓"节目预约"、云听节目单均已验证） |
| 11 | **横屏双栏/分屏工作台** | 横屏时左栏=电台+频谱，右栏=**文稿/节目单/收藏**可切换；支持拖拽把某台甩进"正在播"（对标爱奇艺车机"甩动转屏"）；浮窗小控件可独立悬浮 | 中 | **高**——平板区别于手机的核心形态 |
| 12 | **系统级服务卡片 + 桌面卡片 + 意图导出** | 把"打开某电台""调频到某台"做成鸿蒙 Service Widget / Intent，供桌面与系统调用；是"跨端流转"的前置能力 | 中 | **高**——鸿蒙生态的差异化入口，别的平台抄不走 |
| 13 | **本地台分组 + 弱网降级 + 缓存** | 定位默认置顶"本地台"；常用台支持缓存；弱网自动降码率 + 缓存优先 + 明确提示"当前为缓存内容/延迟 X 秒" | 中 | 中高——直接回应"网络电台最大痛点：隧道/弱网/流量" |
| 14 | **"描述式电台"：一句话生成我的电台** | 用户输入"我想听写稿时背景不抢戏的爵士"→ 生成可持续更新的频道流；运营端预置多个"场景电台"模板（通勤/助眠/学习/老人） | 中 | **高**——现有"地区/题材筛选"是静态维度，这是动态维度，差异化明显 |

### 第三梯队：高难度、长期价值

| # | 建议 | 落地要点 | 难度 | 预期价值 |
|---|---|---|---|---|
| 15 | **直播回看 + 端侧自动切章** | 30–60 秒回退滑杆；端侧 AI 对直播流做话题切章，字幕侧栏按章跳转 | 高 | **高**——"不是播客，但也能回看"是广播类 App 的核心差异化 |
| 16 | **端侧"Ask 电台"** | 自然语言选台（"大阪的爵士"）+ 在当前字幕里做句子检索反查节目 | 高 | **高**——移动端 LLM 最有说服力的落地场景 |
| 17 | **中栏新增地球/地图选台视图** | 城市气泡 + 准星命中即播 + "Zap"甩动切台；与频谱形成双轴可视化 | 中高 | 中高——平板大屏最能承载 3D 地球 |
| 18 | **AI 主持人（端侧）口播串场** | 频谱 + 字幕驱动一个虚拟主播在曲间串场（天气/本地话题/下一档预告），可关；不同音色人格可选 | 高 | **高**——把已有频谱与字幕"活"起来，最容易做出传播点的差异化功能 |
| 19 | **接 Radio Browser 作为目录兜底与死链治理** | 用 `lastcheckok` 过滤死链、`codec/bitrate/hls` 决定解码路径、`geo_lat/geo_long` 做"附近电台"；数据 CC0、成本为零 | 中 | **高**——解决"哪个台还活着"与"海外台 geo-block"两大体验雷区（[API](https://all.api.radio-browser.info/json/stations/topclick/2)） |
| 20 | **节目单编排（自动化播控）** | 定时切台 + 自动垫乐/广告位 + 淡入淡出曲线 + 场景预设（早高峰/睡前/专注），可导出为"电台模板" | 中 | 中高——把现有"音效预设"升级为"节目单预设" |
| 21 | **空间化：端侧听感调节 → 伪空间化** | 声像展宽、场景混响、头部感应；为后续对接杜比全景声 / Audio Vivid 留出协议位 | 高 | 中——是"端侧听感调节"的自然延伸 |

### 可选补充

- **收藏"正在播的这条歌"而非只有电台**（RadION 的 Scrap 思路）：从 ICY 曲目一键存入本地曲库/收藏夹，带时间戳。
- **流媒体录制**（theradio.app 付费版 / RadioRec）：把电台存到本地文件，RadioRec 的做法是精确到分钟 + 按星期几 + 自动写 ID3。
- **音频 → 带字幕短视频导出分享**（小宇宙）：社交传播效率极高。
- **收听年度报告**：把时长/台数沉淀成可分享的卡片（小宇宙）。
- **Magic Eye 式 AI 透明指示**：一颗小灯区分"真人内容 / AI 生成"（ACM IMX'26）。

---

## 5. 本项目现状 vs 竞品：差距诊断

| 维度 | 本项目现状 | 主流竞品 | 差距判断 |
|---|---|---|---|
| 台单 | 2105 个静态内置、离线可用 | Radio Browser 5.8 万+ 在线目录，带健康检查 | **不是劣势**——离线可用是特色；但缺"死链治理"与"更多台" |
| 频谱 | 真实 PCM FFT，9 样式 × 5 配色 | theradio.app 用封面上的 FFT 条；多数 App 无频谱 | **领先**——真频谱 + 多样式是我们的护城河 |
| 字幕 | 端侧 AI 实时字幕，仅显示不落盘 | Radio Dad 端侧字幕 + 句对句翻译；小宇宙文稿可导出可搜索 | **领先但欠一步**——差"原文/译文对照""落盘可搜索""章节/高能标记" |
| 正在播 / 歌曲历史 | 无 | theradio.app / myTuner / RadION 都有 | **明显缺口**（建议 #2） |
| 节目单 | 无 | 蜻蜓/云听/云听车载/Radio 24 都有 | **明显缺口**（建议 #10） |
| 回看/时移 | 无 | Global Player / Audacy / 蜻蜓 / 喜马拉雅都有 | 缺口，但依赖服务端时移能力，优先级后置 |
| 播控形态 | 锁屏卡片 + 通知栏 + 耳机按键 | 普遍再加：小组件、Siri、桌面歌词、CarPlay/Auto | 缺"桌面/系统级入口"（建议 #12） |
| 音效 | 12 档端侧预设 + 响度增益 + 感知音量曲线 | RadioRec 有响度归一化；Pocket Casts 有 boost/trim silence | 领先，但缺"自动响度归一化跨台" |
| 跨端 | 无 | 网易云鸿蒙、喜马拉雅、TuneIn 全都有 | 缺口（建议 #12 → #跨端续播） |
| 无障碍 | 大字模式 | 懒人听书大字版、Radio Garden 高对比、reduced-motion | **缺口**（建议 #6，成本低） |

---

## 6. 来源清单

### ① 官方 / 权威
1. 央广传媒集团《2025 云听车载 App 3.6 版本正式上线》 — http://www.cnrmg.cn/xwzx1/jtyw/20251030/t20251030_527413354.html
2. 央广网《云听车联网携手中国交通广播(湖南)、湖南高速创新车路云协同应用》 — https://www.cnr.cn/yggg/ygdt/20250509/t20250509_527163834.shtml
3. 中国日报网《喜马拉雅推出"AI 听中问"功能》 — https://ex.chinadaily.com.cn/exchange/partners/82/rss/channel/cn/columns/snl9a7/stories/WS686b8049a3106af2b3c72d00.html
4. 中国日报网·HDC2025《喜马拉雅：AI 智能体与空间音频升级车载娱乐体验》 — https://ex.chinadaily.com.cn/exchange/partners/82/rss/channel/cn/columns/snl9a7/stories/WS6863a9efa3106af2b3c71f23.html
5. 中国日报网《喜马拉雅受邀参加 2025 华为开发者大会》 — https://ex.chinadaily.com.cn/exchange/partners/82/rss/channel/cn/columns/snl9a7/stories/WS6863a9efa3106af2b3c71f23.html
6. 车质网《智能车机评测：2025 款蔚来 ET9》 — https://m.12365auto.com/scbg/20250530/548690_3.shtml
7. 车质网《2019 款蔚来 ES6 日常实用性测试报告》（收音机界面） — https://m.12365auto.com/scbg/20200908/437660_3.shtml
8. 理想汽车社区《车机免费流量用完了怎么办（FM 收音机应用）》 — https://www.lixiang.com/community/detail/article/2648872.html
9. 新浪《理想 ONE 车机说明》 — https://k.sina.cn/article_7880068201_1d5b04c6901901xhde.html
10. 中国商报网《主流终端全适配 网易云音乐鸿蒙版全新适配华为 HiCar》 — https://www.zgswcn.com/news.html?aid=378409
11. 中华网科技《喜马拉雅亮相 2025 上海车展》 — https://m.tech.china.com/articles/20250425/202504251665518.html
12. 中华网数码《喜马拉雅首发"AI 听中问"：音频交互进入对话式时代》 — https://digi.china.com/articles/20250725/202507251704972.html
13. 中华网科技《喜马拉雅 Miniboom Aplus 重磅发布》 — https://m.tech.china.com/articles/20250930/202509301742989.html
14. 新浪《喜马拉雅小雅 AI 正式推出 #AI 荐书#》 — https://www.sina.cn/news/detail/5249243334838926.html
15. 北青网《喜马拉雅亮相 2025 广播论坛》（珠峰大模型/单田芳） — https://news.ynet.com/2025/11/04/3953612t70.html
16. 国企网《喜马拉雅移动端全景声音质上新》 — https://www.cnsoe.com.cn/cjsy/content_121947.html
17. 中国青年网《小米发布触屏音箱，喜马拉雅小雅 OS 内容技能共同加持》 — https://d.youth.cn/newtech/201902/t20190221_11876043.htm
18. 环球网《喜马拉雅亮相石家庄数博会》（小雅 OS 技能指标） — https://3w.huanqiu.com/a/f27b59/9CaKrnKnekE
19. 凤凰网科技《喜马拉雅亮相中国国际数字经济博览会》（云历史/断点续播） — https://itech.ifeng.com/45688614/news.shtml
20. 中国青年网《打车"随心听"，点歌你来定：酷我车载创新首发》 — https://fun.youth.cn/yl24xs/202311/t20231108_14895197.htm
21. 网易新闻《喜马拉雅"奇奇学"让孩子自信开口说英语》（AI 换声·爸妈分身） — https://c.m.163.com/news/a/KET2J9FG0525ETL1.html
22. 腾讯新闻《从微信灰度测试到 Google/字节/小红书等下场，AI 播客能否抢滩 AIGC 新蓝海？》 — https://news.qq.com/rain/a/20251008A05MZQ00
23. Rolling Stone《AI Is Replacing Radio Disc Jockeys》 — https://www.rollingstone.com/music/music-features/ai-is-replacing-radio-disc-jockeys-1235463028/
24. 天脉网《从〈Her〉到现实：前百川智能联创焦可创业，用 AI 音频造主播开启新赛道》 — https://www.dtm.com.cn/news/202602/190883.html
25. 小宇宙播客《ep1. 来福：一个纯 AI 生成播客产品的诞生》 — https://www.xiaoyuzhoufm.com/episode/69bf93ed2d318777c91e70af
26. 快懂百科·随车听 — https://www.baike.com/wikiid/9194880891491081355
27. 百度百科·小雅智能语音助手 — https://baike.baidu.com/item/小雅智能语音助手/67272815
28. 百度百科·AI 听中问 — https://baike.baidu.com/item/AI听中问/67308208
29. 百度百科·小宇宙 — https://baike.baidu.com/item/小宇宙/49717858
30. 什么值得买《特斯拉物理拆了调谐器…电车听广播的三条路线》 — https://post.smzdm.com/p/am9xqkod
31. Apple《CarPlay Developer Guide》（2026-10） — https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf
32. Apple CarPlay 主页 — https://developer.apple.com/carplay/
33. Apple Podcasts 创作者文档（转写与搜索） — https://podcasters.apple.com/support/823-podcast-transcripts
34. Radio Garden 官网 / 设置页 / 源码 — https://radio.garden/ ｜ https://radio.garden/settings/radio-garden
35. Wikipedia·Radio Garden — https://en.wikipedia.org/wiki/Radio_Garden
36. Radio Dad 官网 / about / stations / 字幕页 / 车载页 / iPad 页 / 跨国收听页 / 对比页 — https://radiodad.app/ ｜ https://radiodad.app/about ｜ https://radiodad.app/stations ｜ https://radiodad.app/learn/radio-with-live-captions-translation ｜ https://radiodad.app/learn/best-carplay-radio-app ｜ https://radiodad.app/learn/radio-on-ipad ｜ https://radiodad.app/learn/listen-to-radio-from-other-countries ｜ https://radiodad.app/learn/radio-garden-alternative
37. TuneIn（App Store 开发者自述） — https://apps.apple.com/us/app/tunein-radio-music-sports/id418987775
38. iHeartRadio（App Store） — https://apps.apple.com/us/app/iheart-radio-music-podcasts/id290638154
39. Audacy / Radio.com（App Store） — https://apps.apple.com/us/app/audacy-radio-sports-talk/id323701765
40. radio.net（App Store） — https://apps.apple.com/us/app/radio-net-am-fm-radio-tuner/id402206359
41. myTuner Radio（App Store） — https://apps.apple.com/us/app/mytuner-radio-live-stations/id520502858
42. Global Player（App Store） — https://apps.apple.com/us/app/global-player-radio-podcasts/id1142951331
43. Radio 24（App Store，PALINSESTO 节目单） — https://apps.apple.com/us/app/radio-24/id365304617
44. Yoodio AI Radio（App Store） — https://apps.apple.com/us/app/yoodio-ai-radio-with-live-djs/id6743950965
45. AccuRadio（App Store） — https://apps.apple.com/us/app/accuradio-curated-music-radio/id351425453
46. Pocket Casts（App Store） — https://apps.apple.com/us/app/pocket-casts-podcast-player/id414834813
47. Podcast App（App Store，AI Digest） — https://apps.apple.com/us/app/podcast-app/id1199070742
48. Podbean / Player FM（App Store，响度处理） — https://apps.apple.com/us/app/podbean-podcast-app-player/id973361050 ｜ https://apps.apple.com/us/app/player-fm-podcast-app/id940558467
49. 收音机: FM 全球直播 theradio.app（App Store，功能清单） — https://apps.apple.com/cn/app/radio-live-uk-world-fm/id6762442559
50. Radio Browser 公开 API 实测（topclick / 字段列表） — https://all.api.radio-browser.info/json/stations/topclick/2 ｜ https://de1.api.radio-browser.info/json/stations/bycountrycodeexact/US?limit=1
51. AntennaPod 官方仓库与 Wiki — https://github.com/AntennaPod/AntennaPod ｜ https://github.com/Hjinwen/AntennaPod/wiki/About-AntennaPod
52. Internet Archive 广播节目收藏 — https://archive.org/details/radioprograms
53. ACM IMX'26《Leveraging a Vintage Radio Interface to Explore Media Recommender Systems》（台间白噪音 + Magic Eye） — https://dl.acm.org/doi/10.1145/3788851.3815017
54. GitHub·OpenRadio 设计文档（Atlas Tuner） — https://github.com/raj-khan/openradio/blob/main/docs/design.md
55. GitHub·Radio Player Pro（KernFerm，开源桌面收听端，社区投票排序） — https://github.com/KernFerm/Radio-Player-Pro/blob/main/README.MD
56. Softpedia·RADIO Player Pro（Radiosoft，广播自动化） — https://www.softpedia.com/get/Multimedia/Audio/Audio-Players/RADIO-Player-Pro.shtml
57. mysoftreview·RADIO Player Pro 规格与版本日志 — http://mysoftreview.com/buy/315135/
58. Digital Radio Choice·Amazon Alexa 播电台 — https://www.digitalradiochoice.com/smart-speakers/amazon-alexa/
59. Business Today·Alexa 支持 350+ 印度电台 — https://www.businesstoday.in/storyprint/318509
60. RadioRec（macOS，计划录制 / ID3 / 响度归一化） — https://gtc-trading.com/audio/62728-radiorec.html
61. AI 电台主持实验（ChatGPT/Gemini/Claude/Grok 主持 + 实体复古收音机） — http://www.ai-jarvis.eu/ai-radio-host-experiment-chatgpt-gemini-and-claude-reveals-bizarre-behavior

### ② 媒体转载 / 行业分析
62. 少数派《小宇宙网页版：评论热力图、逐字文稿和"只有大屏才放得下"的功能》 — https://sspai.com/post/118207
63. 图扬科技《纯空间音频》（马栏山车载实时上混） — http://www.tome-sz.com/hynews_view.aspx?id=1082&nid=1&typeid=50046
64. CSDN / 火山引擎《Cleer Arc5 如何实现头部追踪的空间音频系统》 — https://vcloud.csdn.net/6ad17c6c536f457592b03df9.html
65. Sleek《Radio App UI Design Template（Analog Broadcast Warmth）》 — https://sleek.design/ko/templates/radio-app
66. RadioInfo Australia《How AI is changing Radio now》 — https://radioinfo.com.au/ai-generative-artificial-intelligence/how-ai-is-changing-radio-now/
67. FoxData《收音机: FM 全球直播 应用功能摘录》 — https://foxdata.com/cn/app-marketing-analytics/6762442559/as/HK/%E6%94%B6%E9%9F%B3%E6%A9%9F-fm%E5%85%A8%E7%90%83%E7%9B%B4%E6%92%AD

### ③ 应用下载站 / SEO 站（仅用于"某 App 有某功能"的存在性判断）
68. 喜马拉雅手机端播放页说明（夜间/极简/亲子模式、直播回放、日历回听） — https://m.k73.com/down/android/192267.html
69. 喜马拉雅车载版 v7.1.0.04（AI 电台续播/品牌电台/瀑布流） — https://www.oppojia.com/app/24543081.html ｜ https://m.87g.com/az/203653.html
70. 蜻蜓FM（车载模式/线控换台/节目预约/电台闹钟/24 小时回听） — https://www.ryzj123.com/app/27431889.html ｜ https://www.downyu.com/downinfo/144115.html ｜ https://www.syx888.com/sjapp/1271.html ｜ https://m.downke.com/android-3203.html
71. 小宇宙（文稿字幕/高能时刻/时间戳评论/热度条/音频转短视频/同声传译） — https://market.goapk.com/pkg/xiaoyuzhoufm ｜ https://www.apkgu.com/android/xyzapp ｜ https://www.paopaoche.net/app/2370953.html ｜ https://www.1fdh.com/sites/4033.html ｜ http://www.sdmi88.cn/sites/25252.html
72. 懒人听书大字版（适老化/语音提示/一键收听） — https://www.51wan.com/azsoft/lrtsdzb/ ｜ https://kinghonor.cn/soft/20845.html
73. 猫耳FM（广播剧/ASMR/语音直播/追更通知） — https://www.shouji.com.cn/down/1583019.html ｜ https://www.lltw1.com/down/201087.html
74. RadiON 网上广播（Shoutcast 5 万+、Scrap 收藏当前曲目、电台闹钟/录音、界面口碑） — https://baike.baidu.com/item/RadiON网上广播/16088590
75. 复古收音机类 App（旋钮调频/信号强度灯/主题皮肤/机械咔嗒） — https://www.77xz.com/softs08/107471.html ｜ https://m.wdsj2.com/game/v_2240469.html ｜ https://tujixiazai.com/biaozhunguifan/v675836.html
76. 91单机网《喜马拉雅随声听实测》 — https://www.91danji.com/news/az35256.html
77. Mixlr（UGC 电台） — https://mixlr.en.uptodown.com/android
78. AntennaPod Android Auto 支持与社区评价 — https://www.tycp.xyz/2138.html

### 已剔除（仅记录以便复核，不采信任何事实性主张）
sugggest.com、sakerplus.net、enveu.com、iptvsky.ca、tashantv.net、nviewx.com、raudoiptv.com、waybb.xyz、carplayabc.com、mac-os.org 系列；某下载站对猫耳 FM 的"声纹捏脸/AR 声音剧场/AI 情绪识别广告"描述；某站对小宇宙"97% 用户认为时间戳提升效率""完播率提升 22%"等无出处数据；部分 AI 生成的"产品介绍"站功能清单。

### 两点诚实声明
1. Radio Browser 前端 `radio-browser.info` / `rnabrowser.com` 本次访问受区域限制，结论基于其**公开 API 的实测响应**与 Radio Dad 官方说明。
2. Apple 未在公开文档逐家列出 CarPlay 支持哪些第三方电台 App，本报告只引用了**各厂商官方 App Store 描述中的自述**与 Apple 官方的类别与数量限制。
