# hermes-install-test

Hermes Agent 一键安装包的 **GitHub Actions 多系统安装测试** 仓库。

> 本仓库是测试镜像，只包含 `hermes_install/` 安装包目录 + CI workflow。源仓库在公司内网 Gitea，此处仅用于在 GitHub Actions 上跑多系统安装测试。

## 目录结构

```
hermes-install-test/
├── hermes_install/               # 安装包（从源仓库同步）
│   ├── scripts/
│   │   ├── _common.sh            # 公共函数库
│   │   ├── install.sh            # Linux/macOS 幂等安装器
│   │   ├── uninstall.sh          # Linux/macOS 卸载
│   │   ├── install-windows.ps1   # Windows 幂等安装器
│   │   └── uninstall-windows.ps1 # Windows 卸载
│   ├── offline-packages/         # 离线包（空壳，CI 走在线）
│   └── README.md
└── .github/workflows/install-test.yml   # 多系统测试 workflow
```

## CI 测试什么

在以下系统跑 `install → 验证 → 幂等二跑 → 卸载`：

| Job | Runner | 测什么 |
|-----|--------|--------|
| Ubuntu-x64 | ubuntu-latest | apt 分支、install.sh 主流程、幂等、卸载 |
| macOS | macos-latest | brew 分支、macOS 路径、LaunchAgent |
| UOS20-sim | python:3.11-slim 容器 | apt 分支、CC-Switch 预检跳过 |
| Windows-x64 | windows-latest | install-windows.ps1、MSI 安装/回滚、注册表 |

> CentOS 7/8 已 EOL 且官方源失效,不再支持。

测试统一用无人值守参数：
- `--skip-provider-config` / `-SKIP_PROVIDER_CONFIG`（跳过 AI 后端配置，不输 API Key）
- `--skip-autostart` / `-SKIP_AUTOSTART`（跳过 GUI 自动启动，无头环境必失败）
- `--skip-connectivity-test` / `-SKIP_CONNECTIVITY_TEST`（不真调 API）
- `--skip-browser-act` / `-SKIP_BROWSER_ACT`（不装 browser-act）
- `HERMES_CI=1` / `-CI`（跳过 Windows RunAs 提权，避免 UAC 卡死）

## 怎么看结果

1. push 后到仓库 **Actions** tab
2. 点最新的「安装测试」run
3. 看四个 job 是否绿；红的点进去看日志
4. 失败日志会自动上传为 artifact（`logs-*`），可下载完整日志

## 如何从源仓库同步 hermes_install

源仓库（公司内网）改了 `hermes_install/` 后，同步到本仓库：

```bash
# 在源仓库目录（含 hermes_install/ 的仓库根）
# 方式1：直接复制目录过来
cd /path/to/hermes-install-test
cp -r /path/to/source-repo/hermes_install ./hermes_install
git add hermes_install
git commit -m "sync: 同步 hermes_install 至 <源仓库 commit>"
git push
```

同步后 push 会自动触发 CI。

## 迭代修脚本

CI 红了之后：

1. 在 Actions 看 red job 的日志，定位失败 step
2. 回源仓库改 `hermes_install/scripts/` 下对应脚本
3. 同步到本仓库，push
4. 等 CI 重跑
5. 重复直到四个 job 全绿

## 备注

- GitHub runner 在境外，脚本里的国内 pip 镜像/ GitHub 代理可能比直连慢——这是预期行为，能跑通即说明逻辑正确。
- CC-Switch 是 GUI 应用，无头 runner 上自动启动必失败（已用 `--skip-autostart` 跳过）；CC-Switch 安装本身仍跑，正好验证预检/回滚逻辑。
- 离线包目录为空，CI 走在线下载，timeout 设 30 分钟。
