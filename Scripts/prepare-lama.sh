#!/bin/bash
set -euo pipefail

packages=(LaMa FastLaMa)
urls=(
    'https://huggingface.co/arraypress/erase-lama/resolve/ef3cdb380b3978f25ec5371b42c0dbbb2f4e5fed/LaMa.mlpackage'
    'https://huggingface.co/Dadm-n/lama-dilated-coreml/resolve/51853822134974a99c9a473175228104f6c97767/Resources/LaMa.mlpackage'
)
files=(
    Manifest.json
    Data/com.apple.CoreML/model.mlmodel
    Data/com.apple.CoreML/weights/weight.bin
)
hashes=(
    a1ca836d96d681498ca6c80438ddbb56557ab2ba3b5b2c4cf24a8d448d83c30f
    289f2c611bd3e52805ee3e686e290981d96d3b9674db93fe6bf30962f7e60d87
    b80614ec29e2362acc33cd4f37bb87574c07229fa378655fe2ada8c5be5a17bd
    6815fbbc528559f940d5100d975482adda46abfd6bb819e7faa0698256e9e9fd
    f39493f520a05444c3112c491249d855626d0b296b404f0b1a3a49641f527bd3
    2b2226b91788047b75794bd990c6eac7200853389d636692799764f40fb93bbd
)
mkdir -p .build
xcrun swiftc -parse-as-library -module-cache-path .build/module-cache Scripts/compile-lama.swift -o .build/compile-lama
for package_index in 0 1; do
    package="${packages[$package_index]}"
    source=".build/$package.mlpackage"
    compiled=".build/$package.mlmodelc"
    mkdir -p "$source/Data/com.apple.CoreML/weights"
    for file_index in 0 1 2; do
        target="$source/${files[$file_index]}"
        hash_index=$((package_index * 3 + file_index))
        expected="${hashes[$hash_index]}"
        if ! printf '%s  %s\n' "$expected" "$target" | shasum -a 256 -c --status 2>/dev/null; then
            curl --fail --location --retry 3 "${urls[$package_index]}/${files[$file_index]}" -o "$target.download"
            printf '%s  %s\n' "$expected" "$target.download" | shasum -a 256 -c --status
            mv "$target.download" "$target"
        fi
    done
    if [ ! -d "$compiled" ] \
        || [ Scripts/compile-lama.swift -nt "$compiled" ] \
        || [ Scripts/prepare-lama.sh -nt "$compiled" ] \
        || [ "$source/Manifest.json" -nt "$compiled" ] \
        || [ "$source/Data/com.apple.CoreML/model.mlmodel" -nt "$compiled" ] \
        || [ "$source/Data/com.apple.CoreML/weights/weight.bin" -nt "$compiled" ]; then
        .build/compile-lama "$source" "$compiled"
    fi
done
