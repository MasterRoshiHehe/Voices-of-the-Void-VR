cmake_minimum_required(VERSION 3.20)
project(votv_marks CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

# UEVR plugin headers (MIT, uevr/Plugin.hpp, API.h/.hpp) from the UEVR release folder, not copied into the repo.
set(UEVR_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/UEVR/1.05/UEVR/include" CACHE PATH "UEVR include dir")

add_library(votv_marks SHARED votv_marks.cpp)
target_include_directories(votv_marks PRIVATE ${UEVR_INCLUDE})
target_compile_definitions(votv_marks PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(votv_marks PRIVATE user32 gdi32 gdiplus d3d11)

add_executable(mark_logic_test mark_logic_test.cpp)
