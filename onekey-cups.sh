#!/bin/bash
# ============================================================
# onekey-cups — HP LaserJet P1008 打印服务器一键部署
# 适用环境: PVE 宿主 + LXC(Debian 13) + Docker
# 功能: 检测打印机直通 → LXC 部署 CUPS 容器(自动固件加载) → 建立打印队列
# 用法: bash onekey-cups.sh <CTID>
#   例: bash onekey-cups.sh 210
# 前提: 已新建 LXC(Debian 13) 并安装 Docker; 已在 PVE Web UI 手动直通 USB 打印机
#      (LXC → Resources → Add → USB device → HP LaserJet P1008); 打印机 USB 连接 PVE
# ============================================================
set -euo pipefail

# ---------- 错误捕获 ----------
trap 'echo -e "\033[0;31m[ERROR] 脚本执行失败，请检查:\033[0m
  - 打印机是否通电并连接 PVE 的 USB 口
  - LXC 网络（需可访问 docker.io / quirinux.org / raw.githubusercontent.com）
  - 是否以 root 运行
  - 尝试: bash -x onekey-cups.sh <CTID>" >&2' ERR

# ---------- 彩色输出 ----------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- root 检测 ----------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 用户运行 (当前非 root)"
fi

# ============================================================
# LXC 内部署段（由 PVE 段 pct exec 调用，勿手动直接运行）
# ============================================================
if [ "${1:-}" = "lxc" ]; then
  info "等待 Docker 就绪"
  until docker info >/dev/null 2>&1; do sleep 2; done

  DIR="${2:-/mnt/nvme1/appdata/cups}"
  info "部署目录: $DIR"
  mkdir -p "$DIR"
  cd "$DIR"

  info "写入 Dockerfile"
  cat > Dockerfile <<'DOCKERFILE'
FROM debian:13-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    cups cups-client cups-filters cups-browsed \
    printer-driver-foo2zjs hp-ppd foomatic-db-compressed-ppds \
    openprinting-ppds smbclient avahi-daemon dbus \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# P1008 固件（与 P1006 共用）: 下载 -> arm2hpdl 转 .dl
RUN mkdir -p /lib/firmware/hp \
    && curl -fsSL -o /tmp/sihpP1006.tar.gz https://quirinux.org/printers/sihpP1006.tar.gz \
    && tar xzf /tmp/sihpP1006.tar.gz -C /tmp \
    && arm2hpdl /tmp/sihpP1006.img > /lib/firmware/hp/sihpP1006.dl \
    && rm -f /tmp/sihpP1006.tar.gz /tmp/sihpP1006.img
# P1008 PPD（Debian 包内被 pyppd 归档，需官方原始文件）
RUN curl -fsSL -o /usr/share/cups/model/HP-LaserJet_P1008.ppd \
    https://raw.githubusercontent.com/OpenPrinting/foo2zjs/master/PPD/HP-LaserJet_P1008.ppd
COPY cupsd.conf /etc/cups/cupsd.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
EXPOSE 631
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
DOCKERFILE

  info "写入 docker-compose.yml"
  cat > docker-compose.yml <<'COMPOSE'
services:
  print-server:
    build: .
    container_name: print-server
    restart: unless-stopped
    network_mode: host
    privileged: true
    volumes:
      - /dev/bus/usb:/dev/bus/usb
      - /sys/bus/usb:/sys/bus/usb:ro
    environment:
      - TZ=Asia/Shanghai
COMPOSE

  info "写入 entrypoint.sh"
  cat > entrypoint.sh <<'ENTRYPOINT'
#!/bin/sh
set -e

echo "[1/5] 设备权限"
chmod -R 666 /dev/bus/usb

echo "[2/5] 等待打印机就绪"
for i in $(seq 1 30); do
    /usr/lib/cups/backend/usb 2>/dev/null | grep -qi 'HP.*LaserJet.*P1008' && break
    sleep 1
done

echo "[3/5] 固件检查与加载"
FW=/lib/firmware/hp/sihpP1006.dl
if /usr/lib/cups/backend/usb 2>&1 | grep -q 'FWVER:'; then
    echo "固件已加载（FWVER 存在），跳过"
else
    URI=$(/usr/lib/cups/backend/usb 2>/dev/null | grep -i 'HP.*LaserJet.*P1008' | cut -d' ' -f2 | head -1)
    echo "加载固件: $FW -> $URI"
    DEVICE_URI="$URI" /usr/lib/cups/backend/usb 1 1 1 1 '' "$FW"
    sleep 3
fi

echo "[4/5] CUPS 启动 + 队列配置"
cupsd
sleep 2
URI=$(/usr/lib/cups/backend/usb 2>/dev/null | grep -i 'HP.*LaserJet.*P1008' | cut -d' ' -f2 | head -1)
lpadmin -p P1008 -E -v "$URI" -P /usr/share/cups/model/HP-LaserJet_P1008.ppd
lpadmin -p P1008 -o printer-is-shared=true
cupsenable P1008
cupsaccept P1008
kill "$(cat /run/cups/cupsd.pid)"
sleep 1

echo "[5/5] 管理凭据 + 打印发现服务"
echo 'root:cupsadmin' | chpasswd
mkdir -p /run/dbus
dbus-daemon --system
avahi-daemon -D --no-drop-root

exec cupsd -f
ENTRYPOINT

  info "写入 cupsd.conf"
  cat > cupsd.conf <<'CUPSD'
LogLevel warn
PageLogFormat
MaxLogSize 0
ErrorPolicy retry-job
Listen *:631
Listen /run/cups/cups.sock
ServerAlias *
Browsing Yes
BrowseLocalProtocols dnssd
DefaultAuthType Basic
DefaultEncryption IfRequested
WebInterface Yes
IdleExitTimeout 60
<Location />
  Order allow,deny
  Allow all
</Location>
<Location /admin>
  Order allow,deny
  Allow all
</Location>
<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow all
</Location>
<Location /admin/log>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow all
</Location>
<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default
  <Limit Create-Job Print-Job Print-URI Validate-Job>
    AuthType None
    Order deny,allow
    Allow all
  </Limit>
  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    AuthType None
    Order deny,allow
    Allow all
  </Limit>
  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>
  <Limit Pause-Printer Resume-Printer Enable-Printer Disable-Printer Pause-Printer-After-Current-Job Hold-New-Jobs Release-Held-New-Jobs Deactivate-Printer Activate-Printer Restart-Printer Shutdown-Printer Startup-Printer Promote-Job Schedule-Job-After Cancel-Jobs CUPS-Accept-Jobs CUPS-Reject-Jobs>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>
  <Limit Cancel-Job CUPS-Authenticate-Job>
    AuthType Default
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>
  <Limit All>
    Order deny,allow
    Allow all
  </Limit>
</Policy>
CUPSD

  info "构建并启动容器"
  docker compose up -d --build

  info "验证打印队列"
  docker exec print-server lpstat -p

  echo ""
  echo "========== 配置信息汇总 =========="
  echo "  CUPS Web 管理   : http://<LXC-IP>:631  (root / cupsadmin)"
  echo "  Windows IPP     : http://<LXC-IP>:631/printers/P1008"
  echo "  iPhone          : AirPrint 自动发现 P1008"
  echo "  Android         : Mopria 手动 IPP 同上"
  echo "  固件自动加载    : 容器启动检查 FWVER, 断电重开自动补载"
  echo "  打印机故障排查  : docker exec print-server lpstat -p"
  echo "==================================="
  exit 0
fi

# ============================================================
# PVE 宿主段（默认）
# ============================================================
CTID="${1:?用法: bash onekey-cups.sh <CTID>}"

read -p "LXC 内部署目录 (默认 /mnt/nvme1/appdata/cups): " INSTALL_DIR </dev/tty
INSTALL_DIR="${INSTALL_DIR:-/mnt/nvme1/appdata/cups}"
info "将在 LXC $CTID 内创建部署目录: $INSTALL_DIR (PVE 宿主机不受影响)"

# 脚本需自我复制到 LXC，必须文件方式运行（不支持 wget 管道）
SCRIPT=$(readlink -f "$0")
[ "$(basename "$SCRIPT")" = "onekey-cups.sh" ] || err "请下载脚本到本地文件后执行（脚本需自我复制到 LXC，不支持管道方式）"

info "检测打印机 (PVE 需已装 usbutils: apt install -y usbutils)"
lsusb | grep -i 'LaserJet P1008' || err "未检测到 HP LaserJet P1008, 请检查 USB 连接"
BUSDEV=$(lsusb | grep -i 'LaserJet P1008' | grep -oE 'Bus [0-9]+ Device [0-9]+' | awk '{print $2"/"$4}')
info "打印机位于: /dev/bus/usb/$BUSDEV"

info "检查 LXC $CTID 内是否已直通 USB 打印机 (需先在 PVE Web UI 手动添加)"
pct exec "$CTID" -- lsusb 2>/dev/null | grep -qi 'LaserJet P1008' || err "LXC $CTID 内未检测到打印机。请先手动直通:
  1) 确认 LXC $CTID 已启动
  2) PVE Web UI → 选中 LXC $CTID → Resources → Add → USB device → 选择 HP LaserJet P1008
  3) 打印机已通电并连接 PVE USB 口
  完成后重新运行本脚本"

info "重启 LXC $CTID (容器自动恢复)"
pct reboot "$CTID"
sleep 15

info "推送脚本到 LXC 并执行部署"
pct push "$CTID" "$SCRIPT" /root/onekey-cups.sh
pct exec "$CTID" -- bash /root/onekey-cups.sh lxc "$INSTALL_DIR"

echo ""
info "全部完成!"
