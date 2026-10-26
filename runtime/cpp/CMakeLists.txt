cmake_minimum_required(VERSION 3.24)
project(material_maker_runtime C CXX)

# Standalone renderer for Material Maker runtime packages (.mmr), with Vulkan
# compute shaders. Dependencies are fetched at configure time.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# Header and source only dependencies are fetched without adding their own
# CMake projects (SOURCE_SUBDIR points to a directory without CMakeLists.txt)
FetchContent_Declare(vulkan_headers
	GIT_REPOSITORY https://github.com/KhronosGroup/Vulkan-Headers.git
	GIT_TAG vulkan-sdk-1.4.363.0
	GIT_SHALLOW TRUE
	SOURCE_SUBDIR none)
FetchContent_Declare(volk
	GIT_REPOSITORY https://github.com/zeux/volk.git
	GIT_TAG vulkan-sdk-1.4.363.0
	GIT_SHALLOW TRUE
	SOURCE_SUBDIR none)
FetchContent_Declare(tinyexr
	GIT_REPOSITORY https://github.com/syoyo/tinyexr.git
	GIT_TAG v3.2.0
	GIT_SHALLOW TRUE
	SOURCE_SUBDIR none)
FetchContent_Declare(miniz
	GIT_REPOSITORY https://github.com/richgel999/miniz.git
	GIT_TAG 3.1.2
	GIT_SHALLOW TRUE)
FetchContent_Declare(json
	GIT_REPOSITORY https://github.com/nlohmann/json.git
	GIT_TAG v3.12.0
	GIT_SHALLOW TRUE)

set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_FUZZERS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(JSON_BuildTests OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(vulkan_headers volk tinyexr miniz json)

add_library(mmr_volk STATIC ${volk_SOURCE_DIR}/volk.c)
target_include_directories(mmr_volk PUBLIC ${volk_SOURCE_DIR} ${vulkan_headers_SOURCE_DIR}/include)
if(WIN32)
	target_compile_definitions(mmr_volk PUBLIC VK_USE_PLATFORM_WIN32_KHR NOMINMAX)
endif()

add_library(mmr_runtime STATIC
	src/package.cpp
	src/image_io.cpp
	src/tinyexr_impl.cpp
	src/renderer.cpp)
target_include_directories(mmr_runtime PUBLIC include PRIVATE src ${tinyexr_SOURCE_DIR})
target_link_libraries(mmr_runtime PUBLIC mmr_volk PRIVATE miniz nlohmann_json::nlohmann_json)

add_executable(mmr_render tools/mmr_render.cpp)
target_link_libraries(mmr_render PRIVATE mmr_runtime)

if(MSVC)
	target_compile_definitions(mmr_runtime PRIVATE _CRT_SECURE_NO_WARNINGS)
	target_compile_options(mmr_runtime PRIVATE /W3 /utf-8)
	target_compile_options(mmr_render PRIVATE /W3 /utf-8)
endif()
