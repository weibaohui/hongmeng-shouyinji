/*
 * 电台音频频谱分析：从网络电台流里解出 PCM，再做 FFT 得到频段能量。
 * 不依赖麦克风、不依赖系统播放捕获，直接二次拉流 + 系统解码器。
 *
 * 线程模型：
 * - 常驻一条 worker 线程，按 token 领取「会话」；Start/Stop 只改状态并唤醒它，
 *   绝不在调用线程 join —— 网络拉流的解封装会阻塞在网络读上，一旦在 ArkTS
 *   UI 线程 join，切台就会整界面卡住。
 * - 每个会话再起一条 pacer 线程匀速吐频谱帧，会话结束时由 worker 线程回收。
 */
#ifndef RADIO_SPECTRUM_ANALYZER_H
#define RADIO_SPECTRUM_ANALYZER_H

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "multimedia/player_framework/native_avbuffer.h"
#include "multimedia/player_framework/native_avcodec_base.h"
#include "multimedia/player_framework/native_avformat.h"

namespace radio {

/** 与 ArkTS 侧 SpectrumPainter 的 BAR_COUNT 保持一致。 */
constexpr int BAND_COUNT = 16;
constexpr int FFT_SIZE = 1024;

/** 状态码：正数为运行态，负数为失败原因，供 UI 决定是否回退模拟模式。 */
enum StatusCode : int {
  STATUS_IDLE = 0,
  STATUS_STARTING = 1,
  STATUS_RUNNING = 2,
  STATUS_NO_AUDIO_TRACK = -1,
  STATUS_SOURCE_FAILED = -2,
  STATUS_CODEC_FAILED = -3,
  STATUS_ENDED = -4
};

class SpectrumAnalyzer {
 public:
  static SpectrumAnalyzer &Get();

  /** 启动分析：立即返回，真正的解封装在常驻线程里完成。 */
  int Start(const std::string &url);
  /** 停止分析：立即返回，旧会话在后台自行收尾（不等网络读返回）。 */
  void Stop();
  int Status();
  std::string Message();
  /** 最近一次计算出的 16 个频段能量（0~1）；尚未有数据时返回空数组。 */
  std::vector<double> Bands();
  /** 每产出一帧新频谱就自增，UI 用它判断数据是否还在更新。 */
  long long Sequence();

 private:
  SpectrumAnalyzer() = default;
  ~SpectrumAnalyzer();
  SpectrumAnalyzer(const SpectrumAnalyzer &) = delete;
  SpectrumAnalyzer &operator=(const SpectrumAnalyzer &) = delete;

  /** 常驻线程：等 token 领取会话，会话结束后继续等下一条。 */
  void ThreadMain();
  /** 一个电台的完整生命周期：拉流 -> 解封装 -> 解码 -> 匀速出帧。 */
  void RunSession(const std::string &url, int token);
  void SetStatus(int code, const std::string &message);
  /** 只有当前会话才能改状态，避免已被替换的旧会话把 UI 状态改乱。 */
  void SetSessionStatus(int token, int code, const std::string &message);
  void Publish(const std::vector<double> &bands, int token);
  /** 把交错 PCM 混成单声道并追加到分析缓冲。 */
  void AppendPcm(const int16_t *data, int sampleCount, int channels);
  void AppendPcmFloat(const float *data, int sampleCount, int channels);
  /** 匀速消费缓冲：每 70ms 取一窗做 FFT，并按缓冲水位微调消费速度。 */
  void PaceLoop(int token);
  void AnalyzeSamples(const int16_t *data, int token);
  /** 缓冲上限按秒裁剪，避免无限堆积与过度滞后。 */
  void TrimBufferLocked();
  /** 按实测到达间隔推算的缓冲目标水位（秒）：网络越抖垫得越深，尽量不断供。 */
  double TargetSeconds() const;
  /** PCM 缓冲是否已到上限：到了就让解码线程歇一下，避免几十倍实时速度空转。 */
  bool PcmBufferFull();  /** 解码器输出回调里调用：按需读取输出格式并累积 PCM。 */
  void HandleOutput(OH_AVBuffer *buffer);

  static void OnErrorCb(OH_AVCodec *codec, int32_t errorCode, void *userData);
  static void OnStreamChangedCb(OH_AVCodec *codec, OH_AVFormat *format, void *userData);
  static void OnNeedInputCb(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);
  static void OnNewOutputCb(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);

  /** 常驻线程与命令通道。 */
  std::thread worker_;
  std::mutex cmdMu_;
  std::condition_variable cmdCv_;
  std::string pendingUrl_;
  bool hasPending_ = false;
  bool exiting_ = false;
  bool threadStarted_ = false;
  /** 每次 Start/Stop 自增；会话发现 token 变了就尽快退出。 */
  std::atomic<int> token_{0};
  std::atomic<long long> seq_{0};

  /** 当前会话是否在运行，供解码回调判断是否需要继续累积数据。 */
  std::atomic<bool> sessionActive_{false};
  /**
   * pacer 线程是否还该活着。
   * pacer 的退出条件不能只看 token：会话因报错 / 断流结束时 token 并没有变，
   * 若只看 token，worker 线程会在 pacer_.join() 上永久阻塞，整条分析链路就此死掉，
   * 之后无论怎么重连都排不上队，频谱会永远停在旧画面上。
   */
  std::atomic<bool> pacerRun_{false};
  /** 会话开始时刻，用来判断「一直没收到 PCM」的死等。 */
  std::atomic<int64_t> sessionStartMs_{0};
  std::thread pacer_;

  std::mutex stateMu_;
  std::vector<double> bands_;
  int status_ = STATUS_IDLE;
  std::string message_ = "未启动";

  std::mutex pcmMu_;
  std::vector<int16_t> mono_;

  std::atomic<int> sampleRate_{44100};
  std::atomic<int> channels_{2};
  std::atomic<int> bytesPerSample_{2};
  std::atomic<bool> floatPcm_{false};
  std::atomic<bool> formatKnown_{false};
  std::atomic<int64_t> lastDataMs_{0};
  /** 断流日志节流：上次记录时间与累计次数，避免一次卡顿刷满日志。 */
  std::atomic<int64_t> lastGapLogMs_{0};
  std::atomic<int> gapCount_{0};
  /**
   * 当前缓冲目标（毫秒）。网络流的音频是"一块一块"突发到达的，块与块之间有空档；
   * 一旦出现断供就自动把缓冲垫深一档，长时间稳定后再缓慢收回。
   */
  std::atomic<int> targetMs_{900};
  /** 每秒统计一次吞吐，便于确认是"网络送得慢"还是"我们消费得慢"。 */
  std::atomic<int64_t> statWindowMs_{0};
  std::atomic<int> statFrames_{0};
  /** 输出回调里需要用 codec 读取输出格式，指向当前解码器实例。 */
  OH_AVCodec *codecRef_ = nullptr;

  std::mutex inMu_;
  std::condition_variable inCv_;
  std::deque<std::pair<uint32_t, OH_AVBuffer *>> inQueue_;
};

}  // namespace radio

#endif  // RADIO_SPECTRUM_ANALYZER_H
