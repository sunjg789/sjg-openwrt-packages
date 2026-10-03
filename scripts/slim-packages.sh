#!/usr/bin/env bash
# ============================================================
# slim-packages.sh — 对拍平的包目录瘦身
# 用法: bash slim-packages.sh <DIR>
#   DIR  目录内为拍平的 *.ipk 或 *.apk（收集时丢失了 feed 来源信息）
#
# 删除规则（这些包官方源/Image Builder 环境均提供，x86 软路由无需自托管）：
#   1. *-firmware-* / linux-firmware-*  无线/硬件固件（x86 软路由用不到，数百 MB）
#   2. kmod-*                            内核模块（必须与固件内核同源，不应跨源安装）
#   3. luci-i18n-* 非 zh-cn              只保留简体中文语言包（英文为内置基础语言）
# ============================================================
set -uo pipefail

DIR="${1:?用法: slim-packages.sh <DIR>}"
[ -d "$DIR" ] || { echo "!! 目录不存在: $DIR"; exit 1; }
cd "$DIR" || exit 1

before="$(find . -maxdepth 1 -type f \( -name '*.ipk' -o -name '*.apk' \) | wc -l)"
rm_fw=0; rm_kmod=0; rm_i18n=0

# 1) firmware
while IFS= read -r -d '' f; do rm -f "$f"; rm_fw=$((rm_fw + 1)); done < <(
  find . -maxdepth 1 -type f \( -name '*-firmware-*' -o -name 'linux-firmware-*' \) -print0 2>/dev/null)

# 2) kmod
while IFS= read -r -d '' f; do rm -f "$f"; rm_kmod=$((rm_kmod + 1)); done < <(
  find . -maxdepth 1 -type f -name 'kmod-*' -print0 2>/dev/null)

# 3) luci-i18n 非 zh-cn
while IFS= read -r -d '' f; do
  case "$(basename "$f")" in
    *-zh-cn-*) : ;;          # 保留简体中文
    *) rm -f "$f"; rm_i18n=$((rm_i18n + 1)) ;;
  esac
done < <(find . -maxdepth 1 -type f -name 'luci-i18n-*' -print0 2>/dev/null)

after="$(find . -maxdepth 1 -type f \( -name '*.ipk' -o -name '*.apk' \) | wc -l)"
echo "==> 瘦身 $DIR"
echo "    删除 firmware $rm_fw 个 / kmod $rm_kmod 个 / 非中文 i18n $rm_i18n 个"
echo "    $before -> $after 个包"
