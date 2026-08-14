# onekey-cups — HP LaserJet P1008 打印服务器一键部署

在 PVE LXC（Debian 13）上用 Docker 部署 CUPS 打印服务器，支持 HP LaserJet P1008（host-based 打印机）自动固件加载、AirPrint 发现、局域网共享打印。

## 快速开始

### 第 0 步：手动创建 LXC（Debian 13）

PVE Web UI 操作：

1. **下载模板**：选中 PVE 节点 → `local` 存储 → `CT Templates` → `Templates` → 选 `debian-13-standard_13.x-1_amd64.tar.zst` → `Download`（列表里没有就先点 `Update` 刷新）
2. **创建容器**：右上角 `Create CT`
   - **General**：CT ID（如 210）、Hostname（如 Serv-Docker）、设置 root 密码（或粘贴 SSH 公钥）
   - **Template**：选中刚下载的 Debian 13 模板
   - **Disks**：rootfs ≥ 16GB（Docker 镜像占空间）
   - **CPU**：2 核足够（打印服务负载低）
   - **Memory**：≥ 1GB（建议 2GB）
   - **Network**：桥接 `vmbr0`，静态 IP（如 `192.168.50.20/24`）、网关 `192.168.50.2`、DNS `192.168.50.2`
   - 其余默认 → `Finish`
3. **启动并安装 Docker**（在 PVE 上执行）：
   ```bash
   pct start 210
   pct enter 210
   apt update && apt install -y docker.io docker-compose-plugin
   ```

### 第 1 步：手动直通 USB 打印机

**① 宿主机确认 USB 打印机**（PVE 上执行）：

```bash
lsusb
```

输出示例：

```
Bus 003 Device 006: ID 03f0:3d17 Hewlett-Packard LaserJet P1008
```

记下 **Bus 号**（例如 `003`，以下配置用 `003` 示例，按实际替换）。

**② 配置 LXC 容器 USB 直通**（PVE 上执行）：

```bash
nano /etc/pve/lxc/<CTID>.conf
```

在文件末尾加入：

```conf
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb/003 dev/bus/usb/003 none bind,optional,create=dir
```

> 直通的是整条 **USB 总线目录**（`/dev/bus/usb/003`），不是单个设备——设备号漂移（如 `006→004`）无需改配置，只要插在同一 Bus 上即可。

**③ 重启 LXC 生效并验证**：

```bash
pct reboot <CTID>
pct enter <CTID>
lsusb    # 应看到: Bus 003 Device ...: ID 03f0:4917 HP, Inc HP LaserJet P1008
```

### 第 2 步：一键部署

```bash
# 下载脚本到 PVE 宿主（注意：不支持 wget 管道方式，脚本需自我复制到 LXC）
wget https://raw.githubusercontent.com/guochan2019/onekey-cups/main/onekey-cups.sh
chmod +x onekey-cups.sh

# 一键部署（运行后交互输入 CTID，必填无默认值；再交互输入部署目录）
bash onekey-cups.sh
```

脚本自动完成：

```
检测打印机在线(PVE lsusb) → 检查 LXC 内打印机可见(直通已正确, 缺 usbutils 自动装)
→ 重启 LXC → pct push 脚本进 LXC → pct exec 执行部署
→ 创建 4 文件(Dockerfile/compose/entrypoint/cupsd.conf)
→ docker compose build(固件+PPD 构建时下载)
→ 启动 → 等打印机 → 固件检查(不在线跳过) → 建队列(固定URI)
→ 凭据/dbus → avahi → cupsd → 固件守护进程(每30秒, 开机后自动补载)
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

- 打印机平时可关机：开机后 30-60 秒内**固件守护进程自动补载**（每 30 秒检查 FWVER），直接打印，无需手动重启容器
- USB 设备号变化：整总线直通（`create=dir`）下 device 号漂移无需处理；**换了 USB 口（Bus 变化）**才需改 conf 的 `lxc.mount.entry` Bus 号并 `pct reboot <CTID>`
- 换打印机型号：改 Dockerfile 固件下载段（型号与 P1006 共用的映射见 getweb.in）+ PPD 文件名

## 部署产物

> 默认部署目录为 `/mnt/nvme1/appdata/cups`，脚本执行时会提示输入，**直接回车使用默认值**。

```
/mnt/nvme1/appdata/cups/
├── Dockerfile          # debian:13-slim + cups + printer-driver-foo2zjs + 固件 + PPD
├── docker-compose.yml  # host 网络 + privileged(USB cgroup) + /dev/bus/usb 挂载
├── entrypoint.sh       # 等打印机 → 固件检查(离线跳过) → 建队列 → dbus/avahi → cupsd + 固件守护
└── cupsd.conf          # 局域网匿名打印(AuthType None) + AirPrint
```

## 常见坑位（均已固化在脚本中）

1. docker devices cgroup 拒绝 USB open（`Failed to open device, code: -1`）→ `privileged: true`
2. Debian 的 foo2zjs 包用 pyppd 归档 PPD → 从 OpenPrinting 下载原始 `HP-LaserJet_P1008.ppd`
3. P1008 固件 = `sihpP1006.dl`（与 P1006 共用），源 `https://quirinux.org/printers/sihpP1006.tar.gz`
4. Debian 包无 hpljP1008 脚本 → 固件加载自写（CUPS usb backend + DEVICE_URI）
5. 容器无 udev → 固件加载靠 entrypoint 检查 + 常驻守护（每 30 秒查 FWVER）
6. `/run/dbus` 目录不存在 → entrypoint 先 `mkdir -p /run/dbus`
7. **`/run/dbus/pid` 残留 → dbus 拒绝启动 → 容器重启死循环** → dbus 前 `rm -f /run/dbus/pid /run/dbus/system_bus_socket`
8. CUPS 2.4 默认 Basic 认证 → 打印 Limit 段 `AuthType None` + `Allow all`
9. AirPrint 需要 avahi 多播 → `network_mode: host`（ports 映射会失效）
10. `pct set --dev0` 与手动整总线直通冲突 → LXC 启动失败（autodev hooks）→ 直通统一用手动 conf 配置
11. LXC 缺 usbutils → 检查误报"未检测到打印机" → 脚本自动安装（幂等）
12. 打印机平时关机 → 启动时固件加载跳过（不再崩溃循环），开机后守护 30-60 秒自动补载
