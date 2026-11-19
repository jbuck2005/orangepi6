#!/bin/bash
# Build GPU benchmark tools on aiPi (-j6 only). Logs to ~/bench/build.log.
set -euo pipefail
mkdir -p ~/bench && cd ~/bench
exec >> build.log 2>&1
echo "== $(date -Is) start"
if [ ! -d llama.cpp ]; then
  TAG=$(git ls-remote --tags --refs https://github.com/ggml-org/llama.cpp | awk -F/ '{print $3}' | grep -E '^b[0-9]+$' | sort -V | tail -1)
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp
fi
cd llama.cpp && git log --oneline -1
cmake -B build -G Ninja -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF
cmake --build build -j6 --target llama-bench llama-cli
cd ~/bench
if [ ! -d vkpeak ]; then git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/nihui/vkpeak; fi
cd vkpeak && git log --oneline -1
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build -j6
echo "== $(date -Is) done EXIT=0"
