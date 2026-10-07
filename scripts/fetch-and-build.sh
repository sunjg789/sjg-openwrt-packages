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

# 脚本自身所在目录（必须在任何 cd 之前解析为绝对路径，否则 cd 进 SDK 后
# 相对路径会错误指向 SDK 内的 scripts）
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# 破环补丁：patch include/toplevel.mk，使 prepare-tmpinfo 每次重建
# tmp/.config-package.in 时自动过滤 musl 下恒真的 glibc 条件依赖守卫
# （master feed 快照 Kconfig 静态环的根因；诊断实测删 157 行后图干净）。
# SELF_DIR 已在脚本开头（cd 之前）解析为绝对路径。
if command -v python3 >/dev/null 2>&1; then
  python3 "$SELF_DIR/patch_sdk_cycles.py" "$SDK_DIR" \
    || echo "    (破环补丁警告，继续，靠后续自愈兜底)"
else
  echo "    (无 python3，跳过 toplevel.mk 破环补丁)"
fi

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

# 克隆/复制完成后的最终防线：第三方合集（small-package 等）可能以不同目录名
# 携带同一递归包。natmap 已知两个变体目录：官方 feeds 的 net/natmap 与 kenzok8
# 合集的 openwrt-natmap（包名均为 natmap，Kconfig 自选择递归）。
echo "==> 克隆后最终扫描递归包（含目录名变体）"
rm -rf package/natmap package/openwrt-natmap package/luci-app-natmap 2>/dev/null || true
find package feeds -maxdepth 6 \( -type d -o -type l \) \
   \( -name 'natmap' -o -name 'openwrt-natmap' \) \
   -exec rm -rf {} + 2>/dev/null || true
for r in asterisk nginx gensio ifstat kadnode natmap openwrt-natmap oscam \
         rsyslog mutt tvheadend parted qemu; do
  find package feeds -maxdepth 6 \( -type d -o -type l \) -name "$r" \
    -exec rm -rf {} + 2>/dev/null || true
done

echo "==> 生成默认 .config（先清 tmp 强制全量重扫，纳入全部克隆包）"
# feeds install 阶段生成过 tmp（不含随后克隆的第三方包）；必须彻底删除，
# 否则 defconfig 复用陈旧 .packageinfo，编译时 package/<克隆包>/compile 目标缺失
# （报 No rule to make target）。rm -rf tmp 后 defconfig 完整重扫 package/ 根，
# 破环补丁在 .config-package.in 生成时自动过滤 glibc 守卫。
rm -rf tmp
export TERM=xterm
make defconfig >/tmp/defconfig.log 2>&1 || {
  echo "!! defconfig 失败（多为某插件 Kconfig 递归依赖，见尾部）"
  tail -n 20 /tmp/defconfig.log
  exit 1
}

# ============================================================
# 诊断模式（DIAGNOSE=1）：强制重建「含全部第三方克隆包」的元数据索引，
# 完整打印 Kconfig 递归依赖块 + 每个报错行的实际 Kconfig 文本后退出
# （不实际编译，几分钟出结果）。
# 背景：上面的 defconfig 复用了第三方包克隆前生成的陈旧 tmp/.config-package.in
# （不含第三方包，所以不报错）；而编译单个包会删除并重建该索引、纳入全部
# 第三方包，Kconfig 递归环才在此刻暴露。
# ============================================================

# dump_recursive <log>：打印递归块 + 报错行（path:line）前后实际文件内容
dump_recursive() {
  local log="$1" blk
  # 只提取递归块文本，定位也只在块内做，避免混入 conf 处理时的其他 path:line
  blk="$(awk '/recursive dependency detected!/{n++; print "\n########## 递归块 #" n " ##########"; p=1}
       p{print}
       /For a resolution/{if(p){print "########## 块 #" n " 结束 ##########"}; p=0}' "$log")"
  printf '%s\n' "$blk"
  echo "----- 报错行实际 Kconfig 内容（前6行/后6行，=> 标记报错行）-----"
  printf '%s\n' "$blk" \
    | grep -oE '(tmp/\.config-package\.in|feeds/[A-Za-z0-9_./-]+/Config[a-z0-9-]*\.in|Config-build\.in):[0-9]+' 2>/dev/null \
    | sort -u | while read -r loc; do
      ln="${loc##*:}"; f="${loc%:[0-9]*}"
      if [ ! -f "$f" ]; then echo "  [$loc] 文件不存在"; continue; fi
      s=$((ln-6)); [ "$s" -lt 1 ] && s=1
      e=$((ln+6))
      echo "  >>> $loc"
      i=$s
      while IFS= read -r line; do
        if [ "$i" -eq "$ln" ]; then printf '      => %s\t%s\n' "$i" "$line"; else printf '         %s\t%s\n' "$i" "$line"; fi
        i=$((i+1))
      done < <(sed -n "${s},${e}p" "$f")
    done
}

if [ "${DIAGNOSE:-0}" = "1" ]; then
  echo "########## [DIAG] 诊断开始：强制重建 package 元数据（含第三方包） ##########"
  echo "==> package/ 根目录清单（package/feeds=官方软链，其余=克隆的第三方包）："
  find package -maxdepth 1 -mindepth 1 | sort
  rm -f tmp/.config-package.in tmp/.packageinfo tmp/.packagedeps
  echo "==> 探测 1/2：make package/OpenClash/compile V=s（取配置阶段）"
  make package/OpenClash/compile V=s >/tmp/diag.log 2>&1 || true
  if grep -q "recursive dependency detected" /tmp/diag.log; then
    dump_recursive /tmp/diag.log
  else
    # 不逐个 compile（那会真实编译、极慢）；重建索引后跑 defconfig 即可一次性
    # 触发 conf 的全量递归检测（defconfig 只做配置，不编译包，几分钟完成）。
    echo "==> 探测 2/2：OpenClash 未触发，重建索引后 make defconfig（不编译，取全部环）"
    rm -f tmp/.config-package.in tmp/.packageinfo tmp/.packagedeps
    make defconfig V=s >/tmp/diag-def.log 2>&1 || true
    if grep -q "recursive dependency detected" /tmp/diag-def.log; then
      dump_recursive /tmp/diag-def.log
    else
      echo "==> 未检测到递归依赖（Kconfig 图干净）"
    fi
  fi
  # ---- 破环试验：musl 下删除恒真 glibc 守卫，验证剩余环 ----
  echo "===== [DIAG] Config-build.in base-files/busybox 完整生成块（1999-2100）====="
  sed -n '1999,2100p' Config-build.in 2>/dev/null
  if [ -f tmp/.config-package.in ]; then
    n0=$(grep -cE 'depends on !\(.*USE_GLIBC.*\) \|\| USE_GLIBC' tmp/.config-package.in || true)
    sed -i -E '/depends on !\(.*USE_GLIBC.*\) \|\| USE_GLIBC/d' tmp/.config-package.in
    touch tmp/.config-package.in
    echo "===== [DIAG] 已删除 musl 下恒真 glibc 守卫行数: $n0；重新 defconfig 验证 ====="
    make defconfig >/tmp/diag-cyc.log 2>&1 || true
    if grep -q "recursive dependency detected" /tmp/diag-cyc.log; then
      echo "----- 删除 glibc 守卫后仍存在的环 -----"
      awk '/recursive dependency detected!/{n++; print "\n### 剩余环 #" n " ###"; p=1} p{print} /For a resolution/{p=0}' /tmp/diag-cyc.log
    else
      echo "----- 删除 glibc 守卫后 Kconfig 图干净（破环成功）-----"
    fi
  fi
  echo "########## [DIAG] 诊断结束 ##########"
  exit 0
fi

# ============================================================
# 递归依赖自愈函数：从编译日志中识别递归包并删除
#   形式 A（depends 环）：feeds/.../Config.in:NN: symbol X depends on Y
#   形式 B（select 环）：symbol PACKAGE_xxx is selected by ...（无 feeds 路径行）
# 返回：0=已删除至少一个包；1=未能定位/删除
# ============================================================
heal_recursive() {
  local logfile="$1" curtarget="$2" removed="" p pkg bn
  # 已知 feeds Kconfig bug 包（静态阶段已删，此处仅兜底）；其余官方 feeds 包全部受保护。
  local BUGFEEDS=" asterisk nginx gensio ifstat kadnode natmap oscam rsyslog mutt tvheadend parted qemu "
  # 只截取递归错误块（"recursive dependency detected!" → "For a resolution"）
  local block
  block="$(awk '/recursive dependency detected!/{f=1} f{print} /For a resolution/{f=0}' "$logfile" 2>/dev/null)"
  # A) feeds Config.in 路径：仅当包属于已知 feeds bug 名单才删除，否则保护跳过
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    pkg="$(basename "$p")"
    case "$BUGFEEDS" in
      *" $pkg "*)
        rm -rf "$p" 2>/dev/null || true
        find package/feeds -maxdepth 4 \( -type d -o -type l \) -name "$pkg" \
          -exec rm -rf {} + 2>/dev/null || true
        removed="$removed $p"
        ;;
      *)
        echo "    [保护] 跳过官方 feeds 包（依赖链无辜节点）: $pkg"
        ;;
    esac
  done < <(printf '%s\n' "$block" | grep -oE 'feeds/[A-Za-z0-9_./-]+/Config[a-z0-9-]*\.in' 2>/dev/null \
             | sed -E 's|/Config.*||' | sort -u)
  # B) symbol PACKAGE_xxx：
  #    - 已知 feeds bug → 删 feeds / package/feeds
  #    - 第三方克隆包  → 只在 package/ 根定位删除（按目录名或 Makefile 中 define Package/<pkg>）
  #    - 其余官方核心包（busybox/base-files/curl/dovecot...）→ 一律不删
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    [ "$pkg" = "$curtarget" ] && continue   # 绝不删除正在编译的目标自身
    case "$BUGFEEDS" in
      *" $pkg "*)
        find feeds package/feeds -maxdepth 6 \( -type d -o -type l \) \
          \( -name "$pkg" -o -name "openwrt-$pkg" \) -exec rm -rf {} + 2>/dev/null || true
        removed="$removed $pkg(feed)"
        ;;
    esac
    # 第三方克隆包：package/ 根，精确目录名 / openwrt 变体 / Makefile 包名匹配
    if [ -d "package/$pkg" ] || [ -d "package/openwrt-$pkg" ]; then
      rm -rf "package/$pkg" "package/openwrt-$pkg" 2>/dev/null || true
      removed="$removed $pkg(3rd)"
    else
      for d in package/*/; do
        bn="$(basename "$d")"
        [ "$bn" = "feeds" ] && continue
        # define Package/<pkg> 行尾才算包定义（排除 /install、/config 等子段）
        if grep -qsE "define Package/$pkg([^A-Za-z0-9_./+-]|$)" "$d/Makefile" 2>/dev/null; then
          rm -rf "$d" 2>/dev/null || true
          removed="$removed $bn->$pkg(3rd)"
          break
        fi
      done
    fi
  done < <(printf '%s\n' "$block" | grep -oE 'symbol PACKAGE_[A-Za-z0-9_.+-]+' 2>/dev/null \
             | sed 's/symbol PACKAGE_//' | sort -u)
  if [ -n "$removed" ]; then
    echo "$removed"
    return 0
  fi
  return 1
}

# ===== 预编译 Rust host 工具链（含完整 LLVM）=====
# 首次编译 rust 程序（shadowsocks-rust / tuic-client / shadow-tls）时，构建系统需先从源码
# 编译 host 版 rustc + LLVM（约 3700 个目标，4 核 runner 约 80–150 分钟）。若不预热，该耗时
# 会落到前几个触发 Rust 的包上，在单包 timeout(40min) 内编不完 LLVM 而被误判失败
# （run #69 已证实：openclash/passwall 各耗 40 分钟只编完一半 LLVM，到 passwall2 才编完）。
NEED_RUST=0
if grep -qE 'CONFIG_PACKAGE_(shadowsocks-rust|tuic-client|shadow-tls)=y' .config 2>/dev/null; then
  NEED_RUST=1
fi
RUST_HOST_DIR=""
for d in package/feeds/packages/rust package/feeds/packages/lang/rust; do
  if [ -d "$d" ]; then RUST_HOST_DIR="$d"; break; fi
done
if [ "$NEED_RUST" = "1" ] && [ -n "$RUST_HOST_DIR" ]; then
  echo "==> 预编译 Rust host（含 LLVM，首次约 80–150 分钟，一次性完成避免分摊到单包超时）"
  if timeout 10800 make -j"$(nproc)" "$RUST_HOST_DIR/host/compile" V=s >/tmp/build-rust-host.log 2>&1; then
    echo "    ✓ rust/host 工具链就绪"
  else
    echo "    ! rust/host 预编译未在 180 分钟内完成，日志尾部："
    tail -n 15 /tmp/build-rust-host.log
    echo "    ! 继续逐个编译（若仍因 rust 失败，请增大预热 timeout 或减少 Rust 内核）"
  fi
else
  echo "==> 未启用 Rust 内核（rust feed: ${RUST_HOST_DIR:-无}），跳过 rust/host 预编译"
fi

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
  healed=0; reindex=0
  while :; do
    # 不再每轮删除 tmp 索引：循环前 defconfig 已全量纳入所有克隆包，复用索引
    # 可使每个包快速编译（每轮强删会导致全量重建 tmp，单包耗时 8-13 分钟）。
    if timeout 3600 make -j"$(nproc)" "package/$target/compile" V=s >"/tmp/build-$target.log" 2>&1; then
      if [ "$healed" -gt 0 ]; then
        echo "    ✓ $target 成功（经 $healed 轮递归自愈）"
      else
        echo "    ✓ $target 成功"
      fi
      break
    fi
    # 1) 递归依赖错误：定位删除递归包 → 重建索引 → 重试
    if grep -q "recursive dependency detected" "/tmp/build-$target.log" 2>/dev/null; then
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
      # 目录已改动，彻底重建 tmp 索引（破环补丁在重建时自动生效）
      rm -rf tmp; make defconfig >/tmp/reindex.log 2>&1 || true
      continue
    fi
    # 2) 索引未纳入该包（No rule to make target）：重建 tmp 后重试，限 2 次
    if grep -q "No rule to make target" "/tmp/build-$target.log" 2>/dev/null; then
      reindex=$((reindex + 1))
      if [ "$reindex" -gt 2 ]; then
        echo "    ✗ $target 失败（重建索引后仍无编译目标，日志尾部见下）"
        tail -n 15 "/tmp/build-$target.log"
        break
      fi
      echo "    ↻ 索引未纳入 $target，重建 tmp（第 $reindex 次）后重试"
      rm -rf tmp
      make defconfig >/tmp/reindex.log 2>&1 || tail -n 15 /tmp/reindex.log
      continue
    fi
    # 3) 其余错误：直接标记失败
    echo "    ✗ $target 失败（非递归错误，日志尾部见下）"
    tail -n 15 "/tmp/build-$target.log"
    break
  done
done

echo "==> 收集产物 -> $OUT_DIR"
# 只收第三方插件（克隆在 package/ 根目录 → bin/packages/base feed）与非官方自定义 feed；
# 官方 packages/luci feed 的包（上千个、含数百 MB x86 用不到的无线 firmware、
# kmod、基础库、docker 等）由 Image Builder 环境与官方源提供，不收进本库。
if [ -d bin/packages/base ]; then
  find bin/packages/base -type f \( -name '*.ipk' -o -name '*.apk' \) \
    -exec cp -n {} "$OUT_DIR/" \; 2>/dev/null
fi
for f in bin/packages/*/; do
  bn="$(basename "$f")"
  case "$bn" in
    base|packages|luci|telephony|routing|freifunk)
      # 官方 feed：跳过（base 已在上面收集）
      ;;
    *)
      find "$f" -type f \( -name '*.ipk' -o -name '*.apk' \) \
        -exec cp -n {} "$OUT_DIR/" \; 2>/dev/null
      ;;
  esac
done
# 双保险：无论哪个 feed，firmware/kmod 一律剔除（x86 软路由不需要，且 kmod 须与内核同源）
find "$OUT_DIR" -type f \( -name '*-firmware-*' -o -name 'linux-firmware-*' -o -name 'kmod-*' \) \
  -delete 2>/dev/null || true
COUNT="$(find "$OUT_DIR" -maxdepth 1 -type f \( -name '*.ipk' -o -name '*.apk' \) | wc -l)"
echo "    共收集 $COUNT 个包文件（仅第三方 feed，已排除 firmware/kmod）"
[ "$COUNT" -gt 0 ] || { echo "!! 未收集到任何包（base feed 缺失？）"; exit 1; }
echo "==> 核心插件硬校验（缺失则判失败，避免 job 假成功）"
MISSING=""
for core in luci-app-openclash luci-app-passwall luci-app-passwall2 luci-app-lucky \
            luci-app-diskman luci-app-dockerman luci-app-adguardhome; do
  if ! ls "$OUT_DIR"/${core}_* >/dev/null 2>&1; then
    MISSING="$MISSING $core"
  fi
done
if [ -n "$MISSING" ]; then
  echo "!! 核心插件主包缺失:$MISSING"
  echo "!! 请向上查看对应包的编译失败日志（多为 Kconfig 递归或依赖缺失）"
  exit 1
fi
echo "    ✓ 7 个核心插件主包齐全"
echo "==> 完成"
