#!/system/bin/sh
# OnePlus Charging Fix - Web API CGI 处理脚本
# 处理前端请求，返回 JSON 数据

# CGI 输出 JSON 头
printf "Content-Type: application/json\r\n\r\n"

# 模块目录 (CGI 脚本在 web/cgi-bin/ 下，模块根目录是上两级)
MODDIR=$(cd "$(dirname "$0")/../.." && pwd)
LOGFILE="$MODDIR/charging_fix.log"
CONFIG_FILE="$MODDIR/charging_params.conf"

# 读取 sysfs
read_sysfs() {
    cat "$1" 2>/dev/null
}

# URL 解码
urldecode() {
    echo "$1" | sed 's/+/ /g;s/%20/ /g'
}

# 解析 query string 参数
get_param() {
    echo "$QUERY_STRING" | tr '&' '\n' | grep "^$1=" | cut -d'=' -f2
}

# 读取配置值
read_config() {
    grep "^$1=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2
}

# 获取电池状态
get_status() {
    local level temp status health
    level=$(read_sysfs /sys/class/power_supply/battery/capacity)
    [ -z "$level" ] && level=0
    temp=$(read_sysfs /sys/class/power_supply/battery/temp)
    # temp 是十分之一摄氏度
    if [ -n "$temp" ]; then
        temp=$((temp / 10))
    else
        temp=0
    fi
    status=$(read_sysfs /sys/class/power_supply/battery/status)
    [ -z "$status" ] && status="Unknown"
    health=$(read_sysfs /sys/class/power_supply/battery/health)
    [ -z "$health" ] && health="Unknown"

    # 充电类型
    local chg_type=""
    for path in \
        /sys/class/power_supply/usb/real_type \
        /sys/class/power_supply/battery/charge_type \
        /sys/class/power_supply/vooc/real_type \
        /sys/class/power_supply/svooc/real_type \
        /sys/class/power_supply/usb/type; do
        chg_type=$(read_sysfs "$path")
        if [ -n "$chg_type" ] && [ "$chg_type" != "Unknown" ] && [ "$chg_type" != "unknown" ]; then
            break
        fi
    done
    [ -z "$chg_type" ] && chg_type="Unknown"

    # 当前电流 (uA -> mA)
    local current=""
    for path in \
        /sys/class/power_supply/battery/current_now \
        /sys/class/power_supply/bms/current_now; do
        current=$(read_sysfs "$path")
        if [ -n "$current" ]; then
            # 负值表示充电，取绝对值
            current=${current#-}
            current=$((current / 1000))
            current="${current}mA"
            break
        fi
    done
    [ -z "$current" ] && current="--"

    # 电压上限
    local volt_max=""
    for path in \
        /sys/class/power_supply/battery/constant_charge_voltage_max \
        /sys/class/power_supply/battery/voltage_max; do
        volt_max=$(read_sysfs "$path")
        if [ -n "$volt_max" ]; then
            # uV -> V
            volt_max=$(awk "BEGIN{printf \"%.2fV\", $volt_max/1000000}")
            break
        fi
    done
    [ -z "$volt_max" ] && volt_max="--"

    # 电流上限
    local curr_max=""
    for path in \
        /sys/class/power_supply/battery/constant_charge_current_max \
        /sys/class/power_supply/main/constant_charge_current_max; do
        curr_max=$(read_sysfs "$path")
        if [ -n "$curr_max" ]; then
            curr_max=$(awk "BEGIN{printf \"%dmA\", $curr_max/1000}")
            break
        fi
    done
    [ -z "$curr_max" ] && curr_max="--"

    printf '{"battery":{"level":%s,"temp":%s,"status":"%s","health":"%s"},"charger":{"type":"%s","current":"%s"},"params":{"voltage_max":"%s","current_max":"%s"}}' \
        "$level" "$temp" "$status" "$health" "$chg_type" "$current" "$volt_max" "$curr_max"
}

# 获取配置
get_config() {
    local voltage_limit current_limit input_current_limit enable_fake_cycle force_max_speed
    voltage_limit=$(read_config "VOLTAGE_LIMIT")
    current_limit=$(read_config "CURRENT_LIMIT")
    input_current_limit=$(read_config "INPUT_CURRENT_LIMIT")
    enable_fake_cycle=$(read_config "ENABLE_FAKE_CYCLE")
    force_max_speed=$(read_config "FORCE_MAX_SPEED")

    [ -z "$voltage_limit" ] && voltage_limit=0
    [ -z "$current_limit" ] && current_limit=0
    [ -z "$input_current_limit" ] && input_current_limit=0
    [ -z "$enable_fake_cycle" ] && enable_fake_cycle=1
    [ -z "$force_max_speed" ] && force_max_speed=0

    printf '{"voltage_limit":%s,"current_limit":%s,"input_current_limit":%s,"enable_fake_cycle":%s,"force_max_speed":%s}' \
        "$voltage_limit" "$current_limit" "$input_current_limit" "$enable_fake_cycle" "$force_max_speed"
}

# 更新配置
update_config() {
    local force fake volt curr input
    force=$(get_param "force_max_speed")
    fake=$(get_param "enable_fake_cycle")
    volt=$(get_param "voltage_limit")
    curr=$(get_param "current_limit")
    input=$(get_param "input_current_limit")

    [ -z "$force" ] && force=0
    [ -z "$fake" ] && fake=1
    [ -z "$volt" ] && volt=0
    [ -z "$curr" ] && curr=0
    [ -z "$input" ] && input=0

    # 写入新配置
    cat > "$CONFIG_FILE" << EOF
# OnePlus Charging Fix 参数配置 (Web UI 更新)
# 更新时间: $(date '+%Y-%m-%d %H:%M:%S')

VOLTAGE_LIMIT=$volt
CURRENT_LIMIT=$curr
INPUT_CURRENT_LIMIT=$input
ENABLE_FAKE_CYCLE=$fake
FORCE_MAX_SPEED=$force
EOF

    # 创建 reload 标志，service.sh 主循环检测到后会重新加载
    touch "$MODDIR/reload"

    printf '{"status":"ok","message":"配置已更新，服务将自动重新加载"}'
}

# 获取日志
get_logs() {
    local lines=50
    local count
    count=$(get_param "count")
    [ -n "$count" ] && lines="$count"

    printf '{"logs":['
    if [ -f "$LOGFILE" ]; then
        tail -n "$lines" "$LOGFILE" 2>/dev/null | while IFS= read -r line; do
            printf '"%s",' "$(echo "$line" | sed 's/"/\\"/g;s/\\/\\\\/g')"
        done | sed 's/,$//'
    fi
    printf ']}'
}

# 重启服务
restart_service() {
    touch "$MODDIR/restart"
    printf '{"status":"ok","message":"重启信号已发送"}'
}

# 主逻辑
action=$(get_param "action")
case "$action" in
    status)  get_status ;;
    config)  get_config ;;
    update)  update_config ;;
    logs)    get_logs ;;
    restart) restart_service ;;
    *)       printf '{"error":"unknown action"}' ;;
esac
