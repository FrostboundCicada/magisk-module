#!/usr/bin/env python3
"""OnePlus Charging Fix - Web UI 预览服务器
提供 mock 数据，无需刷入模块即可预览 Web 管理界面
"""
import http.server
import json
import os
import re
import socketserver
import sys
import threading
import time
import random

WEB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")

# Mock 状态
mock_config = {
    "voltage_limit": 4400,
    "current_limit": 6000,
    "input_current_limit": 3000,
    "enable_fake_cycle": 1,
    "force_max_speed": 1,
}

mock_logs = [
    "2026-06-23 10:00:01: ===============================",
    "2026-06-23 10:00:01: OnePlus Charging Fix 服务启动",
    "2026-06-23 10:00:01: 设备: OP596DL1",
    "2026-06-23 10:00:01: 型号: PJZ110",
    "2026-06-23 10:00:01: ROM版本: ColorOS16",
    "2026-06-23 10:00:01: ===============================",
    "2026-06-23 10:00:01: 配置摘要:",
    "2026-06-23 10:00:01:   电压上限: 4400mV",
    "2026-06-23 10:00:01:   电流上限: 6000mA",
    "2026-06-23 10:00:01:   输入电流: 3000mA",
    "2026-06-23 10:00:01:   插拔伪装: 启用",
    "2026-06-23 10:00:01:   强制满速: 启用",
    "2026-06-23 10:00:01:   Web管理: 启用 (端口:8765)",
    "2026-06-23 10:00:01: ===============================",
    "2026-06-23 10:00:02: --- 备份原始充电参数 ---",
    "2026-06-23 10:00:02: 原始电压上限: 4350000 (/sys/class/power_supply/battery/constant_charge_voltage_max)",
    "2026-06-23 10:00:02: 原始电流上限: 4000000 (/sys/class/power_supply/battery/constant_charge_current_max)",
    "2026-06-23 10:00:02: 原始输入电流: 3000000 (/sys/class/power_supply/usb/input_current_limit)",
    "2026-06-23 10:00:02: 原始参数已备份到 original_params.conf",
    "2026-06-23 10:00:02: --- 备份完成 ---",
    "2026-06-23 10:00:03: --- 应用充电参数 ---",
    "2026-06-23 10:00:03: 应用电压上限: 4400mV (4400000uV)",
    "2026-06-23 10:00:03: 电压上限 [/sys/class/power_supply/battery/constant_charge_voltage_max]:",
    "2026-06-23 10:00:03:   修改前: 4350000",
    "2026-06-23 10:00:03:   修改后: 4400000",
    "2026-06-23 10:00:04: 电流上限 [/sys/class/power_supply/battery/constant_charge_current_max]:",
    "2026-06-23 10:00:04:   修改前: 4000000",
    "2026-06-23 10:00:04:   修改后: 6000000",
    "2026-06-23 10:00:04: --- 参数应用完成 ---",
    "2026-06-23 10:00:05: --- 强制满速充电已启用 ---",
    "2026-06-23 10:00:05: 将持续覆盖: 亮屏限速 / 温控降速 / 电量阶段限速",
    "2026-06-23 10:00:05: 强制满速初始应用完成",
    "2026-06-23 10:00:06: Web 管理界面已启动: http://localhost:8765",
    "2026-06-23 10:00:06: 局域网访问: http://192.168.1.100:8765",
    "2026-06-23 10:00:06: 进入主循环 (强制满速刷新: 10s, 插拔伪装: 120s)",
    "2026-06-23 10:02:06: 检测到快充协议: SUPERVOOC, 开始伪装插拔",
    "2026-06-23 10:02:06: 通过 /sys/class/power_supply/svooc/enable 关闭快充",
    "2026-06-23 10:02:09: 通过 /sys/class/power_supply/svooc/enable 恢复快充",
    "2026-06-23 10:02:09: 插拔伪装完成，快充协议将重新协商",
]


class MockHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    def do_GET(self):
        # 处理 API 请求
        if "/cgi-bin/api.sh" in self.path:
            self.handle_api()
        else:
            super().do_GET()

    def handle_api(self):
        # 解析 query string
        qs = ""
        if "?" in self.path:
            qs = self.path.split("?", 1)[1]

        params = {}
        for pair in qs.split("&"):
            if "=" in pair:
                k, v = pair.split("=", 1)
                params[k] = v

        action = params.get("action", "")

        if action == "status":
            level = random.randint(60, 85)
            temp = random.randint(35, 42)
            data = {
                "battery": {
                    "level": level,
                    "temp": temp,
                    "status": "Charging",
                    "health": "Good",
                },
                "charger": {
                    "type": "SUPERVOOC" if mock_config["force_max_speed"] else "USB_PD",
                    "current": f"{random.randint(4500, 5800)}mA",
                },
                "params": {
                    "voltage_max": "4.40V",
                    "current_max": "6000mA",
                },
            }
            self.send_json(data)

        elif action == "config":
            self.send_json(mock_config)

        elif action == "update":
            for key in ["voltage_limit", "current_limit", "input_current_limit",
                        "enable_fake_cycle", "force_max_speed"]:
                if key in params:
                    mock_config[key] = int(params[key])
            ts = time.strftime("%Y-%m-%d %H:%M:%S")
            mock_logs.append(f"{ts}: [Web UI] 配置已更新: 强制满速={mock_config['force_max_speed']} 插拔伪装={mock_config['enable_fake_cycle']}")
            mock_logs.append(f"{ts}: --- 检测到配置更新 (Web UI)，重新加载 ---")
            mock_logs.append(f"{ts}: --- 配置热重载完成 ---")
            self.send_json({"status": "ok", "message": "配置已更新"})

        elif action == "logs":
            self.send_json({"logs": mock_logs[-50:]})

        elif action == "restart":
            ts = time.strftime("%Y-%m-%d %H:%M:%S")
            mock_logs.append(f"{ts}: --- 收到重启信号，重启服务 ---")
            mock_logs.append(f"{ts}: --- 服务重启完成 ---")
            self.send_json({"status": "ok", "message": "重启信号已发送"})

        else:
            self.send_json({"error": "unknown action"})

    def send_json(self, data):
        body = json.dumps(data).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass  # 静默日志


def main():
    port = 8765
    if len(sys.argv) > 1:
        port = int(sys.argv[1])

    with socketserver.TCPServer(("", port), MockHandler) as httpd:
        print(f"OnePlus Charging Fix - Web UI 预览")
        print(f"访问: http://localhost:{port}")
        print(f"按 Ctrl+C 停止")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
