#!/system/bin/sh
# OnePlus Charging Fix - 卸载脚本
# 模块卸载时自动执行

ui_print "- 正在卸载 OnePlus Charging Fix"

# 停止 Web 服务器
pkill -f "httpd.*8765" 2>/dev/null
ui_print "- Web 管理界面已停止"

# 尝试恢复原始充电参数
MODDIR=${0%/*}
if [ -f "$MODDIR/original_params.conf" ]; then
    . "$MODDIR/original_params.conf"
    ui_print "- 正在恢复原始充电参数..."

    # 恢复电压上限
    if [ -n "$BACKUP_VOLT" ]; then
        for path in \
            /sys/class/power_supply/battery/constant_charge_voltage_max \
            /sys/class/power_supply/battery/voltage_max; do
            if [ -w "$path" ]; then
                echo "$BACKUP_VOLT" > "$path" 2>/dev/null
                break
            fi
        done
    fi

    # 恢复电流上限
    if [ -n "$BACKUP_CURRENT" ]; then
        for path in \
            /sys/class/power_supply/battery/constant_charge_current_max \
            /sys/class/power_supply/main/constant_charge_current_max; do
            if [ -w "$path" ]; then
                echo "$BACKUP_CURRENT" > "$path" 2>/dev/null
                break
            fi
        done
    fi

    # 恢复输入电流
    if [ -n "$BACKUP_INPUT_CURRENT" ]; then
        for path in \
            /sys/class/power_supply/usb/input_current_limit \
            /sys/class/power_supply/main/input_current_limit; do
            if [ -w "$path" ]; then
                echo "$BACKUP_INPUT_CURRENT" > "$path" 2>/dev/null
                break
            fi
        done
    fi

    # 恢复亮屏限速等开关
    for path in \
        /sys/class/oplus_chg/screen_on_limit \
        /sys/class/oplus_chg/screen_on_limit_enable; do
        if [ -w "$path" ]; then
            echo 1 > "$path" 2>/dev/null
        fi
    done

    for path in \
        /sys/class/oplus_chg/thermal_switch \
        /sys/class/oplus_chg/cool_down; do
        if [ -w "$path" ]; then
            echo 1 > "$path" 2>/dev/null
        fi
    done

    ui_print "- 原始参数已恢复"
fi

ui_print "- 充电设置将恢复为系统默认"
ui_print "- 卸载完成，建议重启设备"
