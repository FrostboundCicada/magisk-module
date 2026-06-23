#!/system/bin/sh
# OnePlus Charging Fix - 充电参数控制 + 插拔伪装 + 强制满速
# 功能:
#   1. 备份原始充电参数并显示修改前/后对比
#   2. 应用电压/电流/输入电流上限
#   3. 检测快充协议时周期性伪装充电器插拔
#   4. 强制满速充电: 亮屏不限速 + 禁用温控降速 + 持续维持最大电流
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
FORCE_MAX_SPEED=0
ENABLE_WEB_UI=1
WEB_PORT=8765
if [ -f "$MODDIR/charging_params.conf" ]; then
    . "$MODDIR/charging_params.conf"
fi
if [ -f "$MODDIR/config" ]; then
    . "$MODDIR/config"
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

# ==================== 强制满速充电 ====================
# 持续覆盖系统充电策略: 亮屏不限速、禁用温控降速、维持最大电流

# 写入 sysfs 节点，失败静默
write_node() {
    if [ -w "$1" ]; then
        echo "$2" > "$1" 2>/dev/null
    fi
}

# 强制启用快充
force_fastcharge_enable() {
    # VOOC/SVOOC 快充开关强制开启
    for path in \
        /sys/class/power_supply/vooc/enable \
        /sys/class/power_supply/svooc/enable \
        /sys/class/oplus_chg/vooc_enable \
        /sys/class/oplus_chg/svooc_enable \
        /sys/class/oplus_chg/fastchg_normal_switch \
        /sys/class/oplus_chg/fastchg_switch; do
        write_node "$path" 1
    done

    # 通用快充开关
    for path in \
        /sys/class/power_supply/battery/fast_charge \
        /sys/class/power_supply/usb/fast_charge; do
        write_node "$path" 1
    done
}

# 禁用亮屏限速
force_disable_screen_throttle() {
    # 一加/OPPO 亮屏充电限速节点
    for path in \
        /sys/class/oplus_chg/screen_on_current_max \
        /sys/class/oplus_chg/screen_on_charge_current_max \
        /sys/class/power_supply/battery/screen_on_current_max \
        /sys/class/power_supply/battery/charge_screen_on_current_max; do
        # 写入一个很大的值，等效于不限速
        write_node "$path" 10000000
    done

    # 禁用亮屏限速开关
    for path in \
        /sys/class/oplus_chg/screen_on_limit \
        /sys/class/oplus_chg/screen_on_limit_enable \
        /sys/class/power_supply/battery/screen_on_limit; do
        write_node "$path" 0
    done
}

# 禁用温控降速
force_disable_thermal_throttle() {
    # 提高温控阈值到最大
    for path in \
        /sys/class/power_supply/battery/system_temp_level \
        /sys/class/oplus_chg/thermal_temp_level \
        /sys/class/oplus_chg/normal_temp_level; do
        # 0 通常表示不限制或最高级别
        write_node "$path" 0
    done

    # 禁用充电温控
    for path in \
        /sys/class/oplus_chg/thermal_switch \
        /sys/class/oplus_chg/cool_down \
        /sys/class/power_supply/battery/thermal_charging; do
        write_node "$path" 0
    done

    # 提高温控电流限制
    for path in \
        /sys/class/oplus_chg/thermal_current_max \
        /sys/class/power_supply/battery/thermal_current_max; do
        write_node "$path" 10000000
    done
}

# 禁用电量阶段限速 (高电量时系统会降低充电速度)
force_disable_stage_throttle() {
    # 禁用充电阶段限制
    for path in \
        /sys/class/oplus_chg/fg_stage_charge \
        /sys/class/oplus_chg/stage_charge_enable \
        /sys/class/power_supply/battery/stage_charge_enable; do
        write_node "$path" 0
    done

    # 提高涓流充电阈值
    for path in \
        /sys/class/oplus_chg/tick_current_max \
        /sys/class/oplus_chg/termination_current \
        /sys/class/power_supply/battery/termination_current; do
        write_node "$path" 10000000
    done
}

# 强制维持最大充电电流
force_max_current() {
    # 持续写入最大电流值
    for path in \
        /sys/class/power_supply/battery/constant_charge_current_max \
        /sys/class/power_supply/main/constant_charge_current_max \
        /sys/class/oplus_chg/constant_charge_current_max; do
        if [ -w "$path" ]; then
            # 写入 10A (10000000uA)，硬件会自动限制到实际最大值
            echo 10000000 > "$path" 2>/dev/null
        fi
    done

    # 输入电流限制拉满
    for path in \
        /sys/class/power_supply/usb/input_current_limit \
        /sys/class/power_supply/main/input_current_limit \
        /sys/class/oplus_chg/input_current_max; do
        if [ -w "$path" ]; then
            echo 10000000 > "$path" 2>/dev/null
        fi
    done
}

# 强制满速充电主逻辑 (每次循环调用)
force_max_speed_once() {
    force_fastcharge_enable
    force_disable_screen_throttle
    force_disable_thermal_throttle
    force_disable_stage_throttle
    force_max_current
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
log "  强制满速: $([ "$FORCE_MAX_SPEED" = "1" ] && echo "启用" || echo "禁用")"
log "  Web管理: $([ "$ENABLE_WEB_UI" = "1" ] && echo "启用 (端口:$WEB_PORT)" || echo "禁用")"
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

# 3. 如果启用强制满速，先执行一次
if [ "$FORCE_MAX_SPEED" = "1" ]; then
    log "--- 强制满速充电已启用 ---"
    log "将持续覆盖: 亮屏限速 / 温控降速 / 电量阶段限速"
    force_max_speed_once
    log "强制满速初始应用完成"
fi

# 4. 启动 Web 管理界面
if [ "$ENABLE_WEB_UI" = "1" ]; then
    # 确保 CGI 脚本有执行权限
    chmod 0755 "$MODDIR/web/cgi-bin/api.sh" 2>/dev/null

    # 先杀掉可能存在的旧 httpd 进程
    pkill -f "httpd.*$WEB_PORT" 2>/dev/null
    sleep 1

    # 尝试用 busybox httpd 启动
    if busybox httpd -p "$WEB_PORT" -h "$MODDIR/web" 2>/dev/null; then
        log "Web 管理界面已启动: http://localhost:$WEB_PORT"
        # 获取设备 IP
        DEVICE_IP=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
        if [ -n "$DEVICE_IP" ]; then
            log "局域网访问: http://$DEVICE_IP:$WEB_PORT"
        fi
    else
        log "警告: busybox httpd 启动失败，Web 管理界面不可用"
    fi
fi

# 5. 主循环
FORCE_INTERVAL=10
log "进入主循环 (强制满速刷新: ${FORCE_INTERVAL}s, 插拔伪装: ${INTERVAL}s)"

cycle_count=0
while true; do
    # 检查配置热重载标志
    if [ -f "$MODDIR/reload" ]; then
        rm -f "$MODDIR/reload"
        log "--- 检测到配置更新 (Web UI)，重新加载 ---"
        # 重新读取配置
        . "$MODDIR/charging_params.conf"
        log "新配置: 电压=${VOLTAGE_LIMIT}mV 电流=${CURRENT_LIMIT}mA 输入=${INPUT_CURRENT_LIMIT}mA"
        log "  强制满速=$FORCE_MAX_SPEED 插拔伪装=$ENABLE_FAKE_CYCLE"
        # 重新应用参数
        apply_voltage_limit
        apply_current_limit
        apply_input_current_limit
        if [ "$FORCE_MAX_SPEED" = "1" ]; then
            force_max_speed_once
        fi
        log "--- 配置热重载完成 ---"
    fi

    # 检查重启标志
    if [ -f "$MODDIR/restart" ]; then
        rm -f "$MODDIR/restart"
        log "--- 收到重启信号，重启服务 ---"
        # 重启 httpd
        if [ "$ENABLE_WEB_UI" = "1" ]; then
            pkill -f "httpd.*$WEB_PORT" 2>/dev/null
            sleep 1
            busybox httpd -p "$WEB_PORT" -h "$MODDIR/web" 2>/dev/null
            log "Web 管理界面已重启"
        fi
        # 重新应用所有配置
        . "$MODDIR/charging_params.conf"
        backup_original_params
        apply_voltage_limit
        apply_current_limit
        apply_input_current_limit
        if [ "$FORCE_MAX_SPEED" = "1" ]; then
            force_max_speed_once
        fi
        log "--- 服务重启完成 ---"
    fi

    # 强制满速: 每 10 秒刷新一次
    if [ "$FORCE_MAX_SPEED" = "1" ]; then
        force_max_speed_once
    fi

    # 插拔伪装: 每 INTERVAL 秒执行一次
    if [ "$ENABLE_FAKE_CYCLE" = "1" ]; then
        cycle_count=$((cycle_count + FORCE_INTERVAL))
        if [ "$cycle_count" -ge "$INTERVAL" ]; then
            cycle_count=0
            if is_charger_connected; then
                charge_type=$(get_fast_charge_type)
                if [ -n "$charge_type" ]; then
                    fake_charger_cycle "$charge_type"
                else
                    log "充电器已连接，非快充协议，跳过插拔"
                fi
            else
                log "充电器未连接，跳过插拔"
            fi
        fi
    fi

    sleep "$FORCE_INTERVAL"
done
