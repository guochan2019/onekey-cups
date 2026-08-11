# onekey-cups — HP LaserJet P1008 打印服务器一键部署

在 PVE LXC（Debian 13）上用 Docker 部署 CUPS 打印服务器，支持 HP LaserJet P1008（host-based 打印机）自动固件加载、AirPrint 发现、局域网共享打印。

## 快速开始

前提：已新建 LXC（Debian 13）并安装 Docker，打印机 USB 线连接 PVE 宿主机。

```bash
# 下载脚本到 PVE 宿主（注意：不支持 wget 管道方式，脚本需自我复制到 LXC）
wget https://raw.githubusercontent.com/guochan2019/onekey-cups/main/onekey-cups.sh
chmod +x onekey-cups.sh

# 一键部署（<CTID> 换成 LXC 容器号，如 210）
bash onekey-cups.sh 210
```

脚本自动完成：

```
检测打印机(lsusb 自动解析设备号) → pct set 直通 USB → 重启 LXC
→ pct push 脚本进 LXC → pct exec 执行部署
→ 创建 4 文件(Dockerfile/compose/entrypoint/cupsd.conf)
→ docker compose build(固件+PPD 构建时下载)
→ 启动 → 等打印机 → FWVER 检查(有则跳过/无则加载固件)
→ 建队列 P1008 → 设管理密码 → avahi → cupsd
```

## 客户端连接

| 设备 | 方式 |
|------|------|
| Windows | 添加打印机 → IPP → `http://<LXC-IP>:631/printers/P1008` → 驱动 HP LaserJet P1008 |
| iPhone | AirPrint 自动发现 P1008 |
| Android | Mopria → 手动 IPP → `http://<LXC-IP>:631/printers/P1008` |
| Web 管理 | `http://<LXC-IP>:631` → 用户名 `root`，密码 `cupsadmin` |

## Web 管理界面

- 地址：`http://<LXC-IP>:631`（如 `http://192.168.50.20:631`）
- 用户名：`root`
- 密码：`cupsadmin`

> 打印共享本身匿名即可，无需登录；登录仅用于管理界面（添加/删除打印机、改配置）。

## 验证命令

```bash
docker exec print-server lpstat -p                              # 队列状态
docker exec print-server lp -d P1008 /usr/share/cups/data/testprint   # 标准测试页
docker exec print-server lpstat -W all                          # 作业状态
docker exec print-server tail -40 /var/log/cups/error_log       # 错误日志
```

## 日常维护

- 打印机断电/重插：无需操作，容器启动自动检查 FWVER 并补载固件
- USB 设备号变化：重跑 `bash onekey-cups.sh <CTID>`（脚本自动解析新设备号）
- 换打印机型号：改 Dockerfile 固件下载段（型号与 P1006 共用的映射见 getweb.in）+ PPD 文件名

## 部署产物

```
/mnt/nvme1/appdata/cups/
├── Dockerfile          # debian:13-slim + cups + printer-driver-foo2zjs + 固件 + PPD
├── docker-compose.yml  # host 网络 + privileged(USB cgroup) + /dev/bus/usb 挂载
├── entrypoint.sh       # 等打印机 → 固件检查加载 → 建队列 → avahi → cupsd
└── cupsd.conf          # 局域网匿名打印(AuthType None) + AirPrint
```

## 常见坑位（均已固化在脚本中）

1. docker devices cgroup 拒绝 USB open（`Failed to open device, code: -1`）→ `privileged: true`
2. Debian 的 foo2zjs 包用 pyppd 归档 PPD → 从 OpenPrinting 下载原始 `HP-LaserJet_P1008.ppd`
3. P1008 固件 = `sihpP1006.dl`（与 P1006 共用），源 `https://quirinux.org/printers/sihpP1006.tar.gz`
4. Debian 包无 hpljP1008 脚本 → 固件加载自写（CUPS usb backend + DEVICE_URI）
5. 容器无 udev → entrypoint 每次启动检查 FWVER 决定是否加载固件
6. `/run/dbus` 目录不存在 → entrypoint 先 mkdir
7. CUPS 2.4 默认 Basic 认证 → 打印 Limit 段 `AuthType None` + `Allow all`
8. AirPrint 需要 avahi 多播 → `network_mode: host`（ports 映射会失效）
