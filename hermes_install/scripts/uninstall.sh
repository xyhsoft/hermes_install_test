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
BASE_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

# 日志随安装包走：安装包路径下的 logs/ 目录
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/uninstall.log"

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
COMPONENTS_RECORD="${HERMES_HOME}/installed-components.txt"

# 辅助函数：判断组件是否由 install 脚本新装（记录在 installed-components.txt）
installed_by_script() {
    local name="$1"
    [[ -f "$COMPONENTS_RECORD" ]] || return 1
    grep -qxF "$name" "$COMPONENTS_RECORD" 2>/dev/null
}

echo "========================================"
echo "  Hermes Agent 卸载 ($OS_KIND $ARCH)"
echo "========================================"
read -p "确认卸载？(y/N): " confirm
if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
    echo "取消卸载"
    exit 0
fi

# 卸载 Hermes Agent（仅卸 install 脚本新装的，用户自己装的不动）
if installed_by_script "hermes-agent"; then
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
    $uninstall_ok && info "[OK] hermes-agent 卸载成功" || warn "[WARN] hermes-agent 卸载失败或未安装"

    # 清理 hermes 残留：symlink、venv、记录文件、各 python bin 里的 console script
    # 优先读 install.sh 记录的真实路径
    recorded_bin=""
    if [[ -f "$HERMES_HOME/.hermes-bin-path" ]]; then
        recorded_bin=$(cat "$HERMES_HOME/.hermes-bin-path" 2>/dev/null || true)
        if [[ -n "$recorded_bin" ]]; then
            rm -f "$recorded_bin" 2>/dev/null || true
            info "[OK] 已删除 hermes 二进制: $recorded_bin"
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
else
    info "[SKIP] hermes-agent 非本脚本安装，跳过卸载"
fi

# 卸载飞书 CLI（仅卸 install 脚本新装的）
if installed_by_script "lark"; then
    info "卸载飞书 CLI..."
    if [[ -d "$INSTALL_DIR/lark" ]]; then
        rm -rf "$INSTALL_DIR/lark" 2>/dev/null || true
        [[ -d "$INSTALL_DIR/lark" ]] && warn "[WARN] lark 目录未删干净" || info "[OK] lark 目录已删除"
    else
        info "[INFO] lark 目录不存在，跳过"
    fi
else
    info "[SKIP] lark 非本脚本安装，跳过卸载"
fi

# 卸载 CC-Switch（仅卸 install 脚本新装的，用户自己装的不动）
if installed_by_script "cc-switch"; then
    info "卸载 CC-Switch..."
    if [[ "$OS_KIND" == "macos" ]]; then
        if [[ -d /Applications/CC-Switch.app ]]; then
            rm -rf /Applications/CC-Switch.app 2>/dev/null || true
            info "[OK] 已删除 /Applications/CC-Switch.app"
        else
            info "[INFO] CC-Switch.app 不存在，跳过"
        fi
        rm -f "$HOME/Library/LaunchAgents/com.cc-switch.app.plist" 2>/dev/null || true
    else
        case "$PKGMGR" in
            apt)
                if dpkg -l 2>/dev/null | grep -q cc-switch; then
                    if dpkg -r cc-switch 2>/dev/null || apt-get remove -y cc-switch 2>/dev/null; then
                        info "[OK] cc-switch 已卸载(dpkg)"
                    else
                        warn "[WARN] cc-switch 卸载失败(dpkg)"
                    fi
                else
                    info "[INFO] dpkg 无 cc-switch 记录"
                fi
                ;;
            yum|dnf)
                if rpm -q cc-switch &>/dev/null; then
                    if rpm -e cc-switch 2>/dev/null || yum remove -y cc-switch 2>/dev/null; then
                        info "[OK] cc-switch 已卸载(rpm)"
                    else
                        warn "[WARN] cc-switch 卸载失败(rpm)"
                    fi
                else
                    info "[INFO] rpm 无 cc-switch 记录"
                fi
                ;;
        esac
        rm -rf /opt/cc-switch 2>/dev/null || true
        rm -f /usr/share/applications/cc-switch.desktop 2>/dev/null || true
    fi
else
    info "[SKIP] CC-Switch 非本脚本安装，跳过卸载"
fi
# 清理自启动（仅当 CC-Switch 是本脚本装的才清）
if installed_by_script "cc-switch"; then
    if [[ -n "${SUDO_USER:-}" ]]; then
        REAL_HOME=$(eval echo "~$SUDO_USER")
    else
        REAL_HOME="$HOME"
    fi
    rm -f "$REAL_HOME/.config/autostart/cc-switch.desktop" 2>/dev/null || true
fi

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
    info "[OK] 已删除配置文件"
else
    info "[INFO] 配置文件已保留: $CONFIG_PATH/config.yaml"
fi

# ---- 卸载后验证 ----
info "========== 卸载后验证 =========="
uninst_passed=0
uninst_failed=0

# hermes 应不可用
if command -v hermes &>/dev/null && hermes --version &>/dev/null 2>&1; then
    warn "[FAIL] hermes 仍可用"; uninst_failed=$((uninst_failed+1))
else
    info "[PASS] hermes 已卸载"; uninst_passed=$((uninst_passed+1))
fi

# 安装目录应删除
if [[ -d "$INSTALL_DIR" ]]; then
    warn "[WARN] 安装目录仍存在: $INSTALL_DIR"; uninst_failed=$((uninst_failed+1))
else
    info "[PASS] 安装目录已删除"; uninst_passed=$((uninst_passed+1))
fi

# CC-Switch：仅本脚本装的才验证卸载；用户自装的不验证（跳过卸载了）
if installed_by_script "cc-switch"; then
    if command -v cc-switch &>/dev/null || [[ -x /opt/cc-switch/CC-Switch.AppImage ]] || [[ -d /Applications/CC-Switch.app ]]; then
        warn "[WARN] CC-Switch 仍存在"; uninst_failed=$((uninst_failed+1))
    else
        info "[PASS] CC-Switch 已卸载"; uninst_passed=$((uninst_passed+1))
    fi
else
    info "[PASS] CC-Switch 非本脚本安装，未卸载（符合预期）"; uninst_passed=$((uninst_passed+1))
fi

if [[ "$uninst_failed" -eq 0 ]]; then
    info "✅ 卸载验证全部通过 ($uninst_passed 项)"
else
    warn "⚠️ 卸载验证部分失败（通过 $uninst_passed 项，警告 $uninst_failed 项）"
fi

# 清理组件记录文件
rm -f "$COMPONENTS_RECORD" 2>/dev/null || true

echo "========================================"
echo "  ✅ 卸载完成!"
echo "  📋 日志: $LOG_FILE"
echo "========================================"
