cmake_minimum_required(VERSION 3.16)
project(cutlab_core VERSION 0.3.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(CUTLAB_BUILD_TESTS "Build cutlab core unit tests" ON)
option(CUTLAB_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)
option(CUTLAB_WITH_MEDIA "Build the FFmpeg media engine" OFF)
set(CUTLAB_FFMPEG_ROOT "" CACHE PATH "FFmpeg install prefix (include/ and lib/)")
option(CUTLAB_ZERO_INIT_LOCALS "Zero-initialise local variables the code leaves uninitialised (hardening; OFF for valgrind runs)" ON)
option(CUTLAB_FFMPEG_SHARED "FFmpeg is a shared build (Windows DLLs)" OFF)
set(CUTLAB_MINIAUDIO_DIR "" CACHE PATH "Directory containing miniaudio.h (downloaded when empty)")

set(CORE_SOURCES src/time.cpp src/capi.cpp)

if(CUTLAB_WITH_MEDIA)
  if(NOT CUTLAB_FFMPEG_ROOT)
    message(FATAL_ERROR "CUTLAB_WITH_MEDIA needs CUTLAB_FFMPEG_ROOT")
  endif()
  if(NOT CUTLAB_MINIAUDIO_DIR)
    include(FetchContent)
    FetchContent_Declare(miniaudio
      GIT_REPOSITORY https://github.com/mackron/miniaudio.git
      GIT_TAG 0.11.21
      GIT_SHALLOW TRUE)
    FetchContent_GetProperties(miniaudio)
    if(NOT miniaudio_POPULATED)
      FetchContent_Populate(miniaudio)
    endif()
    set(CUTLAB_MINIAUDIO_DIR ${miniaudio_SOURCE_DIR})
  endif()
  list(APPEND CORE_SOURCES
    src/media/demuxer.cpp
    src/media/probe.cpp
    src/media/video_decoder.cpp
    src/media/audio_decoder.cpp
    src/media/player.cpp
    src/media/audio_output.cpp
    src/media/timeline.cpp
    src/media/miniaudio_impl.c
    src/media/media_capi.cpp
    src/diag/diag.cpp)
  if(ANDROID)
    list(APPEND CORE_SOURCES src/platform/android_jni.cpp)
  endif()
else()
  list(APPEND CORE_SOURCES src/media/media_stub.cpp)
endif()

# Shared library loaded by Flutter through dart:ffi.
add_library(cutlab_core SHARED ${CORE_SOURCES})
target_include_directories(cutlab_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_definitions(cutlab_core PRIVATE CUTLAB_CORE_BUILD CUTLAB_CORE_VERSION="${PROJECT_VERSION}")

if(CUTLAB_WITH_MEDIA)
  target_include_directories(cutlab_core PRIVATE ${CUTLAB_FFMPEG_ROOT}/include ${CUTLAB_MINIAUDIO_DIR})
  set(FF_LIBS avformat avcodec swresample swscale avutil)
  if(CUTLAB_FFMPEG_SHARED)
    foreach(lib ${FF_LIBS})
      find_library(FF_${lib} NAMES ${lib} PATHS ${CUTLAB_FFMPEG_ROOT}/lib NO_DEFAULT_PATH REQUIRED)
      target_link_libraries(cutlab_core PRIVATE ${FF_${lib}})
    endforeach()
  else()
    # Static FFmpeg is linked into the engine: one library to ship.
    foreach(lib ${FF_LIBS})
      target_link_libraries(cutlab_core PRIVATE ${CUTLAB_FFMPEG_ROOT}/lib/lib${lib}.a)
    endforeach()
    if(ANDROID)
      target_link_libraries(cutlab_core PRIVATE z m dl log android mediandk)
      # Keep FFmpeg's static symbols out of the exported table.
      target_link_options(cutlab_core PRIVATE -Wl,--exclude-libs,ALL -Wl,--gc-sections)
    elseif(UNIX AND NOT APPLE)
      find_package(Threads REQUIRED)
      target_link_libraries(cutlab_core PRIVATE z m dl Threads::Threads)
      target_link_options(cutlab_core PRIVATE -Wl,--exclude-libs,ALL -Wl,-Bsymbolic)
    endif()
  endif()
  if(UNIX AND NOT APPLE AND NOT ANDROID)
    target_link_libraries(cutlab_core PRIVATE pthread)
  endif()
endif()

# Warnings apply to our C++ only (miniaudio is third-party C).
set(CUTLAB_WARN_FLAGS)
if(MSVC)
  set(CUTLAB_WARN_FLAGS /W4 /permissive- /wd4100)
  if(CUTLAB_WARNINGS_AS_ERRORS)
    list(APPEND CUTLAB_WARN_FLAGS /WX)
  endif()
else()
  set(CUTLAB_WARN_FLAGS -Wall -Wextra -Wpedantic -Wshadow)
  if(CUTLAB_WARNINGS_AS_ERRORS)
    list(APPEND CUTLAB_WARN_FLAGS -Werror)
  endif()
endif()
target_compile_options(cutlab_core PRIVATE $<$<COMPILE_LANGUAGE:CXX>:${CUTLAB_WARN_FLAGS}>)

# Hardening: an uninitialised local (like the AVChannelLayout behind the
# 0.4.x Android preview crash) becomes zero instead of stack garbage.
if(CUTLAB_ZERO_INIT_LOCALS AND NOT MSVC)
  include(CheckCXXCompilerFlag)
  check_cxx_compiler_flag(-ftrivial-auto-var-init=zero CUTLAB_HAS_ZERO_INIT)
  if(CUTLAB_HAS_ZERO_INIT)
    target_compile_options(cutlab_core PRIVATE $<$<COMPILE_LANGUAGE:CXX>:-ftrivial-auto-var-init=zero>)
  endif()
endif()

if(CUTLAB_BUILD_TESTS)
  enable_testing()
  # Time tests link the sources directly to reach internal C++ symbols.
  add_executable(cutlab_core_tests tests/test_time.cpp src/time.cpp src/capi.cpp src/media/media_stub.cpp)
  target_include_directories(cutlab_core_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_compile_definitions(cutlab_core_tests PRIVATE CUTLAB_CORE_BUILD CUTLAB_CORE_VERSION="${PROJECT_VERSION}")
  add_test(NAME cutlab_core_tests COMMAND cutlab_core_tests)

  if(CUTLAB_WITH_MEDIA)
    # Media tests use only the exported C ABI, exactly as Flutter does.
    add_executable(cutlab_media_tests tests/test_media.cpp)
    target_link_libraries(cutlab_media_tests PRIVATE cutlab_core)
    add_test(NAME cutlab_media_tests COMMAND cutlab_media_tests)
    set_tests_properties(cutlab_media_tests PROPERTIES TIMEOUT 900)
    add_executable(cutlab_timeline_tests tests/test_timeline.cpp)
    target_link_libraries(cutlab_timeline_tests PRIVATE cutlab_core)
    add_test(NAME cutlab_timeline_tests COMMAND cutlab_timeline_tests)
    set_tests_properties(cutlab_timeline_tests PROPERTIES TIMEOUT 900)
    add_executable(cutlab_bench_timeline tests/bench_timeline.cpp)
    target_link_libraries(cutlab_bench_timeline PRIVATE cutlab_core)
    # Preview stress test (run by hand / in CI on real-size media files).
    find_package(Threads REQUIRED)
    add_executable(cutlab_stress_preview tests/stress_preview.cpp)
    target_link_libraries(cutlab_stress_preview PRIVATE cutlab_core Threads::Threads)
    if(UNIX)
      # The native crash handler (fork + deliberate crash; POSIX only).
      add_executable(cutlab_crash_report_tests tests/test_crash_report.cpp)
      target_link_libraries(cutlab_crash_report_tests PRIVATE cutlab_core)
      add_test(NAME cutlab_crash_report_tests COMMAND cutlab_crash_report_tests ${CMAKE_CURRENT_BINARY_DIR}/crash-report-test)
    endif()
  endif()
endif()
