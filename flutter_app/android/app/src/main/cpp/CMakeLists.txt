cmake_minimum_required(VERSION 3.22.1)
project(secure_import LANGUAGES CXX)

add_library(secure_import SHARED secure_import.cpp mcp_launch_io.cpp rootfs_browser_io.cpp)
target_compile_features(secure_import PRIVATE cxx_std_17)
target_compile_options(secure_import PRIVATE -fvisibility=hidden)
target_link_libraries(secure_import android log)
