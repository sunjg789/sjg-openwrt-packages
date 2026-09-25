#!/usr/bin/env bash
# ============================================================
# fetch-and-build.sh — 下载 SDK → 克隆插件源码 → 逐个编译 → 收集产物
# 用法: bash fetch-and-build.sh <SDK_URL> <OUT_DIR> <PLUGINS_CONF>
#   SDK_URL     ImmortalWrt SDK 压缩包完整 URL
#   OUT_DIR     产物输出目录（如 repo/apk/x86_64）
#   PLUGINS_CONF 收录清单（plugins.conf）
# 产物: OUT_DIR 下收集全部编译出的 .ipk（opkg 系）或 .apk（apk 系）
# ============================================================
set -uo pipefail

SDK_URL="${1:?用法: fetch-and-build.sh <SDK_URL> <OUT_DIR> <PLUGINS_CONF>}"
OUT_DIR="${2:?缺少 OUT_DIR}"
PLUGINS_CONF="${3:?缺少 PLUGINS_CONF}"

WORK="$(pwd)"
mkdir -p "$OUT_DIR"

echo "==> [1/4] 下载 SDK: $(basename "$SDK_URL")"
TARBALL="$(basename "$SDK_URL")"
if [ ! -f "$WORK/$TARBALL" ]; then
  wget -q --tries=3 "$SDK_URL" -O "$WORK/$TARBALL" \
    || curl -fsSL --retry 3 "$SDK_URL" -o "$WORK/$TARBALL"
fi
[ -s "$WORK/$TARBALL" ] || { echo "!! SDK 下载失败"; exit 1; }

echo "==> [2/4] 解压 SDK"
tar --zstd -xf "$WORK/$TARBALL" -C "$WORK"
SDK_DIR="$(find "$WORK" -maxdepth 1 -type d -name '*sdk*' | head -n1)"
[ -n "$SDK_DIR" ] || { echo "!! SDK 解压失败"; exit 1; }
echo "    SDK 目录: $SDK_DIR"
cd "$SDK_DIR"

echo "==> 更新并安装 feeds（提供 luci-base 等编译依赖源码）"
./scripts/feeds update -a >/tmp/feeds-update.log 2>&1 \
  || echo "    (feeds update 警告，继续)"
./scripts/feeds install -a >/tmp/feeds-install.log 2>&1 \
  || echo "    (feeds install 警告，继续)"

# ImmortalWrt 25.12 SDK 的 packages feed 中 nginx-mod-ubus 存在递归依赖 bug，
# 本库不编译 nginx，移除其 feed 源码避免污染全局 Kconfig 配置生成
rm -rf package/feeds/packages/nginx 2>/dev/null || true

echo "==> [3/4] 克隆插件源码（收录清单: $PLUGINS_CONF）"
source "$PLUGINS_CONF"
for entry in "${PLUGINS[@]}"; do
  IFS='|' read -r dir url target note <<< "$entry"
  if [ "$url" = "SMALLPKG" ]; then
    echo "    · $dir <- small-package（稀疏拉取，见 [2.5/4]）"
    continue
  fi
  if [ -d "package/$dir" ]; then rm -rf "package/$dir"; fi
  if git clone --quiet --depth 1 --single-branch "$url" "package/$dir" 2>/dev/null \
     || git clone --quiet --depth 1 "$url" "package/$dir" 2>/dev/null; then
    echo "    ✓ $dir  <-  $url"
  else
    echo "    ✗ clone 失败: $dir ($url)，跳过"
  fi
done

echo "==> [2.5/4] 同步 small-package 收录（kenzok8 热门源码合集，稀疏拉取）..."
SMALL_SRC="https://github.com/kenzok8/small-package.git"
SMALL_DIRS=()
for entry in "${PLUGINS[@]}"; do
  IFS='|' read -r dir url target note <<< "$entry"
  if [ "$url" = "SMALLPKG" ]; then
    IFS=',' read -ra ds <<< "$dir"
    for d in "${ds[@]}"; do SMALL_DIRS+=("$d"); done
  fi
done
if [ "${#SMALL_DIRS[@]}" -gt 0 ]; then
  if [ ! -d "$WORK/smallpkg" ]; then
    git clone --depth 1 --filter=blob:none --sparse "$SMALL_SRC" "$WORK/smallpkg" 2>/dev/null \
      || git clone --depth 1 "$SMALL_SRC" "$WORK/smallpkg" 2>/dev/null \
      || { echo "    ✗ small-package clone 失败（跳过全部 SMALLPKG 条目）"; SMALL_DIRS=(); }
  fi
  if [ "${#SMALL_DIRS[@]}" -gt 0 ]; then
    (cd "$WORK/smallpkg" && git sparse-checkout set "${SMALL_DIRS[@]}") 2>/dev/null || true
    for d in "${SMALL_DIRS[@]}"; do
      if [ -d "package/$d" ]; then echo "    目录已存在，跳过: $d"; continue; fi
      if [ -d "$WORK/smallpkg/$d" ]; then
        cp -r "$WORK/smallpkg/$d" "package/"
        echo "    ✓ smallpkg: $d"
      else
        echo "    ✗ small-package 中无此目录: $d"
      fi
    done
  fi
fi

echo "==> 生成默认 .config（make defconfig，避免无终端交互 menuconfig）"
export TERM=xterm
make defconfig >/tmp/defconfig.log 2>&1 || {
  echo "!! defconfig 失败（多为某插件 Kconfig 递归依赖，见尾部）"
  tail -n 20 /tmp/defconfig.log
  exit 1
}

echo "==> [4/4] 逐个编译插件"
for entry in "${PLUGINS[@]}"; do
  IFS='|' read -r dir url target note <<< "$entry"
  if [ "$target" = "-" ]; then
    echo "    - 跳过编译（仅克隆，依赖自动解析）: $dir"
    continue
  fi
  if [ ! -d "package/$target" ]; then
    echo "    ✗ 源码目录缺失，跳过: $target（依赖未拉取或上游改名）"
    continue
  fi
  echo "==> 编译 $target（$note）"
  if make -j"$(nproc)" "package/$target/compile" V=s >"/tmp/build-$target.log" 2>&1; then
    echo "    ✓ $target 成功"
  else
    echo "    ✗ $target 失败（日志尾部见下）"
    tail -n 15 "/tmp/build-$target.log"
  fi
done

echo "==> 收集产物 -> $OUT_DIR"
find bin/packages -type f \( -name '*.ipk' -o -name '*.apk' \) -exec cp -n {} "$OUT_DIR/" \; 2>/dev/null
COUNT="$(ls -1 "$OUT_DIR" | wc -l)"
echo "    共收集 $COUNT 个包文件"
[ "$COUNT" -gt 0 ] || { echo "!! 未收集到任何包"; exit 1; }
echo "==> 完成"
