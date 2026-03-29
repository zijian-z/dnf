cmake_minimum_required (VERSION 2.8)

project ("server")

link_directories(${CMAKE_SOURCE_DIR}/lib)
include_directories(/usr/include/c++/4.4.4/i686-redhat-linux)

set(CMAKE_CXX_STANDARD 11)#不支持11
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++0x")

#改用编译器标志
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fvisibility=hidden")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fvisibility=hidden")

SET(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,--no-as-needed")

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -m32")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -m32")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -m32")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY /home/neople/game)

include_directories(inc)
add_library(fd SHARED "server.cpp" "server.h" "frida-gum.h" "mysql.cpp" "common.h")
target_link_libraries(fd libfrida-gum.a pthread dl)

