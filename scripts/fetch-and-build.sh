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

# ImmortalWrt 25.12 SDK 的 packages feed 中存在递归依赖 bug 的包（本库不编译它们），
# 必须在 feeds install 之前先从 feeds 源目录删除，install 才不会把软链装进 package/feeds。
# 已确认的递归包（静态扫描 + 构建日志逐个确认，12 个）：
#   net/asterisk    asterisk-curl / asterisk-res-stir-shaken / asterisk-res-pjsip-stir-shaken 递归
#   net/nginx       nginx-mod-ubus 递归
#   net/gensio      GENSIO_SSL/GENSIO_AVAHI 等 ↔ PACKAGE_libgensio 递归（asterisk 依赖库）
#   net/ifstat      IFSTAT_SNMP ↔ PACKAGE_ifstat
#   net/kadnode     KADNODE_ENABLE_TLS 等 ↔ PACKAGE_kadnode
#   net/natmap      PACKAGE_natmap is selected by PACKAGE_natmap（自选择递归）
#   net/oscam       OSCAM_USE_LIBUSB ↔ PACKAGE_oscam
#   admin/rsyslog   RSYSLOG_elasticsearch ↔ PACKAGE_rsyslog
#   mail/mutt       MUTT_SASL ↔ PACKAGE_mutt
#   multimedia/tvheadend  TVHEADEND_AVAHI_SUPPORT ↔ PACKAGE_tvheadend
#   utils/parted    PARTED_READLINE ↔ PACKAGE_parted
#   utils/qemu      QEMU_UI_VNC_SASL ↔ PACKAGE_qemu-x86_64-softmmu
# 双保险：install 后再次 find 全量清理；编译循环内还有递归自愈（兜底 feed 新引入的递归包）。
echo "==> 移除递归依赖 feed 源码（12 包）"
rm -rf feeds/packages/net/asterisk feeds/packages/net/nginx feeds/packages/net/gensio \
       feeds/packages/net/ifstat feeds/packages/net/kadnode feeds/packages/net/natmap \
       feeds/packages/net/oscam feeds/packages/admin/rsyslog feeds/packages/mail/mutt \
       feeds/packages/multimedia/tvheadend feeds/packages/utils/parted \
       feeds/packages/utils/qemu 2>/dev/null || true
find feeds -maxdepth 5 -type d \( -name 'asterisk' -o -name 'nginx' -o -name 'gensio' -o -name 'ifstat' \
       -o -name 'kadnode' -o -name 'natmap' -o -name 'oscam' -o -name 'rsyslog' -o -name 'mutt' \
       -o -name 'tvheadend' -o -name 'parted' -o -name 'qemu' \) -exec rm -rf {} + 2>/dev/null || true
# 精确诊断：列出仍存在的目标目录（避免 grep 宽匹配误报 nginx-util 等）
LEFT=$(find feeds/packages -maxdepth 3 -type d \( -name 'asterisk' -o -name 'nginx' -o -name 'gensio' -o -name 'ifstat' \
       -o -name 'kadnode' -o -name 'natmap' -o -name 'oscam' -o -name 'rsyslog' -o -name 'mutt' \
       -o -name 'tvheadend' -o -name 'parted' -o -name 'qemu' \) 2>/dev/null)
if [ -n "$LEFT" ]; then
  echo "!! feeds 源目录仍存在: $LEFT"
else
  echo "    ✓ feeds 源已清理"
fi

./scripts/feeds install -a >/tmp/feeds-install.log 2>&1 \
  || echo "    (feeds install 警告，继续)"

# install 后兜底：包软链若仍存在则删除
rm -rf package/feeds/packages/asterisk package/feeds/packages/nginx package/feeds/packages/gensio \
       package/feeds/packages/ifstat package/feeds/packages/kadnode package/feeds/packages/natmap \
       package/feeds/packages/oscam package/feeds/packages/rsyslog package/feeds/packages/mutt \
       package/feeds/packages/tvheadend package/feeds/packages/parted package/feeds/packages/qemu 2>/dev/null || true
find package/feeds -maxdepth 4 -type d \( -name 'asterisk' -o -name 'nginx' -o -name 'gensio' -o -name 'ifstat' \
       -o -name 'kadnode' -o -name 'natmap' -o -name 'oscam' -o -name 'rsyslog' -o -name 'mutt' \
       -o -name 'tvheadend' -o -name 'parted' -o -name 'qemu' \) \
       -exec rm -rf {} + 2>/dev/null || true
find package/feeds -maxdepth 4 -type l \( -name '*asterisk*' -o -name '*nginx*' -o -name '*gensio*' -o -name '*ifstat*' \
       -o -name '*kadnode*' -o -name '*natmap*' -o -name '*oscam*' -o -name '*rsyslog*' -o -name '*mutt*' \
       -o -name '*tvheadend*' -o -name '*parted*' -o -name '*qemu*' \) \
       -delete 2>/dev/null || true
[ -d package/feeds/packages/asterisk ] && echo "!! package/feeds 仍有 asterisk" || echo "    ✓ package/feeds 已清理"

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

# ============================================================
# 递归依赖自愈函数：从编译日志中识别递归包并删除
#   形式 A（depends 环）：feeds/.../Config.in:NN: symbol X depends on Y
#   形式 B（select 环）：symbol PACKAGE_xxx is selected by ...（无 feeds 路径行）
# 返回：0=已删除至少一个包；1=未能定位/删除
# ============================================================
heal_recursive() {
  local logfile="$1" curtarget="$2" removed="" p pkg hits
  # A) feeds Config.in 路径（depends 环里 symbol 所在的包目录）
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    pkg="$(basename "$p")"
    rm -rf "$p" 2>/dev/null || true
    find package/feeds -maxdepth 4 \( -type d -o -type l \) -name "$pkg" \
      -exec rm -rf {} + 2>/dev/null || true
    removed="$removed $p"
  done < <(grep -oE 'feeds/[A-Za-z0-9_./-]+/Config[a-z0-9-]*\.in' "$logfile" 2>/dev/null \
             | sed -E 's|/Config.*||' | sort -u)
  # B) symbol PACKAGE_xxx（select 环，如 natmap；错误行不带 feeds 路径）
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    [ "$pkg" = "$curtarget" ] && continue   # 绝不删除正在编译的目标自身
    hits="$(find feeds package/feeds -maxdepth 5 \( -type d -o -type l \) -name "$pkg" 2>/dev/null)"
    if [ -n "$hits" ]; then
      while IFS= read -r h; do rm -rf "$h" 2>/dev/null || true; done <<EOF
$hits
EOF
      removed="$removed $pkg(find)"
    fi
  done < <(grep -oE 'symbol PACKAGE_[A-Za-z0-9_.+-]+' "$logfile" 2>/dev/null \
             | sed 's/symbol PACKAGE_//' | sort -u)
  if [ -n "$removed" ]; then
    echo "$removed"
    return 0
  fi
  return 1
}

echo "==> [4/4] 逐个编译插件（递归依赖自动自愈，每包最多 30 轮）"
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
  healed=0
  while :; do
    rm -f tmp/.config-package.in
    if timeout 2400 make -j"$(nproc)" "package/$target/compile" V=s >"/tmp/build-$target.log" 2>&1; then
      if [ "$healed" -gt 0 ]; then
        echo "    ✓ $target 成功（经 $healed 轮递归自愈）"
      else
        echo "    ✓ $target 成功"
      fi
      break
    fi
    # 失败：递归错误才自愈，其余错误直接标记失败
    if ! grep -q "recursive dependency detected" "/tmp/build-$target.log" 2>/dev/null; then
      echo "    ✗ $target 失败（非递归错误，日志尾部见下）"
      tail -n 15 "/tmp/build-$target.log"
      break
    fi
    healed=$((healed + 1))
    if [ "$healed" -gt 30 ]; then
      echo "    ✗ $target 失败（递归自愈超过 30 轮，日志尾部见下）"
      tail -n 20 "/tmp/build-$target.log"
      break
    fi
    removed="$(heal_recursive "/tmp/build-$target.log" "$target")"
    if [ $? -ne 0 ] || [ -z "$removed" ]; then
      echo "    ✗ $target 失败（递归但无法定位删除，日志尾部见下）"
      tail -n 20 "/tmp/build-$target.log"
      break
    fi
    echo "    ↻ 第 $healed 轮自愈: 删除递归包:$removed"
  done
done

echo "==> 收集产物 -> $OUT_DIR"
find bin/packages -type f \( -name '*.ipk' -o -name '*.apk' \) -exec cp -n {} "$OUT_DIR/" \; 2>/dev/null
COUNT="$(ls -1 "$OUT_DIR" | wc -l)"
echo "    共收集 $COUNT 个包文件"
[ "$COUNT" -gt 0 ] || { echo "!! 未收集到任何包"; exit 1; }
echo "==> 完成"
