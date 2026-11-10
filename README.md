# 鸿蒙收音机

基于 **HarmonyOS ArkTS 原生**开发的平板网络收音机，参考 `youdao-tinglibao-e6` 中的 radio 示例实现，针对大屏重新设计了布局与交互。内置 2105 个网络电台，列表数据静态编译进 HAP，启动即可浏览，无需联网拉取台单。

![平板横屏主界面](preview/screenshot.png)



> 真机截图：[横屏](preview/device_screenshot.jpeg) · [竖屏播放页](preview/screenshot_portrait.png) · [12 档音效设置](preview/sound_effects.jpeg) · [可交互 HTML 预览](preview/index.html)（`?settings=1` 展开设置）

## 功能

| 模块  | 说明                                                                  |
| --- | ------------------------------------------------------------------- |
| 电台库 | 2105 个电台，静态数据分片为 4 个 ArkTS 模块；支持名称／省市／题材搜索                          |
| 筛选  | 范围（全部／最近播放／收藏／国内／国际）+ 省市胶囊 + 题材胶囊，多维叠加，选中态实时高亮                           |
| 最近播放 | 左侧导航一等公民入口：列出最近收听的电台并标注相对时间（刚刚／N 分钟前／昨天），可一键清空；锁屏卡片切台同样计入 |
| 收藏  | 收藏夹、任意列表内一键收藏，持久化保存                                                 |
| 播放  | 系统 `AVPlayer` 直连网络流；播放／暂停／停止、音量调节、上一台／下一台、顺序／随机切台                   |
| 后台播放 | 接入系统播控中心（AVSession）并申请 `AUDIO_PLAYBACK` 长时任务：退到后台／锁屏后继续出声，锁屏与控制中心有播控卡片（播放／暂停／上一台／下一台／停止），支持耳机按键与点击通知回到应用；睡眠定时改由服务侧计时，后台也能按时停 |
| 平滑切台 | 切台先淡出旧台再换流、新台从 0 电平淡入；暂停／恢复／停止／拖动音量同样平滑过渡，消除流切换的电平跳变爆音；渐变时长可选关闭／短／标准／舒缓 |
| 音效  | 12 档端侧听感预设（原声／纯音／新闻／人声／音乐／醇厚／影院／环绕／游戏／收音机／夜间／轻语），组合 `audioRendererInfo.usage` 系统音效链路（音乐／影院／有声书／游戏）、`setLoudnessGain` 响度增益（−12 ~ +6 dB）、感知音量曲线、削峰余量与渐入时长；另提供响度微调（−12 ~ +12 dB）、柔和度、系统音效引擎开关，全部无需云端或自行解码 PCM |
| 音量归一化 | **默认开启**。用真实音频解析拿到流里的 PCM，逐拍算 RMS 节目电平，取 75 分位作为该台代表响度，与目标电平（−17 dBFS）相减得到修正量（±9 dB 内，取 0.5 dB 一档），并入 `setLoudnessGain` 链路与听感预设、用户微调叠加（越界时优先保住归一化值）；每台的修正值持久化，下次听同一台直接套用，换台时不再忽大忽小 |
| 容错  | 播放失败时在 `http` / `https` 备用线路间自动重试一次；明文流由网络安全配置放行                    |
| 频谱  | Canvas 复刻 E6 的 9 种样式（双向镜像／经典柱状／LED 点阵／峰值山峰／动感波峰／环形雷达／瀑布流／粒子散落／分贝电平）× 5 套配色（彩色／灰白／随机／赛博／琥珀） |
| 实时字幕 | 系统 `@kit.SpeechKit` 的 `AICaptionComponent`，端侧离线中文识别；5.1.0(18) 起自动识别本应用播放的音频，无需云端密钥或 PCM 喂流，设置中可开关；仅显示，不落盘 |
| 定时  | 睡眠定时 0 / 15 / 30 / 60 / 90 分钟，倒计时显示                                 |
| 记忆  | `@ohos.data.preferences` 保存收藏、上次收听电台、最近播放记录、每台的归一化增益、音量、音效档位／响度微调／柔和度、渐变档位、系统音效开关、样式、配色、随机模式 |
| 适配  | ≥1000vp 三栏（导航／列表／播放器），680–1000vp 紧凑三栏，<680vp 单栏 + 底部页签；竖屏播放页自顶部纵向铺满 |
| 资源  | 深色主题、中文／英文文案、应用与启动图标                                                |

## 环境要求

- **DevEco Studio** 及配套 SDK：`compatibleSdkVersion 6.1.1(24)`，`targetSdkVersion 26.0.0`，`runtimeOS: HarmonyOS`
- **设备**：`tablet` / `phone`，HarmonyOS 6.1.0 及以上，已开启开发者模式与 USB 调试  
  （已在 HUAWEI MatePad Mini 悦读版 MLR-AL00 / API 24 上真机验证）
- **网络**：应用声明 `ohos.permission.INTERNET`；播放需要可访问电台流地址的网络
- **后台**：应用声明 `ohos.permission.KEEP_BACKGROUND_RUNNING` 并在 `EntryAbility` 上配置 `backgroundModes: ["audioPlayback"]`，用于后台播放的长时任务
- **工具脚本**：Python 3（数据导出／图标生成）、Bash（无线调试脚本）；DevEco 自带 Node 用于命令行构建

## 快速开始

1. 克隆仓库并用 DevEco Studio 打开工程根目录。
2. **配置签名**：`File → Project Structure → Signing Configs` 勾选自动生成签名。  
   仓库中的 `build-profile.json5` 刻意将 `signingConfigs` 留空（不含任何证书与密码），**未签名无法安装到真机**。
3. 连接设备或启动模拟器，点击 Run。首次编译会同步 `oh_modules` 依赖。

命令行编译（macOS，路径按本机 DevEco 安装位置调整）：

```bash
cd hongmeng-shouyinji
export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
export JAVA_HOME="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home"
export PATH="$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH"
node /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

已装好无线调试脚本的话，等价命令是 `./tools/wireless.sh build`。

产物在 `entry/build/default/outputs/default/`。签名成功后为 `entry-default-signed.hap`，用 `hdc install -r` 安装。

> **注意**：命令行必须使用 DevEco 自带的 JBR。系统 JDK 8 读取新版调试证书会报 `11014003 Init keystore failed`。

## 目录结构

```
AppScope/                     应用级配置、图标与字符串资源
entry/src/main/
  ets/entryability/           EntryAbility（Stage 模型入口）
  ets/pages/Index.ets         全部 UI：三栏布局、列表、播放器、设置
  ets/model/
    Station.ets               数据模型、范围/样式枚举、色板
    RadioStore.ets            筛选、收藏、preferences 持久化
    StationData.ets           静态电台数据汇总入口
    data/StationDataPart*.ets 自动生成的电台分片（请勿手工编辑）
  ets/player/RadioPlayer.ets  AVPlayer 封装、状态机、音量渐变引擎、端侧音效预设、归一化增益、备用线路重试
  ets/player/RadioService.ets 播放服务单例：持有播放器、播控中心会话（AVSession）、长时任务、睡眠定时
  ets/player/LoudnessNormalizer.ets 音量归一化：电平采样 → 稳健分位数 → 每台修正增益
  ets/player/SpectrumAnalyzer.ets 真实频谱分析器的 ArkTS 封装（含节目电平 level()）
  ets/view/SpectrumPainter.ets Canvas 频谱绘制
  resources/                  颜色、字符串、图标、页面路由、网络安全配置
preview/                     可交互 HTML 原型 + 各尺寸／真机截图
tools/
  export_stations.py          从 radio.db 生成 ArkTS 数据模块与预览数据
  gen_icons.py                生成应用／启动图标
  verify_norm_recent.sh       音量归一化 / 最近播放的真机验证脚本
  wireless.sh                 无线连接、编译推送、日志、截图
```

## 无线调试

`tools/wireless.sh` 把「编译 → 无线推送 → 启动」串成一条命令，改完代码不必插线。

| 命令                                             | 作用                               |
| ---------------------------------------------- | -------------------------------- |
| `./tools/wireless.sh enable`                   | **首次**：插 USB 开启设备 TCP 调试端口（8710） |
| `./tools/wireless.sh connect [IP]`             | 建立连接；IP 变化时会扫描局域网自动找回设备          |
| `./tools/wireless.sh push --build`             | 常用：编译并签名 + 无线覆盖安装 + 启动           |
| `./tools/wireless.sh push`                     | 仅推送已有 HAP                        |
| `./tools/wireless.sh build`                    | 仅编译并签名                           |
| `./tools/wireless.sh log [关键字]` / `logf [关键字]` | 抓取／实时跟随日志                        |
| `./tools/wireless.sh shot [路径]`                | 无线截图                             |
| `./tools/wireless.sh shell "命令"`               | 无线执行 shell 命令                    |
| `./tools/wireless.sh keepalive`                | 15 秒心跳，避免 DevEco 中设备空闲掉线         |
| `./tools/wireless.sh status` / `disable`       | 查看连接／关闭 TCP 端口（关闭需插着 USB）        |

前提：电脑与设备在**同一局域网**。无线会话空闲会掉线，脚本每次执行命令前会自动重连；设备 IP 记在 `.wireless-device`（已忽略提交）。

> **安全提醒**：8710 端口在局域网内无认证，同一 Wi-Fi 下的其他设备也能连接。调试结束请执行 `disable` 关闭。设备重启后若端口未自动恢复，插一次线重新执行 `enable` 即可。

## 验证后台播放

```bash
./tools/wireless.sh push --build     # 编译 + 安装 + 启动
./tools/wireless.sh logf RadioService # 另开一个终端跟随日志
```

1. 在应用里点开任意电台，等状态变成「正在播放」；
2. 按 Home 键退到后台 —— 声音应当继续；
3. 锁屏 / 下拉控制中心，应当出现媒体卡片，显示台名与地区，可播放／暂停／上一台／下一台；
4. 在卡片上按「下一台」，回到应用后应看到列表与频率都已切到新台。

日志里应当依次出现：

| 日志关键字 | 含义 |
| --- | --- |
| `av session ready` | 播控中心会话建立成功 |
| `continuous task acquired` | 后台长时任务申请成功（进程不会被挂起） |
| `continuous task released` | 停止播放时长时任务已释放 |

若 `continuous task acquired` 没出现，多半是 `ohos.permission.KEEP_BACKGROUND_RUNNING` 没授上；用 `./tools/wireless.sh shell "bm dump -n com.example.helloworld"` 可以确认权限状态。

## 验证音量归一化与最近播放

```bash
# 设备需处于解锁状态（锁屏时系统会拒绝启动应用）
bash tools/verify_norm_recent.sh
```

脚本会播放一个电台、等待约 18 秒让测量完成，然后打印 `RadioPlayer` 日志与界面上与归一化／最近播放相关的文案。要点：

| 现象 | 含义 |
| --- | --- |
| 日志 `loudness <n> dB applied` | 系统响度增益可用，归一化走 `setLoudnessGain` 链路 |
| 日志 `loudness unsupported` + `fall back to volume scaling` | 本机不支持系统响度增益，已自动降级为音量缩放 |
| 设置面板出现「本台已归一化 ±X.XdB」 | 测量出结果并已生效 |
| 播放页台名下方出现「· 归一化 ±X.XdB」 | 修正值对用户可见 |
| 左侧导航出现「最近播放」及条数 | 收听历史在一等公民位置 |

手动验证最近播放：播放任意电台 → 点「下一台」两三次 → 左侧点「最近播放」，应看到按时间倒序的列表与相对时间。

## 数据与工具

电台数据来自参考项目 `youdao-tinglibao-e6/framework/examples/radio/assets/radio.db`（蜻蜓 FM / Radio Browser 等公开流）。重新导出：

```bash
RADIO_DB=/path/to/radio.db python3 tools/export_stations.py
# 也可直接传路径，或把 radio.db 放到工程 assets/ 目录
python3 tools/export_stations.py /path/to/radio.db
```

脚本会同时更新 `entry/src/main/ets/model/data/StationDataPart{1..4}.ets` 和 `preview/stations.js`，并把已验证支持 TLS 的明文域名优先升级为 `https`。应用图标可用 `python3 tools/gen_icons.py` 重新生成。

HTML 预览直接用浏览器打开 `preview/index.html`（`?pane=1` 打开竖屏播放页，`?settings=1` 直接展开设置抽屉），点选电台、筛选、收藏、设置与频谱动画均可交互。浏览器的音频播放受协议／跨域限制，**能否出声以鸿蒙真机为准**。

## 已知限制

- 当前 `bundleName` 为 `com.example.helloworld`，是复用本机调试证书时的临时包名（调试 profile 绑定包名）。正式发布前需改为自有包名并在 DevEco 重新自动签名。
- **后台播放**：已接入播控中心（`AVSession`）并申请 `AUDIO_PLAYBACK` 长时任务，按 Home 键或锁屏后声音会继续，锁屏／控制中心有播控卡片。几点边界：
  - 卡片封面用应用自己的图标（`app_icon.png` 512×512）；电台数据里没有图片字段，所以不按台区分。
  - 直播流没有时长，`AVPlaybackState` 不填 `position` / `duration`，系统按「直播」显示而不是进度条。
  - 字幕浮层长在页面里，退到后台后不再显示（不影响出声）。
  - 从最近任务里划掉应用仍会结束播放（与系统媒体应用一致）。
- 睡眠定时由播放服务计时，退到后台后依然会按时停止。
- **接 AVSession 踩到的两个坑**（都在真机 API 24 上验证过，已写进 `RadioService.ets` 注释）：
  1. 队列项的 `description` 里**不能带 `mediaImage`**。一张 512×512 的 PixelMap 约 1MB，乘上条目数直接超出 Parcel 上限，系统一律回 `SetAVQueueItems failed : item number is out of range`。封面只能放在顶层 `AVMetadata` 上。
  2. **`AVQueueItem.itemId` 必须是队列内序号 `[1, N]`**，不能直接用业务 id。系统按序号定位条目，所以这里重新编号，再用一张 `itemId → 电台` 的映射表把 `skipToQueueItem` 回调还原回来。
  - `setMediaCenterControlType`（显式声明控制中心要显示哪些按钮）是 API 26 才有的接口，本工程 `compatibleSdkVersion` 为 24 用不了，因此改用「给系统一份队列」这条兼容路径 —— 卡片上的上一台／下一台就是靠它出现的。
- **字幕开→关后频谱定格**（已修复，真机 API 24 上复现并验证）：
  - 现象：点「字幕」开启、再关闭，频谱动画立刻停住并永远停在最后一帧；音频照常播放，页面上其它交互也照常响应。
  - 定位过程：页面的 70ms `setInterval` 在**系统动态组件（`AICaptionComponent`）被销毁**的那一刻被单独取消 —— 独立的 1 秒心跳定时器仍在走、`aboutToDisappear` 没有被调用（说明页面没被销毁），回调里也没有任何异常抛出。换句话说不是「画错了」，是「压根不再画了」。
  - 修法（`entry/src/main/ets/pages/Index.ets`）：
    1. 动画循环改成「每帧自己排下一帧」的 `setTimeout` 链，不再用 `setInterval`；
    2. 回调内部自己 `try/catch` —— 定时器回调里抛异常同样会让 ArkUI 取消这个定时器；
    3. 加 1 秒心跳看门狗：超过 1.5 秒没有成功画出一帧就判定循环被掐掉，重新拉起来（双重保险）。
  - 顺带修掉原生分析器的两个死等（`entry/src/main/cpp/spectrum_analyzer.cpp`）：
    1. `PaceLoop` 原本只在 token 变化时退出，而会话因报错／断流结束时 token 并不变，worker 线程会卡死在 `pacer_.join()` 上，整条分析链路从此死掉、之后任何重连都排不上队；现在会话结束会显式收掉 pacer。
    2. 起流阶段「一个 PCM 都没收到」原本没有超时，流起不来时状态会永远停在 `STARTING`；现在 15 秒拿不到数据即判失败。
  - ArkTS 侧再加一层自愈（`pollAnalysis`）：不看状态码，只盯频段数据版本号有没有继续涨 —— 不涨就重连分析流，连续重连仍无数据才回退模拟模式，保证画面永远不至于定格。
  - 顺带理顺后台行为：`onPageHide` 断开第二条分析流后不再被后台的定时器悄悄拉回来（`pageVisible` 标记），回到前台由 `onPageShow` 统一重连；锁屏卡片切台也不会在后台偷偷开新流。
  - 验证方式：真机上按「开字幕 → 关字幕 → 连续采样 5 次频谱画布的像素差」，修复前恒为 0（完全静止），修复后 5/5 都在动；重复开关、切台、Home 退后台再回前台同样 5/5 在动。
- **音量归一化**（新增，默认开启）：
  - 它和「真实频谱」是**绑定的**：要测节目电平必须有 PCM，而 PCM 只存在于真实音频解析那条额外拉流里，所以开启归一化就等于开启真实解析，频谱来源会被锁定为「真实」（「模拟」按钮置灰）。代价是**每个电台会多拉一条网络连接**、多耗一份流量与电量 —— 这是自动测量必然付的代价，关掉归一化即可退回纯模拟频谱。
  - 目标电平取 −17 dBFS（RMS），取该台响度的 75 分位而不是平均值：静音段和节目间隙不会把结果拉低，鼓点瞬态也不会把结果拉高。
  - 修正量夹在 ±9 dB 内、粒度 0.5 dB：超出这个范围多半是测量本身出了问题，宁可不动。
  - 最终送给系统的响度增益是「听感预设 + 用户微调 + 归一化修正」三者之和。系统 `setLoudnessGain` 的合法区间是 [−90, 24] dB，这里上界取满 24；若三者相加仍越界，按 **归一化修正 > 用户微调 > 听感预设** 的优先级削减 —— 自动校准出来的归一化值永远不会被手动微调挤掉（早期版本夹在 12 dB，用户手动 +9 dB 时归一化修正会被整段削掉，实测修正后系统收到 15.5 dB = 2 + 9 + 4.5）。
  - 测量需要约 7 秒有效样本，因此**切台后的前几秒仍按原始响度播放**，随后修正值立刻生效；每台的修正值会持久化，下次听同一台直接套用。
  - `setLoudnessGain` 是 API 21+ 的系统接口，个别机型／音频链路并不实现。检测到不可用时会自动降级为**音量缩放**兜底（`RadioPlayer.markLoudnessUnavailable`），日志里能看到 `fall back to volume scaling`；此时补响度会被夹在 1.0 以内以免削顶。
  - 真实解析彻底失败（起流超时／连续自愈失败）时，频谱退回模拟动画，**归一化会一并关闭**并在设置面板说明原因 —— 没有 PCM 就没有归一化，不能让开关显示着「已开启」却什么都不做。
- **最近播放**：
  - 只记录真正开播的电台（锁屏卡片切台同样计入），最多保留 50 条，可一键清空。
  - 列表按收听时间倒序，右侧显示相对时间（刚刚／N 分钟前／N 小时前／昨天／M 月 D 日）。
  - 「最近播放」是一个独立的列表范围，切台队列（上一台／下一台）也随之变成时间序。
  - 枚举里插入新范围会让旧编号错位，因此加了 `scopeV2` 迁移：老版本存下的「收藏／国内／国际」会正确映射到新编号，不会变成「最近播放」。
- 电台流地址来自第三方公开数据，可能失效或变更，本项目不保证其可用性；部分流为 HTTP 明文，已在 `network_config.json` 放行。
- 电台数据及流地址的版权归原作者与各电台所有，公开使用前请自行确认使用许可。
- **字幕只显示、不保存**：`AICaptionComponent` 不向应用回传识别文本（`AICaptionOptions` 只有 `onPrepared` / `onError`）。实测第三方应用无法内录本应用音频（`SOURCE_TYPE_PLAYBACK_CAPTURE` 返回 `6800301`，`CAPTURE_VOICE_DOWNLINK_AUDIO` 为 `system_basic` 权限），麦克风只能采集外放环境音，`READ_PASTEBOARD` 同样是系统级权限，因此未实现字幕落盘。若要全自动保存，需改为自解码播放链路（PCM → `speechRecognizer.writeAudio`）或对字幕区域做端侧 OCR。
- 打开设置面板时，系统字幕浮层会遮挡面板下半部，操作上半部的音效／渐变项不受影响。
- **音效依赖系统能力**：ArkTS 层没有开放播放均衡器／AudioSuite（后者只有 native C API，且需要自解码拿到 PCM），`audioEffectMode` 只有 `EFFECT_NONE` / `EFFECT_DEFAULT` 两档。因此预设的听感差异来自 `usage` 对应的系统音效链路、`setLoudnessGain`（API 21+，老设备静默忽略）、音量曲线与渐入时长，是「调音」而非逐频段 EQ；不同机型外放上的实际差别会有不同。想拉开更明显的差距可用「响度」微调滑杆（−12 ~ +12 dB）；正增益拉得过高可能削波失真，收听大动态节目时建议配合削峰余量较大的「夜间／轻语」档。只有系统音效场景（usage）变化时才需要平滑重连当前流，其余参数即时生效。

## 许可证

本项目**原创代码**采用 [MIT License](LICENSE)。`radio.db` 派生的电台数据、第三方流地址及 `preview/` 中的真机截图不包含在该授权范围内。
