#!/bin/bash
set -euo pipefail

mkdir -p .build/LaMa.mlpackage/Data/com.apple.CoreML/weights
base='https://huggingface.co/arraypress/erase-lama/resolve/ef3cdb380b3978f25ec5371b42c0dbbb2f4e5fed'
files=(
    Manifest.json
    Data/com.apple.CoreML/model.mlmodel
    Data/com.apple.CoreML/weights/weight.bin
)
hashes=(
    a1ca836d96d681498ca6c80438ddbb56557ab2ba3b5b2c4cf24a8d448d83c30f
    289f2c611bd3e52805ee3e686e290981d96d3b9674db93fe6bf30962f7e60d87
    b80614ec29e2362acc33cd4f37bb87574c07229fa378655fe2ada8c5be5a17bd
)
for index in 0 1 2; do
    target=".build/LaMa.mlpackage/${files[$index]}"
    expected="${hashes[$index]}"
    if ! printf '%s  %s\n' "$expected" "$target" | shasum -a 256 -c --status 2>/dev/null; then
        curl --fail --location --retry 3 "$base/LaMa.mlpackage/${files[$index]}" -o "$target.download"
        printf '%s  %s\n' "$expected" "$target.download" | shasum -a 256 -c --status
        mv "$target.download" "$target"
    fi
done
if [ ! -d .build/LaMa.mlmodelc ] \
    || [ Scripts/compile-lama.swift -nt .build/LaMa.mlmodelc ] \
    || [ Scripts/prepare-lama.sh -nt .build/LaMa.mlmodelc ] \
    || [ .build/LaMa.mlpackage/Manifest.json -nt .build/LaMa.mlmodelc ] \
    || [ .build/LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel -nt .build/LaMa.mlmodelc ] \
    || [ .build/LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin -nt .build/LaMa.mlmodelc ]; then
    xcrun swiftc -parse-as-library -module-cache-path .build/module-cache Scripts/compile-lama.swift -o .build/compile-lama
    .build/compile-lama
fi
