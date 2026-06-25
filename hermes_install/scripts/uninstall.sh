#!/bin/bash
# ============================================================
# Hermes Agent + 飞书CLI + CC-Switch Linux/macOS 合并卸载脚本
#
# 卸载内容：
#   - hermes-agent (pip uninstall)
#   - 飞书 CLI (删目录)
#   - CC-Switch (dpkg -r / rpm -e / 删 .app / 删 AppImage + 桌面文件)
#   - 环境变量 (/etc/profile, /etc/profile.d/hermes.sh, autostart)
#   - 安装目录
#   - 本次新装的系统依赖（读 installed-deps.txt，默认保留，确认才卸）
#   - 配置文件（--remove-config 才删 ~/.hermes）
#
# 用法: sudo bash uninstall.sh [--remove-config] [--remove-deps]
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

REMOVE_CONFIG=false
REMOVE_DEPS=false
for arg in "$@"; do
    case $arg in
        --remove-config) REMOVE_CONFIG=true ;;
        --remove-deps)   REMOVE_DEPS=true ;;
    esac
done

INSTALL_DIR="${INSTALL_DIR:-/usr/local/hermes}"
HERMES_HOME="${HERMES_HOME:-/var/lib/hermes}"

ensure_root "$@"
detect_platform

# macOS 默认数据目录与 Linux 不同（与 install.sh 保持一致）
if [[ "$OS_KIND" == "macos" ]] && [[ "$HERMES_HOME" == "/var/lib/hermes" ]]; then
    HERMES_HOME="/Library/Application Support/Hermes"
fi
DEPS_RECORD="${HERMES_HOME}/installed-deps.txt"

echo "========================================"
echo "  Hermes Agent 卸载 ($OS_KIND $ARCH)"
echo "========================================"
read -p "确认卸载？(y/N): " confirm
if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
    echo "取消卸载"
    exit 0
fi

# 卸载 Hermes Agent
info "卸载 Hermes Agent..."
# hermes 可能装在多个 python 环境里（macOS 上 install.sh 用 brew python@3.13 装的），
# 用所有可能的 python 解释器都试一遍卸载
uninstall_ok=false
for py in python3 python3.13 python3.12 python3.11 \
          /opt/homebrew/opt/python@3.13/bin/python3.13 \
          /opt/homebrew/opt/python@3.12/bin/python3.12 \
          /opt/homebrew/bin/python3.13 \
          /opt/homebrew/bin/python3.12 \
          /usr/local/opt/python@3.13/bin/python3.13 \
          /usr/local/opt/python@3.12/bin/python3.12 \
          /usr/local/bin/python3 \
          /usr/bin/python3; do
    if command -v "$py" &>/dev/null || [[ -x "$py" ]]; then
        if "$py" -m pip uninstall -y hermes-agent &>/dev/null; then
            info "通过 $py 卸载 hermes-agent 成功"
            uninstall_ok=true
        fi
    fi
done
# 也清理 venv 兜底装的 hermes
if [[ -d /opt/hermes-venv ]]; then
    if /opt/hermes-venv/bin/pip uninstall -y hermes-agent &>/dev/null; then
        info "通过 /opt/hermes-venv 卸载 hermes-agent 成功"
        uninstall_ok=true
    fi
fi
$uninstall_ok || warn "hermes-agent 卸载失败或未安装"

# 清理 hermes 残留：symlink、venv、记录文件、各 python bin 里的 console script
# 优先读 install.sh 记录的真实路径
recorded_bin=""
if [[ -f "$HERMES_HOME/.hermes-bin-path" ]]; then
    recorded_bin=$(cat "$HERMES_HOME/.hermes-bin-path" 2>/dev/null || true)
    if [[ -n "$recorded_bin" ]]; then
        rm -f "$recorded_bin" 2>/dev/null || true
        info "已删除 hermes 二进制: $recorded_bin"
    fi
fi
rm -f /usr/local/bin/hermes 2>/dev/null || true
rm -f /opt/homebrew/bin/hermes 2>/dev/null || true
# brew python 各版本的 bin 里的 hermes
for hb in /opt/homebrew/opt/python@3.*/bin/hermes /usr/local/opt/python@3.*/bin/hermes; do
    rm -f "$hb" 2>/dev/null || true
done
rm -f "$HERMES_HOME/.hermes-bin-path" 2>/dev/null || true
rm -rf /opt/hermes-venv 2>/dev/null || true

# 卸载飞书 CLI
info "卸载飞书 CLI..."
rm -rf "$INSTALL_DIR/lark" 2>/dev/null || true

# 卸载 CC-Switch
info "卸载 CC-Switch..."
if [[ "$OS_KIND" == "macos" ]]; then
    rm -rf /Applications/CC-Switch.app 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.cc-switch.app.plist" 2>/dev/null || true
else
    case "$PKGMGR" in
        apt)
            if dpkg -l 2>/dev/null | grep -q cc-switch; then
                dpkg -r cc-switch 2>/dev/null || apt-get remove -y cc-switch 2>/dev/null || true
            fi
            ;;
        yum|dnf)
            if rpm -q cc-switch &>/dev/null; then
                rpm -e cc-switch 2>/dev/null || yum remove -y cc-switch 2>/dev/null || true
            fi
            ;;
    esac
    rm -rf /opt/cc-switch 2>/dev/null || true
    rm -f /usr/share/applications/cc-switch.desktop 2>/dev/null || true
fi
# 清理自启动
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME=$(eval echo "~$SUDO_USER")
else
    REAL_HOME="$HOME"
fi
rm -f "$REAL_HOME/.config/autostart/cc-switch.desktop" 2>/dev/null || true

# 清理环境变量（精确匹配 install.sh 写入的行，避免误删无关行）
info "清理环境变量..."
if [[ "$OS_KIND" == "macos" ]]; then
    rm -f /etc/profile.d/hermes.sh 2>/dev/null || true
else
    # 只删 install.sh 追加的 PATH 行（含 INSTALL_DIR）和 HERMES_HOME 行
    sed -i "\#export PATH=\"$INSTALL_DIR:#d" /etc/profile 2>/dev/null || true
    sed -i '\#export HERMES_HOME=#d' /etc/profile 2>/dev/null || true
fi
rm -f /etc/paths.d/hermes 2>/dev/null || true

# 删除安装目录
info "删除安装目录..."
rm -rf "$INSTALL_DIR" 2>/dev/null || true

# 卸载本次新装的系统依赖（默认保留，确认才卸）
if [[ -f "$DEPS_RECORD" ]] && [[ -s "$DEPS_RECORD" ]]; then
    echo ""
    echo "本次安装新装了以下系统依赖（记录于 $DEPS_RECORD）："
    cat "$DEPS_RECORD"
    echo ""
    do_remove=false
    if [[ "$REMOVE_DEPS" == "true" ]]; then
        do_remove=true
    else
        read -p "是否一并卸载这些依赖？[y/N，默认 N 保留]: " dep_choice
        [[ "$dep_choice" =~ ^[Yy]$ ]] && do_remove=true
    fi
    if [[ "$do_remove" == "true" ]]; then
        info "卸载新装系统依赖..."
        pkg=""
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            # 幂等校验：包还在才卸
            case "$PKGMGR" in
                apt)
                    if dpkg -s "$pkg" &>/dev/null 2>&1; then
                        apt-get remove -y "$pkg" 2>/dev/null && info "已卸载 $pkg" || warn "卸载 $pkg 失败"
                    fi
                    ;;
                yum|dnf)
                    if rpm -q "$pkg" &>/dev/null; then
                        yum remove -y "$pkg" 2>/dev/null && info "已卸载 $pkg" || warn "卸载 $pkg 失败"
                    fi
                    ;;
                brew)
                    if brew list --formula -1 2>/dev/null | grep -qx "$pkg"; then
                        brew uninstall "$pkg" 2>/dev/null && info "已卸载 $pkg" || warn "卸载 $pkg 失败"
                    fi
                    ;;
            esac
        done < "$DEPS_RECORD"
        rm -f "$DEPS_RECORD" 2>/dev/null || true
    else
        info "保留系统依赖（如需卸载请加 --remove-deps 或交互输入 y）"
    fi
else
    info "无新装依赖清单（$DEPS_RECORD 不存在或为空），跳过依赖卸载"
fi

# 配置文件处理
CONFIG_PATH="$HOME/.hermes"
if [[ "$REMOVE_CONFIG" == "true" ]]; then
    rm -rf "$CONFIG_PATH" 2>/dev/null || true
    rm -rf "$HERMES_HOME" 2>/dev/null || true
    info "已删除配置文件"
else
    info "配置文件已保留: $CONFIG_PATH/config.yaml"
fi

echo "========================================"
echo "  ✅ 卸载完成!"
echo "========================================"
