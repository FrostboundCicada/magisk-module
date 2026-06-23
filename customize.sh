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
# 尝试通过 prop 获取
if [ "$COLOROS_VERSION" = "unknown" ]; then
    COLOROS_VERSION=$(getprop ro.build.version.oplusrom 2>/dev/null)
fi

ui_print "- ================================"
ui_print "- OnePlus Charging Fix v1.2.0"
ui_print "- 功能: 快充检测 + 插拔伪装 + 电压上限"
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

# ==================== 音量键选择充电电压上限 ====================
ui_print "- "
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
    ui_print "! 建议仅在需要时使用更高电压"
fi

# 保存电压选择到配置文件
if [ "$VOLTAGE_LIMIT" != "0" ]; then
    echo "VOLTAGE_LIMIT=$VOLTAGE_LIMIT" > "$MODPATH/voltage.conf"
else
    echo "VOLTAGE_LIMIT=0" > "$MODPATH/voltage.conf"
fi

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

echo "ENABLE_FAKE_CYCLE=$ENABLE_FAKE_CYCLE" >> "$MODPATH/voltage.conf"

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
