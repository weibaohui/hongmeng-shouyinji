#include <napi/native_api.h>

#include <string>
#include <vector>

#include "spectrum_analyzer.h"

namespace {

std::string ReadStringArg(napi_env env, napi_value value) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length == 0) {
    return std::string();
  }
  std::vector<char> buffer(length + 1, '\0');
  size_t written = 0;
  if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &written) != napi_ok) {
    return std::string();
  }
  return std::string(buffer.data(), written);
}

/** start(url): 返回状态码，解封装与解码在子线程进行。 */
napi_value Start(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  int code = radio::STATUS_SOURCE_FAILED;
  if (argc >= 1) {
    const std::string url = ReadStringArg(env, argv[0]);
    code = radio::SpectrumAnalyzer::Get().Start(url);
  }
  napi_value result = nullptr;
  napi_create_int32(env, code, &result);
  return result;
}

napi_value Stop(napi_env env, napi_callback_info info) {
  (void)env;
  (void)info;
  radio::SpectrumAnalyzer::Get().Stop();
  napi_value result = nullptr;
  napi_get_undefined(env, &result);
  return result;
}

napi_value Status(napi_env env, napi_callback_info info) {
  (void)info;
  const int code = radio::SpectrumAnalyzer::Get().Status();
  napi_value result = nullptr;
  napi_create_int32(env, code, &result);
  return result;
}

napi_value Message(napi_env env, napi_callback_info info) {
  (void)info;
  const std::string text = radio::SpectrumAnalyzer::Get().Message();
  napi_value result = nullptr;
  napi_create_string_utf8(env, text.c_str(), text.size(), &result);
  return result;
}

/** bands(): 返回 16 个频段能量（0~1），还没有数据时是空数组。 */
napi_value Bands(napi_env env, napi_callback_info info) {
  (void)info;
  const std::vector<double> bands = radio::SpectrumAnalyzer::Get().Bands();
  napi_value result = nullptr;
  napi_create_array_with_length(env, bands.size(), &result);
  for (size_t i = 0; i < bands.size(); ++i) {
    napi_value item = nullptr;
    napi_create_double(env, bands[i], &item);
    napi_set_element(env, result, static_cast<uint32_t>(i), item);
  }
  return result;
}

/** seq(): 每产出一帧新频段就自增，UI 用它判断数据是否还在更新。 */
napi_value Sequence(napi_env env, napi_callback_info info) {
  (void)info;
  const long long value = radio::SpectrumAnalyzer::Get().Sequence();
  napi_value result = nullptr;
  napi_create_int64(env, value, &result);
  return result;
}

/**
 * level(): 最近一帧的节目电平（dBFS，-120 ~ 0）。
 * 音量归一化用它判断这一台到底有多响；还没有数据时是 -120。
 */
napi_value Level(napi_env env, napi_callback_info info) {
  (void)env;
  (void)info;
  const double value = radio::SpectrumAnalyzer::Get().LevelDb();
  napi_value result = nullptr;
  napi_create_double(env, value, &result);
  return result;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
    {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"status", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"message", nullptr, Message, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"bands", nullptr, Bands, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"seq", nullptr, Sequence, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"level", nullptr, Level, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

}  // namespace

static napi_module spectrumModule = {
  1,
  0,
  nullptr,
  Init,
  "spectrum",
  nullptr,
  {0},
};

extern "C" __attribute__((constructor)) void RegisterSpectrumModule(void) {
  napi_module_register(&spectrumModule);
}
