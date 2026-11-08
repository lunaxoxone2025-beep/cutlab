cmake_minimum_required(VERSION 3.16)
project(cutlab_core VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(CUTLAB_BUILD_TESTS "Build cutlab core unit tests" ON)
option(CUTLAB_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)

# Shared library: this is what Flutter loads through dart:ffi (Phase 3).
add_library(cutlab_core SHARED
  src/time.cpp
  src/capi.cpp
)
target_include_directories(cutlab_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_definitions(cutlab_core
  PRIVATE CUTLAB_CORE_BUILD CUTLAB_CORE_VERSION="${PROJECT_VERSION}")

if(MSVC)
  target_compile_options(cutlab_core PRIVATE /W4 /permissive-)
  if(CUTLAB_WARNINGS_AS_ERRORS)
    target_compile_options(cutlab_core PRIVATE /WX)
  endif()
else()
  target_compile_options(cutlab_core PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)
  if(CUTLAB_WARNINGS_AS_ERRORS)
    target_compile_options(cutlab_core PRIVATE -Werror)
  endif()
endif()

if(CUTLAB_BUILD_TESTS)
  enable_testing()
  # Tests link the sources statically so they can reach internal C++ symbols
  # that the shared library keeps hidden.
  add_executable(cutlab_core_tests tests/test_time.cpp src/time.cpp src/capi.cpp)
  target_include_directories(cutlab_core_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_compile_definitions(cutlab_core_tests PRIVATE CUTLAB_CORE_BUILD CUTLAB_CORE_VERSION="${PROJECT_VERSION}")
  add_test(NAME cutlab_core_tests COMMAND cutlab_core_tests)
endif()
