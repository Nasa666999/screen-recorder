#!/bin/bash
set -euo pipefail

identity="${1:-Screen Recorder Local Development}"
if [[ "$identity" == "-" ]]; then
    printf '%s\n' '注意：已明确选择临时签名，重新构建后 macOS 可能要求重新授予录屏权限。' >&2
    exit 0
fi

# 写入应用前先确认固定身份存在，避免缺少证书时覆盖仍可运行的已授权构建。
identities="$(security find-identity -v -p codesigning)"
if ! printf '%s\n' "$identities" | awk -v requested="$identity" '
    $2 == toupper(requested) {
        found = 1
    }
    {
        first = index($0, "\"")
        if (first > 0 && substr($0, first) == "\"" requested "\"") {
            found = 1
        }
    }
    END {
        exit !found
    }
'; then
    printf '找不到有效的代码签名身份：%s\n' "$identity" >&2
    printf '%s\n' '请先在钥匙串配置固定代码签名证书，或通过 SIGN_IDENTITY 指定现有身份。' >&2
    printf '%s\n' '仅需临时运行时可明确使用 SIGN_IDENTITY=-；该方式不保证授权跨构建保留。' >&2
    exit 1
fi
