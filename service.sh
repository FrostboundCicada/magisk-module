#!/system/bin/sh
# OnePlus Charging Fix - 开机服务脚本
# 在 zygote 启动后运行，用于动态调整充电参数

MODDIR=${0%/*}

# 等待系统启动完成
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done

# 额外等待确保系统稳定
sleep 5

# 日志文件
LOGFILE="$MODDIR/charging_fix.log"
echo "$(date): OnePlus Charging Fix 服务启动" > "$LOGFILE"

# 获取设备信息
DEVICE=$(getprop ro.product.device 2>/dev/null)
ROM_VERSION=$(getprop ro.build.version.oplusrom 2>/dev/null)
echo "$(date): 设备: $DEVICE" >> "$LOGFILE"
echo "$(date): ROM版本: $ROM_VERSION" >> "$LOGFILE"

# TODO: 根据具体充电问题添加修复逻辑

echo "$(date): 充电修复服务已启动" >> "$LOGFILE"
