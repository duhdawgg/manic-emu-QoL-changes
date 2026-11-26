#!/bin/bash
# Azahar iOS LibRetro 构建脚本

set -e  # 出错时退出

echo "================================================"
echo "  MelonDSDS iOS LibRetro Core Build Script"
echo "================================================"


cmake -B build --toolchain ./cmake/toolchain/ios.toolchain.cmake -DPLATFORM=OS64 -DDEPLOYMENT_TARGET=14 -DCMAKE_BUILD_TYPE=Release -DENABLE_JIT=ON

make -C build -j4                                                                                                                      
    