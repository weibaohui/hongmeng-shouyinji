cmake_minimum_required(VERSION 3.5.0)
project(spectrum)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(spectrum SHARED
    napi_init.cpp
    spectrum_analyzer.cpp)

target_link_libraries(spectrum PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_core.so
    libnative_media_codecbase.so
    libnative_media_avsource.so
    libnative_media_avdemuxer.so
    libnative_media_acodec.so)
