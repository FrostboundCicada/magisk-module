#!/system/bin/sh
# OnePlus Charging Fix - 安装脚本
# 主要支持 ColorOS 16，向下兼容

SKIPUNZIP=0

# 检测设备是否为一加设备
ONEPLUS=false
if [ -f /proc/oplus-version ] || [ -f /proc/oplus/version ]; then
    ONEPLUS=true
elif [ -d /system/oplus ]; then
    ONEPLUS=true
fi

# 检测 ColorOS 版本
COLOROS_VERSION="unknown"
if [ -f /proc/oplus-version ]; then
    COLOROS_VERSION=$(cat /proc/oplus-version 2>/dev/null | head -n1)
elif [ -f /proc/oplus/version ]; then
    COLOROS_VERSION=$(cat /proc/oplus/version 2>/dev/null | head -n1)
fi
if [ "$COLOROS_VERSION" = "unknown" ]; then
    COLOROS_VERSION=$(getprop ro.build.version.oplusrom 2>/dev/null)
fi

ui_print "- ================================"
ui_print "- OnePlus Charging Fix v1.3.0"
ui_print "- 快充检测 + 插拔伪装 + 电压/电流调节"
ui_print "- ================================"

if [ "$ONEPLUS" = "true" ]; then
    ui_print "- 检测到一加设备"
    ui_print "- ColorOS/系统版本: $COLOROS_VERSION"
else
    ui_print "! 警告: 未检测到一加设备"
    ui_print "! 本模块专为 OnePlus 设备设计"
    ui_print "! 继续安装可能导致未知问题"
    ui_print "- 等待 3 秒后继续..."
    sleep 3
fi

# ==================== 读取并显示原始充电参数 ====================
ui_print "- "
ui_print "- 正在读取当前充电参数..."
ui_print "- "

# 读取 sysfs 节点值
read_sysfs() {
    cat "$1" 2>/dev/null
}

# 电压相关
ORIG_VOLT=""
for path in \
    /sys/class/power_supply/battery/constant_charge_voltage_max \
    /sys/class/power_supply/battery/voltage_max; do
    val=$(read_sysfs "$path")
    if [ -n "$val" ]; then
        ORIG_VOLT="$val"
        ui_print "- 电压上限: ${val} (${path##*/})"
        break
    fi
done
[ -z "$ORIG_VOLT" ] && ui_print "- 电压上限: 读取失败"

# 电流相关
ORIG_CURRENT=""
for path in \
    /sys/class/power_supply/battery/constant_charge_current_max \
    /sys/class/power_supply/main/constant_charge_current_max; do
    val=$(read_sysfs "$path")
    if [ -n "$val" ]; then
        ORIG_CURRENT="$val"
        ui_print "- 充电电流上限: ${val} (${path##*/})"
        break
    fi
done
[ -z "$ORIG_CURRENT" ] && ui_print "- 充电电流上限: 读取失败"

# 输入电流限制
ORIG_INPUT_CURRENT=""
for path in \
    /sys/class/power_supply/usb/input_current_limit \
    /sys/class/power_supply/main/input_current_limit \
    /sys/class/power_supply/battery/input_current_max; do
    val=$(read_sysfs "$path")
    if [ -n "$val" ]; then
        ORIG_INPUT_CURRENT="$val"
        ui_print "- 输入电流限制: ${val} (${path##*/})"
        break
    fi
done
[ -z "$ORIG_INPUT_CURRENT" ] && ui_print "- 输入电流限制: 读取失败"

# 保存原始参数到文件（重启后 service.sh 会读取并备份）
echo "# 原始充电参数备份（安装时读取）" > "$MODPATH/original_params.conf"
echo "ORIG_VOLT=$ORIG_VOLT" >> "$MODPATH/original_params.conf"
echo "ORIG_CURRENT=$ORIG_CURRENT" >> "$MODPATH/original_params.conf"
echo "ORIG_INPUT_CURRENT=$ORIG_INPUT_CURRENT" >> "$MODPATH/original_params.conf"

ui_print "- "
ui_print "- 以上为当前系统原始参数"
ui_print "- "

# ==================== 音量键选择充电电压上限 ====================
ui_print "- 请选择电池充电电压上限:"
ui_print "-   [音量+] 默认(不修改)"
ui_print "-   [音量-] 自定义选择"
ui_print "- "

VOLTAGE_LIMIT=0
VOLTAGE_LABEL="默认(不修改)"

choice=$(chooseport 60)

if [ "$choice" = "2" ]; then
    ui_print "-   [音量+] 4.35V (轻度提升)"
    ui_print "-   [音量-] 更高"
    choice=$(chooseport 60)

    if [ "$choice" = "1" ]; then
        VOLTAGE_LIMIT=4350
        VOLTAGE_LABEL="4.35V"
    else
        ui_print "-   [音量+] 4.40V (中度提升)"
        ui_print "-   [音量-] 4.45V (最大提升)"
        choice=$(chooseport 60)

        if [ "$choice" = "1" ]; then
            VOLTAGE_LIMIT=4400
            VOLTAGE_LABEL="4.40V"
        else
            VOLTAGE_LIMIT=4450
            VOLTAGE_LABEL="4.45V"
        fi
    fi
fi

ui_print "- "
ui_print "- 已选择电压上限: $VOLTAGE_LABEL"

if [ "$VOLTAGE_LIMIT" != "0" ]; then
    ui_print "! 注意: 提高充电电压会增加电池损耗"
fi

ui_print "- "

# ==================== 音量键选择充电电流上限 ====================
ui_print "- 请选择充电电流上限:"
ui_print "-   [音量+] 默认(不修改)"
ui_print "-   [音量-] 自定义选择"
ui_print "- "

CURRENT_LIMIT=0
CURRENT_LABEL="默认(不修改)"

choice=$(chooseport 60)

if [ "$choice" = "2" ]; then
    ui_print "-   [音量+] 2000mA (保守)"
    ui_print "-   [音量-] 更高"
    choice=$(chooseport 60)

    if [ "$choice" = "1" ]; then
        CURRENT_LIMIT=2000
        CURRENT_LABEL="2000mA"
    else
        ui_print "-   [音量+] 3000mA (标准)"
        ui_print "-   [音量-] 更高"
        choice=$(chooseport 60)

        if [ "$choice" = "1" ]; then
            CURRENT_LIMIT=3000
            CURRENT_LABEL="3000mA"
        else
            ui_print "-   [音量+] 4000mA (快速)"
            ui_print "-   [音量-] 6000mA (极速)"
            choice=$(chooseport 60)

            if [ "$choice" = "1" ]; then
                CURRENT_LIMIT=4000
                CURRENT_LABEL="4000mA"
            else
                CURRENT_LIMIT=6000
                CURRENT_LABEL="6000mA"
            fi
        fi
    fi
fi

ui_print "- "
ui_print "- 已选择电流上限: $CURRENT_LABEL"

if [ "$CURRENT_LIMIT" != "0" ]; then
    ui_print "! 注意: 提高充电电流会增加发热"
fi

ui_print "- "

# ==================== 音量键选择输入电流限制 ====================
ui_print "- 请选择输入电流限制:"
ui_print "-   [音量+] 默认(不修改)"
ui_print "-   [音量-] 自定义选择"
ui_print "- "

INPUT_CURRENT_LIMIT=0
INPUT_CURRENT_LABEL="默认(不修改)"

choice=$(chooseport 60)

if [ "$choice" = "2" ]; then
    ui_print "-   [音量+] 1000mA (保守)"
    ui_print "-   [音量-] 更高"
    choice=$(chooseport 60)

    if [ "$choice" = "1" ]; then
        INPUT_CURRENT_LIMIT=1000
        INPUT_CURRENT_LABEL="1000mA"
    else
        ui_print "-   [音量+] 2000mA (标准)"
        ui_print "-   [音量-] 3000mA (最大)"
        choice=$(chooseport 60)

        if [ "$choice" = "1" ]; then
            INPUT_CURRENT_LIMIT=2000
            INPUT_CURRENT_LABEL="2000mA"
        else
            INPUT_CURRENT_LIMIT=3000
            INPUT_CURRENT_LABEL="3000mA"
        fi
    fi
fi

ui_print "- "
ui_print "- 已选择输入电流限制: $INPUT_CURRENT_LABEL"
ui_print "- "

# ==================== 音量键选择是否启用插拔伪装 ====================
ui_print "- 是否启用充电器插拔伪装?"
ui_print "-   [音量+] 启用(默认)"
ui_print "-   [音量-] 禁用"
choice=$(chooseport 60)

ENABLE_FAKE_CYCLE=1
if [ "$choice" = "2" ]; then
    ENABLE_FAKE_CYCLE=0
    ui_print "- 已禁用插拔伪装"
else
    ui_print "- 已启用插拔伪装 (间隔120s)"
fi

# ==================== 保存配置 ====================
cat > "$MODPATH/charging_params.conf" << PARAMS_EOF
# OnePlus Charging Fix 参数配置
# 安装时通过音量键选择，重启后 service.sh 读取应用

# 电池充电电压上限 (mV，0=不修改)
VOLTAGE_LIMIT=$VOLTAGE_LIMIT

# 充电电流上限 (mA，0=不修改)
CURRENT_LIMIT=$CURRENT_LIMIT

# 输入电流限制 (mA，0=不修改)
INPUT_CURRENT_LIMIT=$INPUT_CURRENT_LIMIT

# 是否启用插拔伪装 (1=启用，0=禁用)
ENABLE_FAKE_CYCLE=$ENABLE_FAKE_CYCLE
PARAMS_EOF

ui_print "- "
ui_print "- ================================"
ui_print "- 配置摘要:"
ui_print "-   电压上限: $VOLTAGE_LABEL"
ui_print "-   电流上限: $CURRENT_LABEL"
ui_print "-   输入电流: $INPUT_CURRENT_LABEL"
ui_print "-   插拔伪装: $([ "$ENABLE_FAKE_CYCLE" = "1" ] && echo "启用" || echo "禁用")"
ui_print "- ================================"
ui_print "- "
ui_print "- 安装中..."

# 设置文件权限
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/system" 0 0 0755 0644

# 脚本文件设置可执行权限
if [ -f "$MODPATH/service.sh" ]; then
    set_perm "$MODPATH/service.sh" 0 0 0755
fi
if [ -f "$MODPATH/post-fs-data.sh" ]; then
    set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
fi
if [ -f "$MODPATH/uninstall.sh" ]; then
    set_perm "$MODPATH/uninstall.sh" 0 0 0755
fi

ui_print "- 安装完成!"
ui_print "- 重启后生效"
ui_print "- 原始参数已备份到 original_params.conf"
ui_print "- 运行日志: charging_fix.log"
