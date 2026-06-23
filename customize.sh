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
ui_print "- OnePlus Charging Fix v1.1.0"
ui_print "- 功能: 快充协议检测 + 充电器插拔伪装"
ui_print "- 默认间隔: 120s"
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
