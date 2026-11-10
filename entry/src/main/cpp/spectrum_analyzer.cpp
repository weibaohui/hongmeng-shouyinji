#include "spectrum_analyzer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <unistd.h>

#include <hilog/log.h>

#include "multimedia/player_framework/native_avbuffer_info.h"
#include "multimedia/player_framework/native_avcodec_audiocodec.h"
#include "multimedia/player_framework/native_avdemuxer.h"
#include "multimedia/player_framework/native_averrors.h"
#include "multimedia/player_framework/native_avsource.h"

namespace radio {
namespace {

constexpr uint32_t kLogDomain = 0x3200;
constexpr const char *kLogTag = "SpectrumAnalyzer";
/** 解封装时复用的一包缓冲，足够容纳任何一帧音频。 */
constexpr int32_t kPacketCapacity = 256 * 1024;
/** 连续多久没有新 PCM 就判定流失效（毫秒）。 */
constexpr int64_t kStallTimeoutMs = 12000;
/** 起流阶段多久一个 PCM 都没收到就判定这条流废了（毫秒）。 */
constexpr int64_t kFirstPcmTimeoutMs = 15000;
/** 出帧节拍：与 UI 的 70ms 定时器同频。 */
constexpr int64_t kTickMs = 70;
/** 缓冲硬上限的余量（秒）：目标水位之上再留一点，避免裁剪跟不上。 */
constexpr double kBufferSlackSeconds = 1.2;
/** 调试开关：置 true 才会打"每秒吞吐/缓冲水位"这类周期性日志，平时保持安静。 */
constexpr bool kVerboseStats = false;
/** 吞吐统计的日志窗口（毫秒），仅 kVerboseStats 为真时生效。 */
constexpr int64_t kStatWindowMs = 5000;
/** PCM 断供超过这个时长才值得记一条，且同一段故障最多每 10 秒报一次。 */
constexpr int64_t kGapLogMs = 1500;
constexpr int64_t kGapLogIntervalMs = 10000;
/** 缓冲目标的自适应范围（毫秒）。 */
constexpr int kMinTargetMs = 700;
constexpr int kMaxTargetMs = 3000;
/** 断供后要在实测空档之上多留的余量（毫秒）。 */
constexpr int kStarveMarginMs = 400;
/** 连续多少拍没有断供才允许把缓冲收窄一档（约 21 秒）。 */
constexpr int kTargetRelaxTicks = 300;

#define SPECTRUM_LOGI(fmt, ...) \
  OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag, fmt, ##__VA_ARGS__)
#define SPECTRUM_LOGW(fmt, ...) \
  OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag, fmt, ##__VA_ARGS__)

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch()).count();
}

/** 原地基 2 FFT，长度必须是 2 的幂。 */
void FftInPlace(std::vector<float> &re, std::vector<float> &im) {
  const int n = static_cast<int>(re.size());
  for (int i = 1, j = 0; i < n; ++i) {
    int bit = n >> 1;
    for (; j & bit; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      std::swap(re[i], re[j]);
      std::swap(im[i], im[j]);
    }
  }
  for (int len = 2; len <= n; len <<= 1) {
    const double angle = -2.0 * M_PI / len;
    const float wRe = static_cast<float>(std::cos(angle));
    const float wIm = static_cast<float>(std::sin(angle));
    for (int i = 0; i < n; i += len) {
      float curRe = 1.0f;
      float curIm = 0.0f;
      for (int k = 0; k < len / 2; ++k) {
        const int a = i + k;
        const int b = i + k + len / 2;
        const float tRe = re[b] * curRe - im[b] * curIm;
        const float tIm = re[b] * curIm + im[b] * curRe;
        re[b] = re[a] - tRe;
        im[b] = im[a] - tIm;
        re[a] += tRe;
        im[a] += tIm;
        const float nextRe = curRe * wRe - curIm * wIm;
        curIm = curRe * wIm + curIm * wRe;
        curRe = nextRe;
      }
    }
  }
}

}  // namespace

SpectrumAnalyzer &SpectrumAnalyzer::Get() {
  static SpectrumAnalyzer instance;
  return instance;
}

SpectrumAnalyzer::~SpectrumAnalyzer() {
  {
    std::lock_guard<std::mutex> lock(cmdMu_);
    exiting_ = true;
    hasPending_ = false;
    token_.fetch_add(1);
  }
  cmdCv_.notify_all();
  if (worker_.joinable()) {
    worker_.join();
  }
}

// ============================== 生命周期 ==============================

int SpectrumAnalyzer::Start(const std::string &url) {
  if (url.empty()) {
    SetStatus(STATUS_SOURCE_FAILED, "电台地址为空");
    return STATUS_SOURCE_FAILED;
  }
  {
    std::lock_guard<std::mutex> lock(cmdMu_);
    pendingUrl_ = url;
    hasPending_ = true;
    // 让正在跑的旧会话立刻放弃（它的网络读不会被强杀，但不再等待它才算"已停止"）
    token_.fetch_add(1);
    if (!threadStarted_) {
      threadStarted_ = true;
      worker_ = std::thread(&SpectrumAnalyzer::ThreadMain, this);
    }
  }
  {
    // 先清空上一家电台的频段，UI 立刻回到"等待数据"，不会残留旧波形
    std::lock_guard<std::mutex> lock(stateMu_);
    bands_.clear();
    status_ = STATUS_STARTING;
    message_ = "正在解析音频流…";
  }
  cmdCv_.notify_all();
  return STATUS_STARTING;
}

void SpectrumAnalyzer::Stop() {
  {
    std::lock_guard<std::mutex> lock(cmdMu_);
    hasPending_ = false;
    pendingUrl_.clear();
    token_.fetch_add(1);
  }
  {
    std::lock_guard<std::mutex> lock(stateMu_);
    bands_.clear();
    status_ = STATUS_IDLE;
    message_ = "未启动";
  }
  cmdCv_.notify_all();
  // 注意：这里不 join。解封装可能正阻塞在网络读上，join 会把 ArkTS 线程一起拖住。
}

int SpectrumAnalyzer::Status() {
  std::lock_guard<std::mutex> lock(stateMu_);
  return status_;
}

std::string SpectrumAnalyzer::Message() {
  std::lock_guard<std::mutex> lock(stateMu_);
  return message_;
}

std::vector<double> SpectrumAnalyzer::Bands() {
  std::lock_guard<std::mutex> lock(stateMu_);
  return bands_;
}

double SpectrumAnalyzer::LevelDb() {
  return levelDb_.load();
}

/**
 * 取走上一拍累积的能量，算出这一拍的均方根电平（dBFS）。
 * RMS 比峰值稳得多：音乐里一个鼓点就能把峰值拉满，但说话内容的 RMS 变化平缓，
 * 用它判断「这一台到底有多响」才靠谱。
 */
double SpectrumAnalyzer::TakeLevelDb() {
  double energy = 0.0;
  long long samples = 0;
  {
    std::lock_guard<std::mutex> lock(levelMu_);
    energy = levelEnergy_;
    samples = levelSamples_;
    levelEnergy_ = 0.0;
    levelSamples_ = 0;
  }
  if (samples <= 0) {
    return -120.0;
  }
  const double rms = std::sqrt(energy / static_cast<double>(samples));
  const double db = 20.0 * std::log10(std::max(rms, 1e-7));
  return std::max(-120.0, std::min(0.0, db));
}

long long SpectrumAnalyzer::Sequence() {
  return seq_.load();
}

void SpectrumAnalyzer::SetStatus(int code, const std::string &message) {
  std::lock_guard<std::mutex> lock(stateMu_);
  status_ = code;
  message_ = message;
}

void SpectrumAnalyzer::SetSessionStatus(int token, int code, const std::string &message) {
  if (token_.load() != token) {
    return;
  }
  SetStatus(code, message);
}

void SpectrumAnalyzer::Publish(const std::vector<double> &bands, int token) {
  if (token_.load() != token) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(stateMu_);
    bands_ = bands;
    if (status_ != STATUS_RUNNING) {
      status_ = STATUS_RUNNING;
      message_ = "实时解析中";
    }
  }
  seq_.fetch_add(1);
}

void SpectrumAnalyzer::ThreadMain() {
  for (;;) {
    std::string url;
    int myToken = 0;
    {
      std::unique_lock<std::mutex> lock(cmdMu_);
      cmdCv_.wait(lock, [this] { return exiting_ || hasPending_; });
      if (exiting_) {
        break;
      }
      url = pendingUrl_;
      hasPending_ = false;
      myToken = token_.load();
    }
    RunSession(url, myToken);
  }
  SPECTRUM_LOGI("worker thread exit");
}

// ============================== 解码器回调 ==============================

void SpectrumAnalyzer::OnNeedInputCb(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer,
                                     void *userData) {
  (void)codec;
  SpectrumAnalyzer *self = static_cast<SpectrumAnalyzer *>(userData);
  if (self == nullptr) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(self->inMu_);
    self->inQueue_.push_back(std::make_pair(index, buffer));
  }
  self->inCv_.notify_one();
}

void SpectrumAnalyzer::OnNewOutputCb(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer,
                                     void *userData) {
  SpectrumAnalyzer *self = static_cast<SpectrumAnalyzer *>(userData);
  if (self != nullptr && buffer != nullptr && self->sessionActive_.load()) {
    self->HandleOutput(buffer);
  }
  OH_AudioCodec_FreeOutputBuffer(codec, index);
}

void SpectrumAnalyzer::OnErrorCb(OH_AVCodec *codec, int32_t errorCode, void *userData) {
  (void)codec;
  SpectrumAnalyzer *self = static_cast<SpectrumAnalyzer *>(userData);
  if (self != nullptr && self->sessionActive_.load()) {
    SPECTRUM_LOGW("codec error %{public}d", errorCode);
    self->SetStatus(STATUS_CODEC_FAILED, "解码出错");
  }
}

void SpectrumAnalyzer::OnStreamChangedCb(OH_AVCodec *codec, OH_AVFormat *format, void *userData) {
  (void)codec;
  (void)format;
  SpectrumAnalyzer *self = static_cast<SpectrumAnalyzer *>(userData);
  if (self != nullptr) {
    // 码流参数变化时允许重新读取一次输出格式
    self->formatKnown_.store(false);
  }
}

/** 输出缓冲区：按需读取采样格式，把 PCM 混成单声道后累积。 */
void SpectrumAnalyzer::HandleOutput(OH_AVBuffer *buffer) {
  OH_AVCodecBufferAttr attr;
  if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK || attr.size <= 0) {
    return;
  }
  if (!formatKnown_.load() && codecRef_ != nullptr) {
    OH_AVFormat *outFormat = OH_AudioCodec_GetOutputDescription(codecRef_);
    if (outFormat != nullptr) {
      int32_t outRate = sampleRate_.load();
      int32_t outChannels = channels_.load();
      int32_t sampleFormat = 1;  // SAMPLE_S16LE
      OH_AVFormat_GetIntValue(outFormat, OH_MD_KEY_AUD_SAMPLE_RATE, &outRate);
      OH_AVFormat_GetIntValue(outFormat, OH_MD_KEY_AUD_CHANNEL_COUNT, &outChannels);
      OH_AVFormat_GetIntValue(outFormat, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &sampleFormat);
      OH_AVFormat_Destroy(outFormat);
      sampleRate_.store(outRate > 0 ? outRate : sampleRate_.load());
      channels_.store(outChannels > 0 ? outChannels : channels_.load());
      const bool isFloat = sampleFormat == 4;
      floatPcm_.store(isFloat);
      bytesPerSample_.store(isFloat ? 4 : 2);
      formatKnown_.store(true);
      SPECTRUM_LOGI("pcm out sr=%{public}d ch=%{public}d float=%{public}d",
                    sampleRate_.load(), channels_.load(), isFloat ? 1 : 0);
    }
  }
  uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
  if (addr == nullptr) {
    return;
  }
  const int perSample = bytesPerSample_.load();
  const int sampleCount = attr.size / perSample;
  const int ch = channels_.load();
  if (floatPcm_.load()) {
    AppendPcmFloat(reinterpret_cast<const float *>(addr), sampleCount, ch);
  } else {
    AppendPcm(reinterpret_cast<const int16_t *>(addr), sampleCount, ch);
  }
  const int64_t now = NowMs();
  const int64_t previous = lastDataMs_.exchange(now);
  if (previous > 0 && now - previous > kGapLogMs) {
    // 网络抖动很正常，只在长时间持续、且距上次记录超过 10 秒时记一条，
    // 避免一次卡顿刷满日志（累计条数一并给出，便于判断严重程度）。
    gapCount_.fetch_add(1);
    const int64_t lastLog = lastGapLogMs_.load();
    if (lastLog == 0 || now - lastLog >= kGapLogIntervalMs) {
      SPECTRUM_LOGW("pcm gap %{public}lld ms (x%{public}d) · target %{public}.2fs",
                    static_cast<long long>(now - previous), gapCount_.exchange(0),
                    TargetSeconds());
      lastGapLogMs_.store(now);
    }
  }

  // 详细吞吐统计默认关闭，只有排查问题时把 kVerboseStats 打开才会输出
  if (kVerboseStats) {
    statFrames_.fetch_add(sampleCount / std::max(1, ch));
    const int64_t windowStart = statWindowMs_.load();
    if (windowStart != 0 && now - windowStart >= kStatWindowMs) {
      double level = 0.0;
      {
        std::lock_guard<std::mutex> lock(pcmMu_);
        level = static_cast<double>(mono_.size()) / std::max(8000, sampleRate_.load());
      }
      SPECTRUM_LOGI("in %{public}d frame/s · buffer %{public}.2fs · target %{public}.2fs",
                    static_cast<int>(statFrames_.load() / (kStatWindowMs / 1000)),
                    level, TargetSeconds());
      statWindowMs_.store(now);
      statFrames_.store(0);
    } else if (windowStart == 0) {
      statWindowMs_.store(now);
    }
  }
}

void SpectrumAnalyzer::TrimBufferLocked() {
  const int rate = std::max(8000, sampleRate_.load());
  const size_t limit = static_cast<size_t>(rate * (TargetSeconds() + kBufferSlackSeconds));
  if (mono_.size() > limit) {
    mono_.erase(mono_.begin(), mono_.begin() + static_cast<long>(mono_.size() - limit));
  }
}

bool SpectrumAnalyzer::PcmBufferFull() {
  const int rate = std::max(8000, sampleRate_.load());
  const size_t limit = static_cast<size_t>(rate * (TargetSeconds() + kBufferSlackSeconds));
  std::lock_guard<std::mutex> lock(pcmMu_);
  return mono_.size() > limit;
}

double SpectrumAnalyzer::TargetSeconds() const {
  const int ms = std::max(kMinTargetMs, std::min(kMaxTargetMs, targetMs_.load()));
  return ms / 1000.0;
}

/**
 * 网络流是突发投递的（一次来好几秒），如果来一批就算一次，波形会一顿一顿。
 * 这里按壁钟匀速消费：每 70ms 取一窗、前进约 70ms 的样本量。
 *
 * 只按"实时速率"消费的话，缓冲一旦被网络抖动抽干，画面就会定住几秒；
 * 所以按水位微调：缓冲充足时稍微加速贴住实时，缓冲见底时放慢，尽量不断供。
 */
void SpectrumAnalyzer::PaceLoop(int token) {
  std::vector<int16_t> window(FFT_SIZE, 0);
  int64_t nextTick = NowMs();
  int healthyTicks = 0;
  int starveStreak = 0;
  bool everAnalyzed = false;
  int outFrames = 0;
  int64_t statAt = NowMs();
  while (token_.load() == token && pacerRun_.load()) {
    nextTick += kTickMs;
    for (;;) {
      const int64_t waitMs = nextTick - NowMs();
      if (waitMs <= 0) {
        break;
      }
      if (token_.load() != token) {
        return;
      }
      usleep(static_cast<useconds_t>(std::min<int64_t>(waitMs, 15) * 1000));
    }
    if (NowMs() - nextTick > 200) {
      // 被调度拖太久（例如切台瞬间）：重新对齐，避免连发补帧让画面跳一下
      nextTick = NowMs();
    }

    bool analyzed = false;
    {
      std::lock_guard<std::mutex> lock(pcmMu_);
      const int rate = std::max(8000, sampleRate_.load());
      const double level = static_cast<double>(mono_.size()) / rate;
      const double target = TargetSeconds();
      double factor = 1.0;
      if (level > target) {
        factor = 1.12;
      } else if (level < target) {
        factor = std::max(0.55, 0.55 + 0.45 * (level / target));
      }
      int hop = static_cast<int>(rate * (kTickMs / 1000.0) * factor);
      hop = std::max(256, std::min(hop, FFT_SIZE));
      const int available = static_cast<int>(mono_.size());
      if (available >= FFT_SIZE) {
        std::copy(mono_.begin(), mono_.begin() + FFT_SIZE, window.begin());
        analyzed = true;
        if (available >= hop + FFT_SIZE) {
          mono_.erase(mono_.begin(), mono_.begin() + hop);
        } else {
          mono_.erase(mono_.begin(), mono_.begin() + (available - FFT_SIZE));
        }
      }
    }
    if (analyzed) {
      AnalyzeSamples(window.data(), token);
      ++outFrames;
      // 刚经历一次断供：按这次实际断供时长把缓冲垫到够用，下次就不会再定格。
      // 首帧之前本来就还没数据，那段等待不算断供，否则一开播就把缓冲顶到 3 秒。
      if (starveStreak > 0 && everAnalyzed) {
        const int needMs = static_cast<int>(starveStreak * kTickMs) + kStarveMarginMs;
        const int before = targetMs_.load();
        if (needMs > before) {
          targetMs_.store(std::min(kMaxTargetMs, needMs));
          // 只在"画面真的断过"且确实调整了缓冲时记一条，平时不刷屏
          if (starveStreak * kTickMs >= 300) {
            SPECTRUM_LOGI("underrun %{public}d ms · target %{public}.2fs → %{public}.2fs",
                          static_cast<int>(starveStreak * kTickMs), before / 1000.0,
                          targetMs_.load() / 1000.0);
          }
        }
      }
      starveStreak = 0;
      everAnalyzed = true;
      // 长时间平稳才慢慢把缓冲收窄，减少画面滞后
      if (++healthyTicks >= kTargetRelaxTicks) {
        healthyTicks = 0;
        const int cur = targetMs_.load();
        if (cur > kMinTargetMs) {
          targetMs_.store(std::max(kMinTargetMs, cur - 100));
        }
      }
    } else {
      healthyTicks = 0;
      starveStreak++;
    }
    if (kVerboseStats && NowMs() - statAt >= kStatWindowMs) {
      SPECTRUM_LOGI("out %{public}d frame/s · target %{public}.2fs · stalled %{public}d tick(s)",
                    static_cast<int>(outFrames / (kStatWindowMs / 1000)), TargetSeconds(),
                    starveStreak);
      outFrames = 0;
      statAt = NowMs();
    }
  }
}

void SpectrumAnalyzer::AppendPcm(const int16_t *data, int sampleCount, int channels) {
  if (channels <= 0) {
    return;
  }
  double energy = 0.0;
  long long frames = 0;
  {
    std::lock_guard<std::mutex> lock(pcmMu_);
    const int count = sampleCount / channels;
    for (int i = 0; i < count; ++i) {
      int sum = 0;
      for (int c = 0; c < channels; ++c) {
        sum += data[i * channels + c];
      }
      const int16_t mono = static_cast<int16_t>(sum / channels);
      mono_.push_back(mono);
      // 顺带累计能量供音量归一化使用：这里用的是混完单声道后的样本，和频段口径一致。
      const double v = static_cast<double>(mono) / 32768.0;
      energy += v * v;
    }
    frames = count;
    TrimBufferLocked();
  }
  {
    std::lock_guard<std::mutex> lock(levelMu_);
    levelEnergy_ += energy;
    levelSamples_ += frames;
  }
}

void SpectrumAnalyzer::AppendPcmFloat(const float *data, int sampleCount, int channels) {
  if (channels <= 0) {
    return;
  }
  double energy = 0.0;
  long long frames = 0;
  {
    std::lock_guard<std::mutex> lock(pcmMu_);
    const int count = sampleCount / channels;
    for (int i = 0; i < count; ++i) {
      float sum = 0.0f;
      for (int c = 0; c < channels; ++c) {
        sum += data[i * channels + c];
      }
      const float value = sum / static_cast<float>(channels);
      const float clamped = std::max(-1.0f, std::min(1.0f, value));
      mono_.push_back(static_cast<int16_t>(clamped * 32767.0f));
      const double v = static_cast<double>(clamped);
      energy += v * v;
    }
    frames = count;
    TrimBufferLocked();
  }
  {
    std::lock_guard<std::mutex> lock(levelMu_);
    levelEnergy_ += energy;
    levelSamples_ += frames;
  }
}

/** 对当前缓冲的前 FFT_SIZE 个采样做 Hann 窗 + FFT，压成 16 个对数频段。 */
void SpectrumAnalyzer::AnalyzeSamples(const int16_t *data, int token) {
  std::vector<float> re(FFT_SIZE);
  std::vector<float> im(FFT_SIZE, 0.0f);
  for (int i = 0; i < FFT_SIZE; ++i) {
    const float window = 0.5f - 0.5f * std::cos(2.0f * static_cast<float>(M_PI) * i / (FFT_SIZE - 1));
    re[i] = (static_cast<float>(data[i]) / 32768.0f) * window;
  }
  FftInPlace(re, im);

  const int maxBin = FFT_SIZE / 2;
  std::vector<double> magnitudes(maxBin);
  const double gain = FFT_SIZE / 4.0;  // Hann 窗相干增益
  for (int k = 0; k < maxBin; ++k) {
    magnitudes[k] = std::sqrt(static_cast<double>(re[k]) * re[k] +
                              static_cast<double>(im[k]) * im[k]) / gain;
  }

  const double rate = static_cast<double>(sampleRate_.load());
  const double nyquist = std::max(4000.0, rate / 2.0);
  const double lowHz = 50.0;
  const double highHz = std::min(16000.0, nyquist * 0.95);
  std::vector<double> bands(BAND_COUNT, 0.0);
  const double ratio = highHz / lowHz;
  for (int b = 0; b < BAND_COUNT; ++b) {
    const double f0 = lowHz * std::pow(ratio, static_cast<double>(b) / BAND_COUNT);
    const double f1 = lowHz * std::pow(ratio, static_cast<double>(b + 1) / BAND_COUNT);
    int k0 = static_cast<int>(std::floor(f0 / nyquist * maxBin));
    int k1 = static_cast<int>(std::ceil(f1 / nyquist * maxBin));
    k0 = std::max(1, std::min(maxBin - 1, k0));
    k1 = std::max(k0, std::min(maxBin - 1, k1));
    double peak = 0.0;
    for (int k = k0; k <= k1; ++k) {
      peak = std::max(peak, magnitudes[k]);
    }
    // -70dB ~ 0dB 映射到 0~1，再开方提升小信号可见度
    const double db = 20.0 * std::log10(peak + 1e-9);
    double norm = (db + 70.0) / 70.0;
    norm = std::max(0.0, std::min(1.0, norm));
    bands[b] = std::sqrt(norm);
  }
  // 节目电平与频段同一拍算出：音量归一化拿到的就是这个值。
  levelDb_.store(TakeLevelDb());
  Publish(bands, token);
}

void SpectrumAnalyzer::RunSession(const std::string &url, int token) {
  sessionActive_.store(true);
  sessionStartMs_.store(NowMs());
  {
    std::lock_guard<std::mutex> lock(pcmMu_);
    mono_.clear();
  }
  {
    std::lock_guard<std::mutex> lock(levelMu_);
    levelEnergy_ = 0.0;
    levelSamples_ = 0;
  }
  levelDb_.store(-120.0);
  {
    std::lock_guard<std::mutex> lock(inMu_);
    inQueue_.clear();
  }
  formatKnown_.store(false);
  sampleRate_.store(44100);
  channels_.store(2);
  bytesPerSample_.store(2);
  floatPcm_.store(false);
  lastDataMs_.store(0);
  targetMs_.store(900);
  statWindowMs_.store(0);
  statFrames_.store(0);
  lastGapLogMs_.store(0);
  gapCount_.store(0);

  pacerRun_.store(true);
  pacer_ = std::thread(&SpectrumAnalyzer::PaceLoop, this, token);

  OH_AVSource *source = OH_AVSource_CreateWithURI(const_cast<char *>(url.c_str()));
  if (source == nullptr) {
    SPECTRUM_LOGW("create source failed");
    if (token_.load() == token) {
      SetSessionStatus(token, STATUS_SOURCE_FAILED, "该电台音频流无法解析");
    }
  } else {
    OH_AVDemuxer *demuxer = nullptr;
    OH_AVCodec *codec = nullptr;
    OH_AVBuffer *packet = nullptr;
    uint32_t audioTrack = 0;

    do {
      OH_AVFormat *sourceFormat = OH_AVSource_GetSourceFormat(source);
      int32_t trackCount = 0;
      if (sourceFormat == nullptr ||
          !OH_AVFormat_GetIntValue(sourceFormat, OH_MD_KEY_TRACK_COUNT, &trackCount)) {
        if (sourceFormat != nullptr) {
          OH_AVFormat_Destroy(sourceFormat);
        }
        SetSessionStatus(token, STATUS_NO_AUDIO_TRACK, "音频流信息缺失");
        break;
      }
      OH_AVFormat_Destroy(sourceFormat);

      OH_AVFormat *trackFormat = nullptr;
      for (int32_t i = 0; i < trackCount; ++i) {
        OH_AVFormat *probe = OH_AVSource_GetTrackFormat(source, static_cast<uint32_t>(i));
        if (probe == nullptr) {
          continue;
        }
        int32_t trackType = -1;
        const bool ok = OH_AVFormat_GetIntValue(probe, OH_MD_KEY_TRACK_TYPE, &trackType);
        if (ok && trackType == MEDIA_TYPE_AUD) {
          audioTrack = static_cast<uint32_t>(i);
          trackFormat = probe;
          break;
        }
        OH_AVFormat_Destroy(probe);
      }
      if (trackFormat == nullptr) {
        SetSessionStatus(token, STATUS_NO_AUDIO_TRACK, "未找到音频轨");
        break;
      }

      char *mime = nullptr;
      int32_t sampleRate = 44100;
      int32_t channelCount = 2;
      OH_AVFormat_GetStringValue(trackFormat, OH_MD_KEY_CODEC_MIME,
                                 const_cast<const char **>(&mime));
      OH_AVFormat_GetIntValue(trackFormat, OH_MD_KEY_AUD_SAMPLE_RATE, &sampleRate);
      OH_AVFormat_GetIntValue(trackFormat, OH_MD_KEY_AUD_CHANNEL_COUNT, &channelCount);
      sampleRate_.store(sampleRate > 0 ? sampleRate : 44100);
      channels_.store(channelCount > 0 ? channelCount : 2);
      if (mime == nullptr) {
        OH_AVFormat_Destroy(trackFormat);
        SetSessionStatus(token, STATUS_NO_AUDIO_TRACK, "音频编码未知");
        break;
      }
      SPECTRUM_LOGI("track=%{public}u mime=%{public}s sr=%{public}d ch=%{public}d",
                    audioTrack, mime, sampleRate_.load(), channels_.load());

      codec = OH_AudioCodec_CreateByMime(mime, false);
      if (codec == nullptr) {
        OH_AVFormat_Destroy(trackFormat);
        SetSessionStatus(token, STATUS_CODEC_FAILED, "该编码格式暂不支持解析");
        break;
      }
      codecRef_ = codec;

      OH_AVCodecCallback callback;
      callback.onError = OnErrorCb;
      callback.onStreamChanged = OnStreamChangedCb;
      callback.onNeedInputBuffer = OnNeedInputCb;
      callback.onNewOutputBuffer = OnNewOutputCb;
      OH_AudioCodec_RegisterCallback(codec, callback, this);

      OH_AVFormat *format = OH_AVFormat_CreateAudioFormat(mime, sampleRate_.load(), channels_.load());
      if (format == nullptr) {
        OH_AVFormat_Destroy(trackFormat);
        SetSessionStatus(token, STATUS_CODEC_FAILED, "解码参数构建失败");
        break;
      }
      const int32_t s16 = 1;  // OH_BitsPerSample::SAMPLE_S16LE
      OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, s16);
      uint8_t *csd = nullptr;
      size_t csdSize = 0;
      if (OH_AVFormat_GetBuffer(trackFormat, OH_MD_KEY_CODEC_CONFIG, &csd, &csdSize) &&
          csd != nullptr && csdSize > 0) {
        OH_AVFormat_SetBuffer(format, OH_MD_KEY_CODEC_CONFIG, csd, csdSize);
      }
      OH_AVFormat_Destroy(trackFormat);

      const OH_AVErrCode cfgRet = OH_AudioCodec_Configure(codec, format);
      OH_AVFormat_Destroy(format);
      if (cfgRet != AV_ERR_OK) {
        SPECTRUM_LOGW("configure failed %{public}d", cfgRet);
        SetSessionStatus(token, STATUS_CODEC_FAILED, "解码器配置失败");
        break;
      }
      const OH_AVErrCode prepRet = OH_AudioCodec_Prepare(codec);
      const OH_AVErrCode startRet = prepRet == AV_ERR_OK ? OH_AudioCodec_Start(codec) : prepRet;
      if (prepRet != AV_ERR_OK || startRet != AV_ERR_OK) {
        SPECTRUM_LOGW("start failed prep=%{public}d start=%{public}d", prepRet, startRet);
        SetSessionStatus(token, STATUS_CODEC_FAILED, "解码器启动失败");
        break;
      }

      demuxer = OH_AVDemuxer_CreateWithSource(source);
      if (demuxer == nullptr ||
          OH_AVDemuxer_SelectTrackByID(demuxer, audioTrack) != AV_ERR_OK) {
        SetSessionStatus(token, STATUS_SOURCE_FAILED, "音频轨选择失败");
        break;
      }
      packet = OH_AVBuffer_Create(kPacketCapacity);
      if (packet == nullptr) {
        SetSessionStatus(token, STATUS_SOURCE_FAILED, "缓冲区分配失败");
        break;
      }

      SetSessionStatus(token, STATUS_STARTING, "正在等待音频数据…");
      SPECTRUM_LOGI("decode loop begin");
      while (token_.load() == token) {
        // 防洪水：个别源站会把整段缓冲瞬间推过来（实测有几十倍实时速度的空转），
        // 缓冲满了就先不喂解码器，等 pacer 消费下去再说。
        const bool full = PcmBufferFull();
        if (full) {
          // 还是满的：本轮跳过喂数据，但下面照常做状态与断流检查
          usleep(20000);
        }
        std::pair<uint32_t, OH_AVBuffer *> slot;
        bool hasSlot = false;
        if (!full) {
          std::unique_lock<std::mutex> lock(inMu_);
          if (inQueue_.empty()) {
            inCv_.wait_for(lock, std::chrono::milliseconds(40));
          }
          if (!inQueue_.empty()) {
            slot = inQueue_.front();
            inQueue_.pop_front();
            hasSlot = true;
          }
        }
        if (hasSlot && slot.second != nullptr) {
          const OH_AVErrCode readRet = OH_AVDemuxer_ReadSampleBuffer(demuxer, audioTrack, packet);
          if (readRet == AV_ERR_OK) {
            OH_AVCodecBufferAttr inAttr;
            if (OH_AVBuffer_GetBufferAttr(packet, &inAttr) == AV_ERR_OK && inAttr.size > 0) {
              uint8_t *dst = OH_AVBuffer_GetAddr(slot.second);
              const int32_t capacity = OH_AVBuffer_GetCapacity(slot.second);
              const int32_t copySize = std::min(inAttr.size, capacity);
              if (dst != nullptr && copySize > 0) {
                std::memcpy(dst, OH_AVBuffer_GetAddr(packet), copySize);
                OH_AVCodecBufferAttr attr = inAttr;
                attr.size = copySize;
                attr.offset = 0;
                OH_AVBuffer_SetBufferAttr(slot.second, &attr);
              }
            }
            OH_AudioCodec_PushInputBuffer(codec, slot.first);
          } else {
            // 暂时读不到数据：把槽还回队列，稍后重试
            {
              std::lock_guard<std::mutex> lock(inMu_);
              inQueue_.push_front(slot);
            }
            usleep(5000);
          }
        }

        if (Status() < 0) {
          break;
        }
        // 一次 PCM 都没收到的死等：起流阶段可能卡在握手 / 等首帧上。
        // 没有这条兜底，状态会永远停在 STARTING，界面上频谱就再也不会动。
        if (lastDataMs_.load() == 0 && NowMs() - sessionStartMs_.load() > kFirstPcmTimeoutMs) {
          SPECTRUM_LOGW("no pcm at all for %{public}lld ms", static_cast<long long>(kFirstPcmTimeoutMs));
          SetSessionStatus(token, STATUS_ENDED, "音频流始终没有数据");
          break;
        }
        if (lastDataMs_.load() > 0 && NowMs() - lastDataMs_.load() > kStallTimeoutMs) {
          SPECTRUM_LOGI("stalled: no pcm for %{public}lld ms",
                        static_cast<long long>(kStallTimeoutMs));
          SetSessionStatus(token, STATUS_ENDED, "音频流已断开");
          break;
        }
      }
    } while (false);

    // 收尾顺序很重要：先让回调失效，再释放 codec，最后放掉网络源（这一步可能阻塞）
    sessionActive_.store(false);
    codecRef_ = nullptr;
    if (packet != nullptr) {
      OH_AVBuffer_Destroy(packet);
    }
    if (demuxer != nullptr) {
      OH_AVDemuxer_Destroy(demuxer);
    }
    if (codec != nullptr) {
      OH_AudioCodec_Stop(codec);
      OH_AudioCodec_Destroy(codec);
    }
    OH_AVSource_Destroy(source);
  }

  sessionActive_.store(false);
  // 必须先让 pacer 自己退出再 join：pacer 的退出条件是 token 变化或本会话结束，
  // 报错 / 断流结束的会话 token 并没有变，不显式收它就会在 join 上死等。
  pacerRun_.store(false);
  if (pacer_.joinable()) {
    pacer_.join();
  }
  {
    std::lock_guard<std::mutex> lock(inMu_);
    inQueue_.clear();
  }
  {
    std::lock_guard<std::mutex> lock(pcmMu_);
    mono_.clear();
  }
  SPECTRUM_LOGI("session end status=%{public}d", Status());
}

}  // namespace radio
