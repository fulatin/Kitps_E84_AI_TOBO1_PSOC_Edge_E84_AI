# 构建系统分析与 Linux 构建（实测报告）

> **结论**：三块目标板**均已在本机 Linux 上实测编译通过**。
>
> | 目标 | 构建系统 | Linux 结果 | 产物 |
> |---|---|---|---|
> | **STM32H743ZIT6**（主控） | 独立 CMake + Ninja | ✅ 通过 | `STM32H7_Main.hex` 161,762 B |
> | **ESP32-S3 ×2**（视觉） | ESP-IDF 6.0.2（`idf.py`） | ✅ 通过 | `ESP32_ov2640.bin` 1,034,336 B |
> | **PSE84E**（NPU 识别） | ModusToolbox 3.9（make） | ✅ 三核通过 | 见 §3.3 |
>
> 验证环境：Arch Linux / `arm-none-eabi-gcc 15.3.1` / CMake 4.4.3 / Ninja 1.13.2 /
> ESP-IDF 6.0.2（`/opt/esp-idf`）/ ModusToolbox 3.9（`/opt/ModusToolbox/tools_3.9`）。

本仓库**没有统一的顶层构建**。`code/build_all.bat` 只是 Windows 批处理编排脚本，
按顺序调用三个互相独立的子构建系统。

---

## 1. 构建系统总览

```
code/
├── build_all.bat                 # 仅 Windows 的编排脚本（非构建系统本体）
├── STM32H7/CMakeLists.txt        # ① 独立 CMake 交叉编译（HAL/CMSIS 内置，无外部 SDK 依赖）
├── PSE84E_Project/CMakeLists.txt # ② 独立 CMake 交叉编译（照 CAT1/PDL 布局手写，已废弃）
├── ESP32_ov2640/CMakeLists.txt   # ③ ESP-IDF 工程
└── linux/                        # 本次新增：三目标 Linux 构建脚本 + 补丁 + 本文档

Workspace/
└── PSOC_Edge_Machine_Learning_DEEPCRAFT_Deploy_Vision/
    ├── Makefile                  # ④ ModusToolbox APPLICATION（MTB_PROJECTS 三核）
    ├── common_app.mk / common.mk
    └── proj_cm33_s / proj_cm33_ns / proj_cm55
```

---

## 2. 逐目标实测

### 2.1 STM32H743ZIT6 —— ✅ 通过（4 处最小改动）

HAL/CMSIS、链接脚本、启动文件都在仓库内，不依赖外部 SDK。Linux 下的 4 个阻断点：

| # | 位置 | 问题 | 修法 |
|---|---|---|---|
| 1 | `CMakeLists.txt:7-11` | 工具链路径写死 `C:/Users/37966/...` + `.exe`；Linux 下 `C:/...` 是相对路径，CMake 把编译器解析成 `C` | 改用 PATH 里的 `arm-none-eabi-gcc`（无 `.exe`） |
| 2 | `CMakeLists.txt:23,33` | 写 `DataLogger`，磁盘上是 `Datalogger` | 改成 `Datalogger` |
| 3 | `CMakeLists.txt:33` | glob `Drivers/*.S`，磁盘上是 `startup_stm32h743xx.s`（小写） | 改成 `Drivers/*.S Drivers/*.s` |
| 4 | `Drivers/uart.h` | `UART_StartRxIT()` 在 `uart.c:26` 有定义但无原型，`Core/system.c:65` 直接调用 | 在 `uart.h` 补原型 |

> **#2/#3 是最隐蔽的坑**。CMake 官方文档：
> *"On Windows and macOS, globbing is case-insensitive … On other platforms, globbing is case-sensitive."*
> 所以 Windows 上一切正常，Linux 上 `logger.h` 找不到、启动文件漏编译。
> 其中 **#3 更危险**：启动文件没编进去 → `Reset_Handler` 未定义 → 配合 `--gc-sections`
> **链接出一个 `text=0` 的空固件却报"成功"**（`.bin` 0 字节）。一定要核对 `arm-none-eabi-size` 和 `.bin` 大小。
>
> **#4 与操作系统无关**，是工具链差异：原用 GCC 12.3/13.2（只报警告），
> GCC 14 起 `-Wimplicit-function-declaration` 默认就是错误。

**实测结果**：
```
text    data     bss     dec     hex
55296   2192    6448   63936    f9c0   → STM32H7_Main.hex 161,762 B / .bin 57,548 B
```

补丁：`linux/stm32h7-linux.patch`；一键构建：`linux/build_linux.sh stm32`。

---

### 2.2 PSE84E —— ✅ 通过（走 ModusToolbox，三核全编）

#### ❌ 先说 `code/PSE84E_Project`：这条路走不通，建议删除

它是**照着 PSoC 6（CAT1）PDL 的目录布局手写**的，与 PSE84 真实平台完全不符：

| 项 | CMakeLists 假设 | PSE84 实际 |
|---|---|---|
| PDL 库名 | `mtb-pdl-cat1` | `mtb-dsl-pse8xxgp`（见 `bsp.mk: BSP_DEVICE_SUPPORT_LIB`） |
| 头文件 | `drivers/include/cy_pdl.h` | `pdl/devices/include/cy_pdl.h` |
| 器件宏 | `-DCYT3BB5CEE` | `PSE846GPS2DBZC4A` / `COMPONENT_CM55` |
| 启动/链接 | `Device/startup_XMC8400E.S` + `XMC8400E_*.ld` | BSP 的 `pse84_ns_cm55.ld` |

该 PDL 未随仓库提供（被 `.gitignore` 忽略）。我实测一路补到
`cycfg_ppc.h` —— 这个文件**不在仓库、也不在任何 SDK 库里**，
由 ModusToolbox 的 Device Configurator **构建时自动生成**。
走通它等于用 CMake 重实现一遍 ModusToolbox，**不值得**。

#### ✅ 正确路径：官方 ModusToolbox 工程

工程本身是官方 `mtb-example-psoc-edge-ml-deepcraft-deploy-vision` 的定制版，
三个核：`proj_cm33_s`（安全 CM33）+ `proj_cm33_ns`（非安全 CM33）+ `proj_cm55`（跑 Ethos-U55 NPU）。

**Linux 下踩到的 4 个坑（按严重程度）**：

**① 【仓库缺陷，最严重】`.gitignore` 把 MTB 依赖清单全部忽略掉了**

根 `.gitignore` 里有 `*.mtb` / `*.mtbx` / `*.cyignore`，导致
`proj_*/deps/*.mtb`（MTB 的依赖声明）和 `bsps/**/.cyignore` **从未进入版本控制**。
没有 `.mtb`，`make getlibs` 就"成功但什么都不下载"（3.8 秒空跑），
随后 `make build` 报：
```
Libraries: "core-make recipe-make" not found. Run "make getlibs" ...
```
> 上游 `mtb-example-...-deploy-vision` 的 `.gitignore` **并不忽略** `*.mtb`（`# bsps/` 还是注释掉的，
> 即 BSP 是要提交的）。我以上游为准恢复了 10 个 `.mtb` 文件，并已修正本仓库 `.gitignore`。

**② 【仓库缺陷】vendored 的 BSP 不完整**

`bsps/TARGET_APP_KIT_PSE84_AI/config/` 只有 `design.cyqspi`，
缺 `design.modus`、`cyreservedresources.list`、`FlashLoaders/`、`GeneratedSource/`。
且 BSP 版本偏旧（core 1.3.0.535）。后果是 MTB 代码生成阶段报：
```
mtbninja: Error: No 'device support library' information found.
mtbninja: Libraries=[NONE]
```
**修法**：用 MTB 自己拉取的官方 BSP 替换（见 §3.3）。

**③ 【环境】MTB 未托管 BSP 时，`libs/mtb.mk` 缺 BSP 依赖的 `SEARCH_*`**

getlibs 生成的 `mtb.mk` 只有应用级库；BSP 级依赖
（`core-make`/`mtb-dsl-pse8xxgp`/`cmsis`/`core-lib`/`mtb-srf`/`mtb-ipc`/
`async-transfer`/`se-rt-services-utils`/`bt-fw-mur-cyw55513`）缺失，
于是 `MTB_TOOLS__CORE_DIR` 为空 → 又是 `core-make recipe-make not found`。
BSP 换成 MTB 托管版本后 getlibs 会自动生成这 9 条（已验证）。

**④ 【环境】应用级 `make getlibs` 会漏掉 `proj_cm33_s`**

应用级 getlibs 只填满了 `proj_cm55`(23 条 SEARCH) 和 `proj_cm33_ns`(6 条)，
`proj_cm33_s` 是 **0 条** → 报 `Libraries: "bsp core-make recipe-make" not found`。
**必须逐个子工程跑 `make -C proj_XX getlibs`**。

**另外两个环境要点**：

* **MTB 3.9 未安装 GCC 编译器包**（`tools_3.9/` 下没有 `gcc/`）。可复用系统工具链：
  传 `CY_COMPILER_GCC_ARM_DIR=/usr` —— 注意**传 `/usr` 而不是 `/usr/bin`**，
  因为 MTB 内部会自己拼 `/bin`（传 `/usr/bin` 会得到 `/usr/bin/bin/arm-none-eabi-gcc`）。
* MTB 的 `lcs-manager-cli` / `mtbgetlibs` 需要写工作区外的 `~/.modustoolbox`
  （本地内容库约 2.7 GB）与 `~/.cache`。

---

### 2.3 ESP32_ov2640 —— ✅ 通过（按 IDF 6.0 适配）

`sdkconfig` 标称目标是 **esp32s3 / ESP-IDF 5.3.2**，本机是 **IDF 6.0.2**，跨了一个大版本，因此需要适配。

**① 【仓库缺陷】`components/esp_camera` 是"孤儿 gitlink"**

它以子模块（`mode 160000`）被记录，但仓库**没有 `.gitmodules`**：
```
$ git submodule status
fatal: no submodule mapping found in .gitmodules for path '.../components/esp_camera'
```
且该 commit 在本地对象库中也不存在 → **任何平台全新 clone 都是空目录**，
而 `main/CMakeLists.txt` 又 `REQUIRES … esp_camera` → 必失败。
`main/idf_component.yml` 也未声明 `espressif/esp32-camera`。

修法：
```bash
git clone https://github.com/espressif/esp32-camera \
    code/ESP32_ov2640/components/esp_camera
```

**② 【IDF 6.0 适配】`driver` 组件被拆分**

`main/CMakeLists.txt` 的 `REQUIRES` 需补（IDF 5.3 起拆出、6.x 起不再由 `driver`/`hal` 转发）：
```cmake
REQUIRES esp_driver_gpio esp_driver_uart esp_driver_i2c esp_driver_ledc esp_hal_uart
```
用到的是 `driver/gpio.h`、`driver/uart.h`、`driver/i2c.h`、`driver/ledc.h`、`hal/uart_types.h`。

**③ 【API 变更】`ESP_IF_WIFI_STA` 在 IDF 6.0 已移除**

`Communication/network_manager.c:115` → 改用 `WIFI_IF_STA`。

**④ 【代码缺陷】缺 `<stdlib.h>`**

`Vision/feature.c`(`abs`)、`tracking/tracker.c`(`malloc`)、`Drivers/ov2640/camera_io.c`(`malloc/free`)
用了 stdlib 函数却没包含头文件。IDF 6.0 用 `-std=gnu23`，GCC 14+ 下隐式声明是**错误**。

**实测结果**：`Project build complete`，
`ESP32_ov2640.bin` = **1,034,336 B**（app 分区 1,536,000 B，余 33%）。

---

## 3. 在 Linux 上构建的操作步骤

### 3.1 STM32H7

```bash
# 依赖（任选其一）
sudo pacman -S arm-none-eabi-gcc arm-none-eabi-newlib cmake ninja   # Arch
sudo apt install gcc-arm-none-eabi cmake ninja-build                # Debian/Ubuntu

cd code/linux
./build_linux.sh stm32        # 在临时副本中打补丁并构建（不改仓库）
./build_linux.sh --apply      # 先把补丁永久写入 code/STM32H7，再就地构建
```
手动等价：
```bash
cd code && patch -p1 < linux/stm32h7-linux.patch
cmake -S STM32H7 -B STM32H7/build -G Ninja && cmake --build STM32H7/build
```

### 3.2 ESP32-S3

```bash
source /opt/esp-idf/export.sh          # ESP-IDF 6.0.2
# 若 components/esp_camera 是空目录：
git clone https://github.com/espressif/esp32-camera \
    code/ESP32_ov2640/components/esp_camera
cd code/ESP32_ov2640 && idf.py build
```
> 若要严格匹配 `sdkconfig`（5.3.2），可改装 ESP-IDF 5.3.2，则 ②③ 两条适配不需要。
> 串口在 Linux 上是 `/dev/ttyUSB*` / `/dev/ttyACM*`，`ESP32烧录备注.txt` 里的 `COM6/COM7` 需替换。

### 3.3 PSE84E（ModusToolbox）

**前置**：ModusToolbox 3.9 装到 `/opt/ModusToolbox/tools_3.9`；
首次需要联网填充本地内容库（约 2.7 GB）：
```bash
LCS=/opt/ModusToolbox/tools_3.9/lcs-manager-cli/bin/lcs-manager-cli
$LCS --add-bsp KIT_PSE84_AI      # 网络抖动时可重复执行，会续传
```

**① 修 BSP**：用 MTB 托管的官方 BSP 替换不完整的 vendored BSP。
最省事的办法是让 project-creator 生成一份标准工程，再把它的 `bsps/` 拷过来：
```bash
cd /tmp && project-creator-cli -b KIT_PSE84_AI \
    -a mtb-example-psoc-edge-ml-deepcraft-deploy-vision
# 逐子工程 getlibs 后，取其 bsps/TARGET_APP_KIT_PSE84_AI 覆盖本仓库同名目录
```

**② 构建**（注意两点：逐子工程 getlibs；编译器目录传 `/usr`）：
```bash
cd Workspace/PSOC_Edge_Machine_Learning_DEEPCRAFT_Deploy_Vision
export CY_TOOLS_PATHS=/opt/ModusToolbox/tools_3.9
for d in proj_cm33_s proj_cm33_ns proj_cm55; do make -C $d getlibs; done
make build CY_COMPILER_GCC_ARM_DIR=/usr
```

**实测产物**（`build/APP_KIT_PSE84_AI/Debug/`）：

| 核 | .bin | .elf | .hex |
|---|---|---|---|
| proj_cm33_s（安全 CM33） | 30,936 B | 727,300 B | 84,309 B |
| proj_cm33_ns（非安全 CM33） | 24,280 B | 801,724 B | 68,371 B |
| proj_cm55（CM55 + NPU） | 3,977,460 B | 7,417,852 B | 11,187,697 B |

**唯一未通过的是后处理 Combine-Sign**（把三核镜像签名合并成单一可烧录镜像）：
```
Error: EdgeProtect Secure Suite not found. Combine-Sign step not executed.
Run the ModusToolbox Setup program to install the Edge Protect Security suite.
```
这是 ModusToolbox Setup 里的**可选安全套件**，**不影响编译产物**。

一键：`linux/build_linux.sh pse84`。

---

## 4. 根因汇总

| # | 问题 | 影响面 | 平台 |
|---|---|---|---|
| 1 | 工具链绝对路径硬编码 `C:/Users/37966/...` + `.exe` | 两个 CMake 工程配置都过不去 | STM32H7、PSE84E |
| 2 | `DataLogger` vs 磁盘 `Datalogger` 大小写 | 头文件找不到 / 源文件漏编译 | 仅 Linux |
| 3 | `Drivers/*.S` vs 磁盘 `startup_*.s` | **启动文件漏编译 → 空固件且不报错** | 仅 Linux |
| 4 | `.gitignore` 忽略 `*.mtb`/`*.mtbx`/`*.cyignore` | **MTB 依赖清单丢失 → getlibs 空跑 → 无法构建** | 全平台 |
| 5 | `esp_camera` 孤儿 gitlink（无 `.gitmodules`） | 全平台全新 clone 后 ESP32 必失败 | 全平台 |
| 6 | vendored BSP 不完整（缺 `design.modus` 等） | MTB 代码生成失败 | 全平台 |
| 7 | `UART_StartRxIT` 无原型 / 多处缺 `<stdlib.h>` | GCC ≥14 直接报错 | 工具链相关 |
| 8 | IDF 6.0：`driver` 拆分、`ESP_IF_WIFI_STA` 移除 | ESP32 编译失败 | 工具链版本相关 |
| 9 | `PSE84E_Project` PDL 库名/布局/器件宏全错 | 该工程无实用价值，建议删除 | 全平台 |
| 10 | `PSE84E_Project/openocd.cfg`、`ESP32_ov2640/openocd.cfg` 是从 XMC8400E 复制的（ESP32 那份还写"XMC8400 是 Cortex-M7"） | 调试/烧录配置不可用 | 全平台 |

**一句话**：#1~#3 是典型的「Windows 能跑、Linux 不行」，被 `build_all.bat` 和 CMake glob 的大小写不敏感行为遮住了；
#4~#6 是仓库层面的**文件缺失**（被 `.gitignore` 或错误的子模块记录吃掉），在任何平台都构建不了。

---

## 5. 构建过程的副作用（请注意）

本次实测中，构建工具**改动了部分受版本控制的文件**，如不需要可 `git checkout -- <path>` 还原：

* `code/ESP32_ov2640/managed_components/**`（54 个文件）——
  IDF 组件管理器按 `idf_component.yml` 的 `'*'` 约束把 `esp_websocket_client`/`mdns`/`esp_jpeg`
  重新解析到 IDF 6.0 兼容版本；`sdkconfig` 也被 IDF 6.0 重新生成。
* `Workspace/.../proj_*/deps/assetlocks.json`、`proj_cm55/imports/emusb-host/**` —— MTB getlibs 更新。
* `Workspace/.../bsps/TARGET_APP_KIT_PSE84_AI/**`（39 个文件）—— BSP 版本替换（见 §3.3）。
* 忽略规则：`mtb_shared/`、`proj_*/libs/`、`proj_*/build/` 已在 `.gitignore` 中；新建的
  `deps/*.mtb` 在修正 `.gitignore` 后应当**纳入版本控制**。

---

## 6. 本次给出的文件

| 文件 | 说明 |
|---|---|
| `linux/build_linux.sh` | 三目标 Linux 构建脚本（STM32H7 默认不动仓库；ESP32 检查组件；PSE84E 走 MTB） |
| `linux/stm32h7-linux.patch` | STM32H7 的 4 处最小改动 |
| `linux/LINUX_BUILD.md` | 本文档 |
