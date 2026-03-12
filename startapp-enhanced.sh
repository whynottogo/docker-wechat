#!/bin/bash

# 增强版启动脚本 - 解决输入法消失问题
# 包含 fcitx 进程持续监控和自动恢复机制

# 设置输入法环境变量
export XMODIFIERS="@im=fcitx"
export GTK_IM_MODULE="fcitx"
export QT_IM_MODULE="fcitx"
export XIM_PROGRAM="fcitx"
export XIM="fcitx"

# Fedora 42 KDE Wayland 兼容性：强制使用 X11 后端
export GDK_BACKEND=x11
export QT_QPA_PLATFORM=xcb

# 确保显示和 DBus 环境正确
export DISPLAY=${DISPLAY:-:1}

# 优先复用基础镜像已经提供的 session bus，避免把 fcitx 指到不存在的地址。
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    export DBUS_SESSION_BUS_ADDRESS
elif [ "$(id -u)" = "0" ] && [ ! -d "/run/user/0" ]; then
    # 只有在没有现成 session bus 时，才退回到临时地址。
    export DBUS_SESSION_BUS_ADDRESS="unix:abstract=/tmp/dbus-session-$$"
else
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
fi

# 日志文件路径
LOG_FILE="/var/log/fcitx-monitor.log"
STARTUP_LOG="/tmp/fcitx_startup.log"
ERROR_LOG="/tmp/fcitx_error.log"

# 创建日志目录
mkdir -p /var/log
touch "$LOG_FILE"

# 日志函数
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
}

ensure_sogou_active() {
    # 对 noVNC / 浏览器场景，尽量保持输入法处于激活且为搜狗拼音。
    fcitx-remote -o 2>/dev/null || true
    fcitx-remote -s sogoupinyin 2>/dev/null || true
}

# 启动 D-Bus 守护进程
start_dbus() {
    if ! pgrep -x "dbus-daemon" > /dev/null; then
        log_message "启动 D-Bus 守护进程..."

        # 确保 D-Bus 依赖的目录存在
        if [[ "$DBUS_SESSION_BUS_ADDRESS" =~ unix:path=/run/user/([0-9]+)/bus ]]; then
            user_id="${BASH_REMATCH[1]}"
            mkdir -p "/run/user/$user_id"
            # 设置正确的权限
            chown "$user_id:$user_id" "/run/user/$user_id" 2>/dev/null || true
            chmod 700 "/run/user/$user_id" 2>/dev/null || true
        fi

        # 启动 D-Bus，添加重试机制
        local retry_count=0
        local max_retries=3

        while [ $retry_count -lt $max_retries ]; do
            dbus-daemon --session --fork --address="$DBUS_SESSION_BUS_ADDRESS" 2>"$ERROR_LOG"
            if [ $? -eq 0 ]; then
                log_message "D-Bus 守护进程启动成功"
                sleep 1  # 给 D-Bus 一点启动时间
                return 0
            else
                retry_count=$((retry_count + 1))
                log_error "D-Bus 启动尝试 $retry_count 失败"
                if [ $retry_count -lt $max_retries ]; then
                    sleep 2
                fi
            fi
        done

        log_error "D-Bus 守护进程启动失败，最终放弃"
        log_error "D-Bus 地址: $DBUS_SESSION_BUS_ADDRESS"
        log_error "D-Bus 用户: $(id)"
        cat "$ERROR_LOG" >> "$LOG_FILE" 2>&1
        return 1
    else
        log_message "D-Bus 守护进程已在运行"
        return 0
    fi
}

# 清理现有 fcitx 进程和套接字
cleanup_fcitx() {
    log_message "清理现有 fcitx 进程和套接字..."
    pkill -f fcitx 2>/dev/null || true
    rm -rf /tmp/fcitx-* 2>/dev/null || true
    rm -rf ~/.config/fcitx/socket 2>/dev/null || true
    sleep 1
}

# 创建 fcitx 套接字目录
create_fcitx_socket_dir() {
    mkdir -p ~/.config/fcitx/socket
    chmod 755 ~/.config/fcitx/socket
}

# 启动 fcitx 守护进程
start_fcitx() {
    log_message "启动 fcitx 守护进程..."

    # 首先确保 D-Bus 正在运行
    if ! pgrep -x "dbus-daemon" > /dev/null; then
        log_error "D-Bus 未运行，Fcitx 无法启动"
        return 1
    fi

    # 设置 XDG 变量以确保 fcitx 找到配置
    export XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
    export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/xdg-runtime-$$}
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

    # fcitx -d 会自行 daemonize，因此不能把启动命令返回的父进程退出误判为崩溃。
    if ! fcitx -d --enable=2 2>"$ERROR_LOG"; then
        log_error "Fcitx 启动命令执行失败"
        cat "$ERROR_LOG" >> "$LOG_FILE" 2>&1 || true
        return 1
    fi

    log_message "Fcitx 启动命令已执行，等待守护进程准备就绪..."

    # 改进的等待机制 - 检查多种状态指标
    timeout=30
    count=0
    ready=false

    while [ $count -lt $timeout ] && [ "$ready" = "false" ]; do
        # 使用多种方式检查 fcitx 状态
        FCITX_PID=$(pgrep -xo fcitx 2>/dev/null || true)
        fcitx_status=$(fcitx-remote 2>/dev/null || echo "ERROR")

        case "$fcitx_status" in
            "0"|"1"|"2")
                if [ -n "$FCITX_PID" ]; then
                    echo "$FCITX_PID" > /tmp/fcitx.pid
                fi
                log_message "Fcitx 已准备就绪，设置搜狗拼音为默认..."
                ready=true

                # 先激活输入法，再切到搜狗拼音。
                fcitx-remote -r 2>/dev/null || true
                ensure_sogou_active
                if fcitx-remote -s sogoupinyin 2>/dev/null; then
                    log_message "成功设置搜狗拼音为默认输入法"
                else
                    log_error "设置搜狗拼音为默认失败，将在 WeChat 启动后重试"
                fi
                ;;
            "ERROR"|*)
                if [ -n "$FCITX_PID" ]; then
                    log_message "尝试 $((count + 1)): Fcitx 进程已存在但尚未就绪..."
                else
                    log_message "尝试 $((count + 1)): Fcitx 尚未准备就绪..."
                fi
                ;;
        esac

        # 每5次尝试记录一次进程状态
        if [ $((count % 5)) -eq 0 ] && [ $count -gt 0 ]; then
            log_message "Fcitx 状态检查: PID=$FCITX_PID, 返回值=$fcitx_status"
        fi

        count=$((count + 1))
        sleep 1
    done

    if [ "$ready" = "false" ]; then
        log_error "Fcitx 在 $timeout 秒内未能初始化"
        log_error "Fcitx 错误详情:"
        cat "$ERROR_LOG" >> "$LOG_FILE" 2>&1 || true
        log_error "系统环境: DISPLAY=$DISPLAY, DBUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"
        if [ -n "${FCITX_PID:-}" ]; then
            log_error "进程状态: PID=$FCITX_PID, 运行状态=$(kill -0 "$FCITX_PID" 2>/dev/null && echo "存活" || echo "已退出")"
        else
            log_error "进程状态: 未发现 fcitx 守护进程"
        fi
        return 1
    fi

    return 0
}

# 检查 fcitx 进程是否健康
check_fcitx_health() {
    local fcitx_pid
    fcitx_pid=$(pgrep -xo fcitx 2>/dev/null || true)

    # 检查进程是否存在
    if [ -z "$fcitx_pid" ] || ! kill -0 "$fcitx_pid" 2>/dev/null; then
        log_error "Fcitx 守护进程不存在"
        return 1
    fi

    # 检查 fcitx 是否响应
    fcitx_status=$(fcitx-remote 2>/dev/null || echo "ERROR")
    if [ "$fcitx_status" != "0" ] && [ "$fcitx_status" != "1" ] && [ "$fcitx_status" != "2" ]; then
        log_error "Fcitx 进程存在但不响应"
        return 1
    fi

    return 0
}

# 重启 fcitx
restart_fcitx() {
    log_message "检测到 fcitx 异常，正在重启..."

    # 清理现有进程
    cleanup_fcitx

    # 重新启动
    create_fcitx_socket_dir
    if start_fcitx; then
        log_message "Fcitx 重启成功"

        # 尝试重新设置搜狗拼音为默认
        sleep 2
        ensure_sogou_active
        if fcitx-remote -s sogoupinyin 2>/dev/null; then
            log_message "重启后成功设置搜狗拼音为默认"
        else
            log_error "重启后设置搜狗拼音失败"
        fi
        return 0
    else
        log_error "Fcitx 重启失败"
        return 1
    fi
}

# fcitx 监控进程
fcitx_monitor() {
    log_message "启动 fcitx 监控进程，监控间隔 3 秒"

    while true; do
        if ! check_fcitx_health; then
            restart_fcitx
        else
            ensure_sogou_active
            # 可选：定期记录状态日志（每5分钟记录一次）
            if [ $(( $(date +%s) % 300 )) -eq 0 ]; then
                log_message "Fcitx 运行正常"
            fi
        fi
        sleep 3
    done
}

# 信号处理函数
cleanup() {
    log_message "接收到退出信号，正在清理..."

    # 停止监控进程
    if [ -n "$MONITOR_PID" ]; then
        kill "$MONITOR_PID" 2>/dev/null || true
    fi

    # 清理 fcitx 进程
    cleanup_fcitx

    log_message "清理完成，退出"
    exit 0
}

# 设置信号处理
trap cleanup SIGTERM SIGINT SIGQUIT

# 主程序
main() {
    log_message "=== 启动增强版 WeChat 容器 ==="
    log_message "系统信息: 用户=$(id), 显示=$DISPLAY, DBUS=$DBUS_SESSION_BUS_ADDRESS"

    # 启动 D-Bus
    if ! start_dbus; then
        log_error "D-Bus 启动失败，这将影响输入法功能"
        log_error "WeChat 将以无输入法模式启动"
        # 即使 D-Bus 失败也继续启动 WeChat，但记录状态
        fcitx_failed=true
    else
        fcitx_failed=false
    fi

    # 清理并初始化 fcitx
    cleanup_fcitx
    create_fcitx_socket_dir

    # 只有在 D-Bus 成功时才尝试启动 fcitx
    if [ "$fcitx_failed" = "false" ]; then
        # 启动 fcitx
        if ! start_fcitx; then
            log_error "Fcitx 初始化失败，但继续启动 WeChat"
            fcitx_failed=true
        else
            # 启动 fcitx 监控进程（后台）
            fcitx_monitor &
            MONITOR_PID=$!
            log_message "Fcitx 监控进程已启动 (PID: $MONITOR_PID)"
        fi
    fi

    # 等待系统稳定
    sleep 3

    # 启动 WeChat
    log_message "启动 WeChat..."

    if [ "$fcitx_failed" = "false" ]; then
        # 在 WeChat 启动后多次尝试激活并切换到搜狗输入法。
        (
            sleep 10
            retry=0
            while [ "$retry" -lt 5 ]; do
                ensure_sogou_active
                if fcitx-remote -s sogoupinyin 2>/dev/null; then
                    log_message "WeChat 启动后成功设置搜狗拼音"
                    exit 0
                fi
                retry=$((retry + 1))
                sleep 5
            done
            log_error "WeChat 启动后多次尝试切换搜狗拼音失败"
        ) &
    else
        # 如果 fcitx 失败，提供解决建议
        log_message "输入法不可用，建议检查容器配置:"
        log_message "1. 确保 Docker 用户 ID 设置正确"
        log_message "2. 检查容器权限配置"
        log_message "3. 验证 D-Bus 配置"
    fi

    # 启动 WeChat 主进程
    exec /usr/bin/wechat
}

# 执行主程序
main "$@"
