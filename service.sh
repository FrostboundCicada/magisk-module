#!/system/bin/sh
# OnePlus Charging Fix - 充电参数控制 + 插拔伪装服务
# 功能:
#   1. 备份原始充电参数并显示修改前/后对比
#   2. 应用电压/电流/输入电流上限
#   3. 检测快充协议时周期性伪装充电器插拔
# 主要支持 ColorOS 16，向下兼容

MODDIR=${0%/*}
LOGFILE="$MODDIR/charging_fix.log"
BACKUP_FILE="$MODDIR/original_params.conf"

# ==================== 读取配置 ====================
INTERVAL=120
TOGGLE_OFF_TIME=3
MAX_LOG_LINES=500

if [ -f "$MODDIR/config" ]; then
    . "$MODDIR/config"
fi

# 读取安装时选择的参数配置
VOLTAGE_LIMIT=0
CURRENT_LIMIT=0
INPUT_CURRENT_LIMIT=0
ENABLE_FAKE_CYCLE=1
if [ -f "$MODDIR/charging_params.conf" ]; then
    . "$MODDIR/charging_params.conf"
fi

# ==================== 等待系统启动 ====================
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done
sleep 5

# ==================== 日志函数 ====================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOGFILE"
    local lines
    lines=$(wc -l < "$LOGFILE" 2>/dev/null)
    if [ -n "$lines" ] && [ "$lines" -gt "$MAX_LOG_LINES" ]; then
        tail -n $((MAX_LOG_LINES / 2)) "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null
        mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null
    fi
}

# ==================== 读取 sysfs 节点 ====================
read_sysfs() {
    cat "$1" 2>/dev/null
}

# ==================== 备份原始参数 ====================
backup_original_params() {
    log "--- 备份原始充电参数 ---"

    local volt="" current="" input_current=""

    # 电压上限
    for path in \
        /sys/class/power_supply/battery/constant_charge_voltage_max \
        /sys/class/power_supply/battery/voltage_max \
        /sys/class/power_supply/main/voltage_max \
        /sys/class/power_supply/bms/voltage_max; do
        volt=$(read_sysfs "$path")
        if [ -n "$volt" ]; then
            log "原始电压上限: ${volt} ($path)"
            break
        fi
    done
    [ -z "$volt" ] && log "原始电压上限: 读取失败"

    # 充电电流上限
    for path in \
        /sys/class/power_supply/battery/constant_charge_current_max \
        /sys/class/power_supply/main/constant_charge_current_max \
        /sys/class/power_supply/battery/current_max; do
        current=$(read_sysfs "$path")
        if [ -n "$current" ]; then
            log "原始电流上限: ${current} ($path)"
            break
        fi
    done
    [ -z "$current" ] && log "原始电流上限: 读取失败"

    # 输入电流限制
    for path in \
        /sys/class/power_supply/usb/input_current_limit \
        /sys/class/power_supply/main/input_current_limit \
        /sys/class/power_supply/battery/input_current_max; do
        input_current=$(read_sysfs "$path")
        if [ -n "$input_current" ]; then
            log "原始输入电流: ${input_current} ($path)"
            break
        fi
    done
    [ -z "$input_current" ] && log "原始输入电流: 读取失败"

    # 写入备份文件（覆盖安装时的备份，使用运行时实际值）
    cat > "$BACKUP_FILE" << EOF
# 原始充电参数备份 (运行时读取)
# 用于卸载后对比参照
BACKUP_VOLT=$volt
BACKUP_CURRENT=$current
BACKUP_INPUT_CURRENT=$input_current
BACKUP_TIME=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    log "原始参数已备份到 original_params.conf"
    log "--- 备份完成 ---"
}

# ==================== 应用电压上限 ====================
apply_voltage_limit() {
    if [ "$VOLTAGE_LIMIT" = "0" ] || [ -z "$VOLTAGE_LIMIT" ]; then
        log "电压上限: 不修改"
        return
    fi

    local voltage_uv="${VOLTAGE_LIMIT}000"
    local applied=false

    log "应用电压上限: ${VOLTAGE_LIMIT}mV (${voltage_uv}uV)"

    for path in \
        /sys/class/power_supply/battery/constant_charge_voltage_max \
        /sys/class/power_supply/battery/voltage_max \
        /sys/class/power_supply/main/voltage_max \
        /sys/class/power_supply/bms/voltage_max \
        /sys/class/power_supply/battery/fg_voltage_max; do
        if [ -w "$path" ]; then
            local before
            before=$(read_sysfs "$path")
            echo "$voltage_uv" > "$path" 2>/dev/null
            local after
            after=$(read_sysfs "$path")
            if [ -n "$after" ]; then
                log "电压上限 [$path]:"
                log "  修改前: ${before}"
                log "  修改后: ${after}"
                applied=true
                break
            fi
        fi
    done

    # 备用: 尝试毫伏单位
    if [ "$applied" = "false" ]; then
        for path in \
            /sys/class/power_supply/battery/constant_charge_voltage_max \
            /sys/class/power_supply/battery/voltage_max; do
            if [ -w "$path" ]; then
                local before
                before=$(read_sysfs "$path")
                echo "$VOLTAGE_LIMIT" > "$path" 2>/dev/null
                local after
                after=$(read_sysfs "$path")
                if [ -n "$after" ]; then
                    log "电压上限 [$path] (mV):"
                    log "  修改前: ${before}"
                    log "  修改后: ${after}"
                    applied=true
                    break
                fi
            fi
        done
    fi

    if [ "$applied" = "false" ]; then
        log "警告: 电压上限应用失败，未找到可用节点"
        ls /sys/class/power_supply/battery/ >> "$LOGFILE" 2>/dev/null
    fi
}

# ==================== 应用电流上限 ====================
apply_current_limit() {
    if [ "$CURRENT_LIMIT" = "0" ] || [ -z "$CURRENT_LIMIT" ]; then
        log "电流上限: 不修改"
        return
    fi

    local current_ua="${CURRENT_LIMIT}000"
    local applied=false

    log "应用充电电流上限: ${CURRENT_LIMIT}mA (${current_ua}uA)"

    for path in \
        /sys/class/power_supply/battery/constant_charge_current_max \
        /sys/class/power_supply/main/constant_charge_current_max \
        /sys/class/power_supply/battery/current_max; do
        if [ -w "$path" ]; then
            local before
            before=$(read_sysfs "$path")
            echo "$current_ua" > "$path" 2>/dev/null
            local after
            after=$(read_sysfs "$path")
            if [ -n "$after" ]; then
                log "电流上限 [$path]:"
                log "  修改前: ${before}"
                log "  修改后: ${after}"
                applied=true
                break
            fi
        fi
    done

    # 备用: 尝试毫安单位
    if [ "$applied" = "false" ]; then
        for path in \
            /sys/class/power_supply/battery/constant_charge_current_max \
            /sys/class/power_supply/main/constant_charge_current_max; do
            if [ -w "$path" ]; then
                local before
                before=$(read_sysfs "$path")
                echo "$CURRENT_LIMIT" > "$path" 2>/dev/null
                local after
                after=$(read_sysfs "$path")
                if [ -n "$after" ]; then
                    log "电流上限 [$path] (mA):"
                    log "  修改前: ${before}"
                    log "  修改后: ${after}"
                    applied=true
                    break
                fi
            fi
        done
    fi

    if [ "$applied" = "false" ]; then
        log "警告: 电流上限应用失败，未找到可用节点"
    fi
}

# ==================== 应用输入电流限制 ====================
apply_input_current_limit() {
    if [ "$INPUT_CURRENT_LIMIT" = "0" ] || [ -z "$INPUT_CURRENT_LIMIT" ]; then
        log "输入电流: 不修改"
        return
    fi

    local current_ua="${INPUT_CURRENT_LIMIT}000"
    local applied=false

    log "应用输入电流限制: ${INPUT_CURRENT_LIMIT}mA (${current_ua}uA)"

    for path in \
        /sys/class/power_supply/usb/input_current_limit \
        /sys/class/power_supply/main/input_current_limit \
        /sys/class/power_supply/battery/input_current_max; do
        if [ -w "$path" ]; then
            local before
            before=$(read_sysfs "$path")
            echo "$current_ua" > "$path" 2>/dev/null
            local after
            after=$(read_sysfs "$path")
            if [ -n "$after" ]; then
                log "输入电流 [$path]:"
                log "  修改前: ${before}"
                log "  修改后: ${after}"
                applied=true
                break
            fi
        fi
    done

    # 备用: 尝试毫安单位
    if [ "$applied" = "false" ]; then
        for path in \
            /sys/class/power_supply/usb/input_current_limit \
            /sys/class/power_supply/main/input_current_limit; do
            if [ -w "$path" ]; then
                local before
                before=$(read_sysfs "$path")
                echo "$INPUT_CURRENT_LIMIT" > "$path" 2>/dev/null
                local after
                after=$(read_sysfs "$path")
                if [ -n "$after" ]; then
                    log "输入电流 [$path] (mA):"
                    log "  修改前: ${before}"
                    log "  修改后: ${after}"
                    applied=true
                    break
                fi
            fi
        done
    fi

    if [ "$applied" = "false" ]; then
        log "警告: 输入电流应用失败，未找到可用节点"
    fi
}

# ==================== 检测充电器是否连接 ====================
is_charger_connected() {
    local online status
    online=$(read_sysfs /sys/class/power_supply/usb/online)
    status=$(read_sysfs /sys/class/power_supply/battery/status)
    if [ "$online" = "1" ]; then
        return 0
    fi
    case "$status" in
        Charging|Full) return 0 ;;
    esac
    return 1
}

# ==================== 检测快充协议 ====================
get_fast_charge_type() {
    local real_type=""
    for path in \
        /sys/class/power_supply/usb/real_type \
        /sys/class/power_supply/battery/charge_type \
        /sys/class/power_supply/vooc/real_type \
        /sys/class/power_supply/svooc/real_type \
        /sys/class/power_supply/usb/type; do
        if [ -f "$path" ]; then
            local val
            val=$(read_sysfs "$path")
            if [ -n "$val" ] && [ "$val" != "Unknown" ] && [ "$val" != "unknown" ]; then
                real_type="$val"
                break
            fi
        fi
    done
    case "$real_type" in
        *VOOC*|*vooc*|*SUPERVOOC*|*SuperVooc*|*SuperVOOC*|*PD*|*QC*|*qc*|*FCP*|*SCP*|*fcp*|*scp*|*HVDCP*|*hvdcp*|*FlashCharge*|*flash_charge*|*USB_HVDCP*|*USB_PD*)
            echo "$real_type"
            ;;
    esac
}

# ==================== 伪装充电器插拔 ====================
fake_charger_cycle() {
    local charge_type="$1"
    log "检测到快充协议: $charge_type, 开始伪装插拔"

    local toggled=false

    # 方法1: VOOC/SVOOC 专用节点
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

    # 方法2: charging_enabled 开关
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

    # 方法3: USB online/present
    if [ "$toggled" = "false" ]; then
        for path in \
            /sys/class/power_supply/usb/online \
            /sys/class/power_supply/usb/present; do
            if [ -w "$path" ]; then
                echo 0 > "$path" 2>/dev/null
                log "通过 $path 模拟拔出"
                sleep "$TOGGLE_OFF_TIME"
                echo 1 > "$path" 2>/dev/null
                log "通过 $path 模拟插入"
                toggled=true
                break
            fi
        done
    fi

    if [ "$toggled" = "false" ]; then
        log "警告: 未找到可用的充电控制路径"
        ls -la /sys/class/power_supply/battery/ >> "$LOGFILE" 2>/dev/null
        ls -la /sys/class/power_supply/usb/ >> "$LOGFILE" 2>/dev/null
    else
        log "插拔伪装完成，快充协议将重新协商"
    fi
}

# ==================== 主流程 ====================
log "==============================="
log "OnePlus Charging Fix 服务启动"
log "设备: $(getprop ro.product.device)"
log "型号: $(getprop ro.product.model)"
log "ROM版本: $(getprop ro.build.version.oplusrom)"
log "==============================="
log "配置摘要:"
log "  电压上限: $([ "$VOLTAGE_LIMIT" = "0" ] && echo "不修改" || echo "${VOLTAGE_LIMIT}mV")"
log "  电流上限: $([ "$CURRENT_LIMIT" = "0" ] && echo "不修改" || echo "${CURRENT_LIMIT}mA")"
log "  输入电流: $([ "$INPUT_CURRENT_LIMIT" = "0" ] && echo "不修改" || echo "${INPUT_CURRENT_LIMIT}mA")"
log "  插拔伪装: $([ "$ENABLE_FAKE_CYCLE" = "1" ] && echo "启用" || echo "禁用")"
log "  循环间隔: ${INTERVAL}s"
log "==============================="

# 1. 备份原始参数
backup_original_params

# 2. 应用充电参数
log "--- 应用充电参数 ---"
apply_voltage_limit
apply_current_limit
apply_input_current_limit
log "--- 参数应用完成 ---"

# 3. 如果禁用了插拔伪装，应用完参数后退出
if [ "$ENABLE_FAKE_CYCLE" != "1" ]; then
    log "插拔伪装已禁用，服务退出"
    exit 0
fi

# 4. 主循环: 插拔伪装
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
