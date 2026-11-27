cmake_minimum_required(VERSION 3.20)
project(votv_controls C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

# UEVR plugin headers (MIT, uevr/Plugin.hpp, API.h/.hpp) from the UEVR release folder, not copied into the repo.
set(UEVR_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/UEVR/1.05/UEVR/include" CACHE PATH "UEVR include dir")

set(MINHOOK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/minhook/minhook-1.3.3" CACHE PATH "MinHook source (BSD-2)")
add_library(minhook STATIC ${MINHOOK_DIR}/src/buffer.c ${MINHOOK_DIR}/src/hook.c ${MINHOOK_DIR}/src/trampoline.c ${MINHOOK_DIR}/src/hde/hde64.c)
target_include_directories(minhook PUBLIC ${MINHOOK_DIR}/include)
add_library(votv_controls SHARED votv_controls.cpp)
set(OPENVR_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/openvr-sdk/v2.15.6/headers" CACHE PATH "OpenVR headers")
set(OPENXR_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/openxr-sdk/include" CACHE PATH "OpenXR headers")
target_include_directories(votv_controls PRIVATE ${UEVR_INCLUDE} ${OPENVR_INCLUDE} ${OPENXR_INCLUDE})
target_compile_definitions(votv_controls PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(votv_controls PRIVATE user32 psapi minhook)

add_executable(mapper_test mapper_test.cpp)
