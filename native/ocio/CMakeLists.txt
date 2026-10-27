cmake_minimum_required(VERSION 3.24)
project(mm_ocio CXX)

# OpenColorIO GDExtension for Material Maker. OpenColorIO must be built and
# installed first (see README.md, or build.py that does everything).

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(GODOT_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/build/godot-cpp" CACHE PATH "godot-cpp sources (godot-4.5-stable)")
set(OCIO_INSTALL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/build/ocio-install" CACHE PATH "OpenColorIO install prefix")
set(ADDON_BIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../addons/material_maker/ocio/bin" CACHE PATH "Where the extension is copied")

set(GODOTCPP_TARGET template_release CACHE STRING "")
# OpenColorIO reports errors with exceptions (godot-cpp disables them by default)
set(GODOTCPP_DISABLE_EXCEPTIONS OFF CACHE BOOL "" FORCE)
add_subdirectory(${GODOT_CPP_DIR} godot-cpp EXCLUDE_FROM_ALL)

find_package(OpenColorIO CONFIG REQUIRED PATHS ${OCIO_INSTALL_DIR} NO_DEFAULT_PATH)

add_library(mm_ocio SHARED src/register_types.cpp src/mm_ocio.cpp)
target_link_libraries(mm_ocio PRIVATE godot::cpp OpenColorIO::OpenColorIO)

if(WIN32)
	set(MM_OCIO_PLATFORM windows)
elseif(APPLE)
	set(MM_OCIO_PLATFORM macos)
else()
	set(MM_OCIO_PLATFORM linux)
endif()
if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64|ARM64")
	set(MM_OCIO_ARCH arm64)
else()
	set(MM_OCIO_ARCH x86_64)
endif()
set_target_properties(mm_ocio PROPERTIES
	OUTPUT_NAME "mm_ocio.${MM_OCIO_PLATFORM}.${MM_OCIO_ARCH}"
	PREFIX "")
# OpenColorIO's library is next to the extension
if(APPLE)
	set_target_properties(mm_ocio PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "@loader_path")
elseif(UNIX)
	set_target_properties(mm_ocio PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "$ORIGIN")
endif()

# The extension, OpenColorIO's library and the .gdextension file go to the
# addon (they are not versioned: Material Maker works without them)
add_custom_command(TARGET mm_ocio POST_BUILD
	COMMAND ${CMAKE_COMMAND} -E make_directory ${ADDON_BIN_DIR}
	COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:mm_ocio> ${ADDON_BIN_DIR}
	# Linux and macOS load the library by its versioned name (soname)
	COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:OpenColorIO::OpenColorIO> ${ADDON_BIN_DIR}/$<IF:$<BOOL:${WIN32}>,$<TARGET_FILE_NAME:OpenColorIO::OpenColorIO>,$<TARGET_SONAME_FILE_NAME:OpenColorIO::OpenColorIO>>
	COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_CURRENT_SOURCE_DIR}/mm_ocio.gdextension ${ADDON_BIN_DIR}/..)
