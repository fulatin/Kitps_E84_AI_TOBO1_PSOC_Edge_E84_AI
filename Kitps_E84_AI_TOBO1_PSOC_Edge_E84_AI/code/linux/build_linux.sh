#!/usr/bin/env bash
#
# build_linux.sh — 在 Linux 下构建本仓库的三块目标板固件
#
# 与 build_all.bat（Windows 版）对应。默认在**临时副本**中构建，不改动仓库源码；
# 加 --apply 才会把补丁永久写入 STM32H7 源码。
#
# 用法：
#   ./build_linux.sh                # 构建 STM32H7（其余目标给出提示）
#   ./build_linux.sh stm32          # 只构建 STM32H7
#   ./build_linux.sh esp32          # 构建 ESP32（需已安装 ESP-IDF）
#   ./build_linux.sh pse84          # 打印 PSE84E 的构建路径说明
#   ./build_linux.sh --apply        # 先把补丁写入仓库，再就地构建 STM32H7
#
# 已验证环境：Arch Linux + arm-none-eabi-gcc 15.3 + cmake 4.4 + ninja 1.13
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_DIR="$(dirname "$SCRIPT_DIR")"
PATCH="$SCRIPT_DIR/stm32h7-linux.patch"
OUT_DIR="$SCRIPT_DIR/out"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'
ok()   { echo "${GRN}(OK)${RST}   $*"; }
fail() { echo "${RED}(FAIL)${RST} $*"; }
skip() { echo "${YEL}(SKIP)${RST} $*"; }
info() { echo "       $*"; }

APPLY=0
TARGETS=()
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        stm32|esp32|pse84) TARGETS+=("$arg") ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "未知参数: $arg"; exit 2 ;;
    esac
done
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(stm32 esp32 pse84)

# ---------------------------------------------------------------- 工具链检查
check_toolchain() {
    local missing=0
    for t in arm-none-eabi-gcc cmake ninja; do
        if command -v "$t" >/dev/null 2>&1; then
            ok "$t -> $(command -v "$t")"
        else
            fail "$t 未安装"; missing=1
        fi
    done
    [ $missing -eq 0 ] || {
        echo
        info "安装示例："
        info "  Arch   : sudo pacman -S arm-none-eabi-gcc arm-none-eabi-newlib cmake ninja"
        info "  Debian : sudo apt install gcc-arm-none-eabi cmake ninja-build"
        info "  通用   : https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads"
        exit 1
    }
}

# ------------------------------------------------------------------- STM32H7
build_stm32() {
    echo "==> [1/3] STM32H743ZIT6"
    local SRC
    if [ "$APPLY" -eq 1 ]; then
        SRC="$CODE_DIR/STM32H7"
        if grep -q 'DataLogger' "$SRC/CMakeLists.txt"; then
            if ! ( cd "$CODE_DIR" && patch -p1 --forward < "$PATCH" ); then
                fail "补丁写入失败"; return 1
            fi
            ok "补丁已写入 $SRC"
        else
            ok "补丁已应用，跳过"
        fi
    else
        SRC="$OUT_DIR/src/STM32H7"
        rm -rf "$SRC"; mkdir -p "$(dirname "$SRC")"
        cp -r "$CODE_DIR/STM32H7" "$SRC"
        if ! patch -p1 -d "$OUT_DIR/src" --forward < "$PATCH" >/dev/null; then
            fail "临时副本打补丁失败"; return 1
        fi
        ok "临时副本已打补丁: $SRC"
    fi

    local B="$OUT_DIR/stm32-build"
    rm -rf "$B"; mkdir -p "$B"
    if ! cmake -S "$SRC" -B "$B" -G Ninja >"$B/configure.log" 2>&1; then
        fail "CMake 配置失败，见 $B/configure.log"; return 1
    fi
    if ! ninja -C "$B" >"$B/build.log" 2>&1; then
        fail "编译失败，见 $B/build.log"
        grep -E "error:|FAILED" "$B/build.log" | head -20
        return 1
    fi

    cp "$B/STM32H7_RadarMaster.hex" "$OUT_DIR/STM32H7_Main.hex"
    cp "$B/STM32H7_RadarMaster.elf" "$OUT_DIR/STM32H7_Main.elf"
    cp "$B/STM32H7_RadarMaster.bin" "$OUT_DIR/STM32H7_Main.bin"
    ok "构建成功"
    arm-none-eabi-size "$B/STM32H7_RadarMaster.elf" | tail -1
    info "产物: $OUT_DIR/STM32H7_Main.{hex,elf,bin}"
}

# --------------------------------------------------------------------- ESP32
build_esp32() {
    echo "==> [2/3] ESP32-S3 (OV2640 视觉跟踪)"
    if ! command -v idf.py >/dev/null 2>&1; then
        skip "未检测到 ESP-IDF 环境（idf.py 不在 PATH）"
        info "ESP-IDF 原生支持 Linux，安装后 source export.sh 即可："
        info "  git clone -b v5.3.2 --recursive https://github.com/espressif/esp-idf.git ~/esp/esp-idf"
        info "  cd ~/esp/esp-idf && ./install.sh esp32s3 && . ./export.sh"
        info "  sdkconfig 中目标为 esp32s3，IDF 版本 5.3.2"
        return 0
    fi
    info "idf.py: $(command -v idf.py)"
    if [ ! -e "$CODE_DIR/ESP32_ov2640/components/esp_camera/CMakeLists.txt" ]; then
        fail "components/esp_camera 为空（仓库中是一个无 .gitmodules 映射的孤立 gitlink）"
        info "修复：把 esp32-camera 组件放到该目录，例如"
        info "  git clone https://github.com/espressif/esp32-camera \\"
        info "      $CODE_DIR/ESP32_ov2640/components/esp_camera"
        return 1
    fi
    ( cd "$CODE_DIR/ESP32_ov2640" && idf.py build ) \
        && { cp build/ESP32_ov2640.bin "$OUT_DIR/ESP32_Tracker.bin" 2>/dev/null || true; ok "构建成功"; } \
        || { fail "编译失败"; return 1; }
}

# --------------------------------------------------------------------- PSE84E
# 走官方 ModusToolbox 工程（见 linux/LINUX_BUILD.md 第 2.2 节）。
# 要点：① 逐个子工程跑 getlibs；② CY_COMPILER_GCC_ARM_DIR 传 /usr（MTB 会自己追加 /bin）
build_pse84() {
    echo "==> [3/3] PSE84E (PSOC Edge E84 + Ethos-U55 NPU)"
    local APP="$CODE_DIR/../Workspace/PSOC_Edge_Machine_Learning_DEEPCRAFT_Deploy_Vision"
    if [ ! -d "$APP" ]; then
        fail "找不到 MTB 工程: $APP"; return 1
    fi
    : "${CY_TOOLS_PATHS:=/opt/ModusToolbox/tools_3.9}"
    export CY_TOOLS_PATHS
    if [ ! -d "$CY_TOOLS_PATHS" ]; then
        skip "未找到 ModusToolbox: $CY_TOOLS_PATHS"
        info "设置 CY_TOOLS_PATHS 指向 tools_X.Y 目录后重试"
        return 0
    fi
    info "ModusToolbox: $CY_TOOLS_PATHS"

    # 1) 逐个子工程拉取依赖（应用级 getlibs 会漏掉 proj_cm33_s）
    for d in proj_cm33_s proj_cm33_ns proj_cm55; do
        if ! ( cd "$APP" && make -C "$d" getlibs ) >"$OUT_DIR/mtb-$d-getlibs.log" 2>&1; then
            fail "$d getlibs 失败，见 $OUT_DIR/mtb-$d-getlibs.log"
            info "若报 'core-make recipe-make not found'：BSP 未被 MTB 托管，见 LINUX_BUILD.md 第 2.2 节"
            return 1
        fi
        ok "$d getlibs"
    done

    # 2) 构建（编译器目录传 /usr，MTB 内部会拼 /bin）
    if ! ( cd "$APP" && make build CY_COMPILER_GCC_ARM_DIR=/usr ) \
            >"$OUT_DIR/mtb-build.log" 2>&1; then
        if grep -q "Build complete" "$OUT_DIR/mtb-build.log"; then
            ok "三核编译链接成功（仅后处理 Combine-Sign 失败）"
            info "Combine-Sign 需要 ModusToolbox Setup 安装 EdgeProtect Secure Suite，不影响编译产物"
        else
            fail "构建失败，见 $OUT_DIR/mtb-build.log"
            tail -20 "$OUT_DIR/mtb-build.log"
            return 1
        fi
    else
        ok "构建成功"
    fi
    for c in proj_cm33_s proj_cm33_ns proj_cm55; do
        local b="$APP/$c/build/APP_KIT_PSE84_AI/Debug/$c.bin"
        [ -f "$b" ] && info "$c.bin $(stat -c%s "$b") B"
    done
    return 0
}

main() {
    echo "========================================"
    echo "  多板协作目标跟踪系统 — Linux 编译脚本"
    echo "========================================"
    mkdir -p "$OUT_DIR"
    check_toolchain
    echo
    local rc=0
    for t in "${TARGETS[@]}"; do
        case "$t" in
            stm32) build_stm32 || rc=1 ;;
            esp32) build_esp32 || rc=1 ;;
            pse84) build_pse84 ;;
        esac
        echo
    done
    echo "========================================"
    [ $rc -eq 0 ] && ok "完成" || fail "有目标未通过，见上方输出"
    return $rc
}

main
