#!/usr/bin/env bash
# ============================================================
# gen-index.sh — 生成软件源索引并签名
# 用法: bash gen-index.sh <fmt> <DIR> <KEYS_DIR> <ROOT>
#   fmt      opkg | apk
#   DIR      包目录（该目录下为 *.ipk 或 *.apk）
#   KEYS_DIR usign 密钥目录（不存在则自动生成）
#   ROOT     构建工作根（SDK 解压目录的父目录，用于定位 host 工具）
#
# 产物:
#   opkg: Packages / Packages.gz / Packages.sig
#   apk : APKINDEX.tar.gz / APKINDEX.tar.gz.sig
# ============================================================
set -uo pipefail

FMT="${1:?用法: gen-index.sh <opkg|apk> <DIR> <KEYS_DIR> <ROOT>}"
DIR="${2:?缺少 DIR}"
KEYS_DIR="${3:?缺少 KEYS_DIR}"
ROOT="${4:?缺少 ROOT}"

# 按格式定位对应版本的 SDK（opkg 用 24.10 系、apk 用 25.12 系；找不到时回退任意 sdk）
if [ "$FMT" = "opkg" ]; then
  SDK_DIR="$(find "$ROOT" -maxdepth 2 -type d -name '*sdk*24.10*' | head -n1)"
  [ -n "$SDK_DIR" ] || SDK_DIR="$(find "$ROOT" -maxdepth 2 -type d -name '*sdk*' | head -n1)"
else
  SDK_DIR="$(find "$ROOT" -maxdepth 2 -type d -name '*sdk*25.12*' | head -n1)"
  [ -n "$SDK_DIR" ] || SDK_DIR="$(find "$ROOT" -maxdepth 2 -type d -name '*sdk*' | head -n1)"
fi

mkdir -p "$KEYS_DIR"
cd "$DIR" || exit 1

# ---------- 定位工具（优先 SDK 原始路径：其动态链接依赖 SDK 内 lib，cp 到 /usr/local/bin 会破坏） ----------
USIGN=""
if [ -n "$SDK_DIR" ]; then
  for cand in "$SDK_DIR/staging_dir/host/bin/usign" \
              "$SDK_DIR/staging_dir/host/usr/bin/usign"; do
    if [ -x "$cand" ]; then USIGN="$cand"; break; fi
  done
fi
if [ -z "$USIGN" ]; then
  USIGN="$(command -v usign || true)"
fi
if [ -z "$USIGN" ]; then
  echo "!! 未找到 usign，跳过签名（未签名源在多数固件中仍可用）"
fi

# ---------- 签名密钥（首次自动生成，之后复用） ----------
if [ -z "$(ls -A "$KEYS_DIR" 2>/dev/null)" ] && [ -n "$USIGN" ]; then
  echo "==> 生成 usign 密钥对: $KEYS_DIR"
  (cd "$KEYS_DIR" && "$USIGN" -G -s secret.key -p public.key)
fi

# ---------- 生成索引 ----------
if [ "$FMT" = "opkg" ]; then
  echo "==> 生成 opkg 索引（Packages / Packages.gz）"
  # opkg 索引：直接用简易生成器（解析 OpenWrt 标准 ipk 命名 name_version_arch.ipk）。
  # 不依赖 SDK 的 ipkg-make-index.sh——它需要 `sha256` 命令（OpenBSD 工具，Ubuntu 无），
  # 且在不同构建机行为不一致。
  {
    for f in *.ipk; do
      [ -f "$f" ] || continue
      base="${f%.ipk}"
      name="${base%%_*}"
      rest="${base#*_}"
      ver_arch="${rest%_*}"
      arch="${rest##*_}"
      printf 'Package: %s\nVersion: %s\nArchitecture: %s\nFilename: %s\nSize: %s\nSHA256sum: %s\n\n' \
        "$name" "$ver_arch" "$arch" "$f" \
        "$(stat -c%s "$f")" "$(sha256sum "$f" | awk '{print $1}')"
    done
  } > Packages
  gzip -9c Packages > Packages.gz
  if [ -n "$USIGN" ] && [ -f "$KEYS_DIR/secret.key" ]; then
    "$USIGN" -S -m Packages -s "$KEYS_DIR/secret.key"
    echo "    Packages.sig 已生成"
  fi
  echo "==> opkg 索引完成: $(ls Packages* | tr '\n' ' ')"

elif [ "$FMT" = "apk" ]; then
  echo "==> 生成 apk 索引（APKINDEX.tar.gz）"
  APK_TOOL=""
  if [ -n "$SDK_DIR" ]; then
    for cand in "$SDK_DIR/staging_dir/host/bin/apk" \
                "$SDK_DIR/staging_dir/host/usr/bin/apk"; do
      if [ -x "$cand" ]; then APK_TOOL="$cand"; break; fi
    done
  fi
  if [ -z "$APK_TOOL" ]; then
    APK_TOOL="$(command -v apk || true)"
  fi
  if [ -z "$APK_TOOL" ]; then
    echo "!! 未找到 apk-tools，无法生成 APKINDEX（请在 runner 安装 apk-tools）"
    exit 1
  fi
  # 包文件需与索引同目录；*.apk 已在 DIR 内
  # --allow-untrusted：SDK 构建的包由 SDK 构建密钥签名，本机无对应公钥，
  # 校验会报 UNTRUSTED 导致索引生成失败；签名在源级由下方 usign 完成。
  "$APK_TOOL" index --allow-untrusted -o APKINDEX.tar.gz ./*.apk
  if [ -n "$USIGN" ] && [ -f "$KEYS_DIR/secret.key" ]; then
    "$USIGN" -S -m APKINDEX.tar.gz -s "$KEYS_DIR/secret.key"
    echo "    APKINDEX.tar.gz.sig 已生成"
  fi
  echo "==> apk 索引完成: $(ls APKINDEX.tar.gz* | tr '\n' ' ')"
else
  echo "!! 未知格式: $FMT（仅支持 opkg / apk）"
  exit 1
fi
echo "==> 完成"
