#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================
# patch_sdk_cycles.py — 给 SDK 的 include/toplevel.mk 打补丁
#
# 根因：ImmortalWrt master feed 快照里，若干官方包（curl/netatalk/fwupd/
#   dovecot/postfix 等）为支持 glibc，对条件依赖生成 Kconfig 守卫：
#       depends on !(子特性 && USE_GLIBC) || USE_GLIBC
#   该守卫使主包反向 depends 子特性，而子特性被 `if 主包` 包裹 -> 静态依赖环。
#   我们使用 musl（USE_GLIBC=n），此表达式恒真、本不构成约束，但 kconfig
#   建立静态图时仍报 recursive dependency。
#
# 修复：在 prepare-tmpinfo 生成 tmp/.config-*.in 的命令之后追加 sed -i，
#   删除这些 musl 下恒真的守卫行。无论 defconfig 还是编译循环重建 tmp，
#   都会自动破环。诊断 run 实测：删除 157 行后 Kconfig 图完全干净。
#
# 用法: python3 patch_sdk_cycles.py <SDK_DIR>
# ============================================================
import sys, os

if len(sys.argv) < 2:
    print("用法: python3 patch_sdk_cycles.py <SDK_DIR>")
    sys.exit(1)

sdk = sys.argv[1]
mk = os.path.join(sdk, "include", "toplevel.mk")

if not os.path.isfile(mk):
    print("!! 未找到 %s" % mk)
    sys.exit(2)

with open(mk, encoding="utf-8") as fh:
    c = fh.read()

# 幂等：破环 sed（含 USE_GLIBC/d）已存在
if "USE_GLIBC/d" in c:
    print("toplevel.mk 已打过破环补丁，跳过")
    sys.exit(0)

# sed 删除程序（ERE；字面括号/竖线需转义）
SEDPROG = r"/depends on !\(.*USE_GLIBC.*\) \|\| USE_GLIBC/d"

# 锚点：prepare-tmpinfo 中 for 循环生成命令的错误处理块结尾 + 续行反斜杠
#   ... || { rm -f "$$t"; echo "Failed to build $$t"; false; break; }; \
anchor = 'echo "Failed to build $$t"; false; break; }; \\'
if anchor not in c:
    print("!! 在 toplevel.mk 中未找到锚点（prepare-tmpinfo 生成块）")
    sys.exit(2)

# 在续行反斜杠前追加独立的 sed -i 破环步骤（保留原错误处理，不引入行内注释）
patched_anchor = (
    'echo "Failed to build $$t"; false; break; }; '
    "sed -i -E '" + SEDPROG + "' \"$$t\"; \\"
)

c2 = c.replace(anchor, patched_anchor, 1)
if c2 == c:
    print("!! 替换失败")
    sys.exit(2)

with open(mk, "w", encoding="utf-8") as fh:
    fh.write(c2)

print("✓ 已 patch toplevel.mk：musl glibc 守卫破环器安装完成")
