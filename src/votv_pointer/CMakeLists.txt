cmake_minimum_required(VERSION 3.20)
project(votv_pointer CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

# UEVR plugin headers (MIT, uevr/Plugin.hpp, API.h/.hpp) from the UEVR release folder, not copied into the repo.
set(UEVR_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/UEVR/1.05/UEVR/include" CACHE PATH "UEVR include dir")

add_library(votv_pointer SHARED votv_pointer.cpp)
target_include_directories(votv_pointer PRIVATE ${UEVR_INCLUDE})
target_compile_definitions(votv_pointer PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(votv_pointer PRIVATE user32 d3d11 dxgi)

add_executable(pointer_test pointer_test.cpp)
