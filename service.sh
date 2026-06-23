#!/system/bin/sh
# OnePlus Charging Fix - 充电伪装插拔服务 + 电压上限控制
# 检测到官方快充协议时，每隔指定间隔伪装一次充电器插拔
# 支持通过安装时选择的电压上限调整电池充电电压
# 主要支持 ColorOS 16，向下兼容

MODDIR=${0%/*}
LOGFILE="$MODDIR/charging_fix.log"

# ==================== 读取配置 ====================
INTERVAL=120
TOGGLE_OFF_TIME=3
MAX_LOG_LINES=500

if [ -f "$MODDIR/config" ]; then
    . "$MODDIR/config"
fi

# 读取安装时选择的电压配置
VOLTAGE_LIMIT=0
ENABLE_FAKE_CYCLE=1
if [ -f "$MODDIR/voltage.conf" ]; then
    . "$MODDIR/voltage.conf"
fi

# ==================== 等待系统启动 ====================
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done
sleep 5

# ==================== 日志函数 ====================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOGFILE"
    # 日志轮转
    local lines
    lines=$(wc -l < "$LOGFILE" 2>/dev/null)
    if [ -n "$lines" ] && [ "$lines" -gt "$MAX_LOG_LINES" ]; then
        tail -n $((MAX_LOG_LINES / 2)) "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null
    fi
}

# ==================== 应用电压上限 ====================
apply_voltage_limit() {
    if [ "$VOLTAGE_LIMIT" = "0" ] || [ -z "$VOLTAGE_LIMIT" ]; then
        log "电压上限: 默认(不修改)"
        return
    fi

    # 将电压值转换为微伏 (mV -> uV)
    local voltage_uv="${VOLTAGE_LIMIT}000"
    local applied=false

    log "开始应用电压上限: ${VOLTAGE_LIMIT}mV (${voltage_uv}uV)"

    # 尝试多个 sysfs 路径设置充电电压上限
    for path in \
        /sys/class/power_supply/battery/constant_charge_voltage_max \
        /sys/class/power_supply/battery/voltage_max \
        /sys/class/power_supply/main/voltage_max \
        /sys/class/power_supply/bms/voltage_max \
        /sys/class/power_supply/battery/fg_voltage_max; do
        if [ -w "$path" ]; then
            echo "$voltage_uv" > "$path" 2>/dev/null
            local result
            result=$(cat "$path" 2>/dev/null)
            if [ -n "$result" ]; then
                log "通过 $path 设置电压上限: ${result}uV"
                applied=true
                break
            fi
        fi
    done

    # 备用: 尝试以毫伏为单位写入
    if [ "$applied" = "false" ]; then
        for path in \
            /sys/class/power_supply/battery/constant_charge_voltage_max \
            /sys/class/power_supply/battery/voltage_max; do
            if [ -w "$path" ]; then
                echo "$VOLTAGE_LIMIT" > "$path" 2>/dev/null
                local result
                result=$(cat "$path" 2>/dev/null)
                if [ -n "$result" ]; then
                    log "通过 $path 设置电压上限(mV): ${result}"
                    applied=true
                    break
                fi
            fi
        done
    fi

    if [ "$applied" = "false" ]; then
        log "警告: 未找到可用的电压控制节点"
        log "可用的 battery sysfs 节点:"
        ls /sys/class/power_supply/battery/ >> "$LOGFILE" 2>/dev/null
    else
        log "电压上限应用完成"
    fi
}

# ==================== 检测充电器是否连接 ====================
is_charger_connected() {
    local online
    local status
    online=$(cat /sys/class/power_supply/usb/online 2>/dev/null)
    status=$(cat /sys/class/power_supply/battery/status 2>/dev/null)

    if [ "$online" = "1" ]; then
        return 0
    fi
    case "$status" in
        Charging|Full)
            return 0
            ;;
    esac
    return 1
}

# ==================== 检测快充协议 ====================
# 返回快充类型字符串，非快充时返回空
get_fast_charge_type() {
    local real_type=""

    # 尝试多个 sysfs 路径获取充电协议类型
    for path in \
        /sys/class/power_supply/usb/real_type \
        /sys/class/power_supply/battery/charge_type \
        /sys/class/power_supply/vooc/real_type \
        /sys/class/power_supply/svooc/real_type \
        /sys/class/power_supply/usb/type; do
        if [ -f "$path" ]; then
            local val
            val=$(cat "$path" 2>/dev/null)
            if [ -n "$val" ] && [ "$val" != "Unknown" ] && [ "$val" != "unknown" ]; then
                real_type="$val"
                break
            fi
        fi
    done

    # 匹配官方快充协议关键词
    case "$real_type" in
        *VOOC*|*vooc*|*SUPERVOOC*|*SuperVooc*|*SuperVOOC*|*PD*|*QC*|*qc*|*FCP*|*SCP*|*fcp*|*scp*|*HVDCP*|*hvdcp*|*FlashCharge*|*flash_charge*|*USB_HVDCP*|*USB_PD*)
            echo "$real_type"
            ;;
    esac
}

# ==================== 伪装充电器插拔 ====================
fake_charger_cycle() {
    local charge_type="$1"
    log "检测到快充协议: $charge_type, 开始伪装充电器插拔"

    local toggled=false

    # 方法1: 通过 VOOC/SVOOC 专用节点重置（优先，影响最小）
    for path in \
        /sys/class/power_supply/vooc/enable \
        /sys/class/power_supply/svooc/enable; do
        if [ -w "$path" ]; then
            echo 0 > "$path" 2>/dev/null
            log "通过 $path 关闭快充"
            sleep "$TOGGLE_OFF_TIME"
            echo 1 > "$path" 2>/dev/null
            log "通过 $path 恢复快充"
            toggled=true
            break
        fi
    done

    # 方法2: 通过 charging_enabled 开关
    if [ "$toggled" = "false" ]; then
        for path in \
            /sys/class/power_supply/battery/charging_enabled \
            /sys/class/power_supply/battery/battery_charging_enabled \
            /sys/class/qcom-battery/charging_enabled \
            /sys/class/power_supply/main/charging_enabled; do
            if [ -w "$path" ]; then
                echo 0 > "$path" 2>/dev/null
                log "通过 $path 关闭充电"
                sleep "$TOGGLE_OFF_TIME"
                echo 1 > "$path" 2>/dev/null
                log "通过 $path 恢复充电"
                toggled=true
                break
            fi
        done
    fi

    # 方法3: 通过 USB online/present 模拟物理插拔
    if [ "$toggled" = "false" ]; then
        for path in \
            /sys/class/power_supply/usb/online \
            /sys/class/power_supply/usb/present; do
            if [ -w "$path" ]; then
                echo 0 > "$path" 2>/dev/null
                log "通过 $path 模拟拔出充电器"
                sleep "$TOGGLE_OFF_TIME"
                echo 1 > "$path" 2>/dev/null
                log "通过 $path 模拟插入充电器"
                toggled=true
                break
            fi
        done
    fi

    if [ "$toggled" = "false" ]; then
        log "警告: 未找到可用的充电控制路径，无法执行插拔伪装"
        log "可用的 sysfs 节点:"
        ls -la /sys/class/power_supply/battery/ >> "$LOGFILE" 2>/dev/null
        ls -la /sys/class/power_supply/usb/ >> "$LOGFILE" 2>/dev/null
    else
        log "充电器插拔伪装完成，快充协议将重新协商"
    fi
}

# ==================== 主流程 ====================
log "==============================="
log "OnePlus Charging Fix 服务启动"
log "设备: $(getprop ro.product.device)"
log "型号: $(getprop ro.product.model)"
log "ROM版本: $(getprop ro.build.version.oplusrom)"
log "循环间隔: ${INTERVAL}s, 关闭时长: ${TOGGLE_OFF_TIME}s"
log "插拔伪装: $([ "$ENABLE_FAKE_CYCLE" = "1" ] && echo "启用" || echo "禁用")"
log "电压上限: $([ "$VOLTAGE_LIMIT" = "0" ] && echo "默认" || echo "${VOLTAGE_LIMIT}mV")"
log "==============================="

# 应用电压上限
apply_voltage_limit

# 如果禁用了插拔伪装，只应用电压后退出
if [ "$ENABLE_FAKE_CYCLE" != "1" ]; then
    log "插拔伪装已禁用，服务退出"
    exit 0
fi

# 主循环
while true; do
    if is_charger_connected; then
        charge_type=$(get_fast_charge_type)
        if [ -n "$charge_type" ]; then
            fake_charger_cycle "$charge_type"
        else
            log "充电器已连接，非快充协议，跳过"
        fi
    else
        log "充电器未连接，跳过"
    fi

    sleep "$INTERVAL"
done
