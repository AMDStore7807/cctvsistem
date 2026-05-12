#!/bin/bash
# ==============================================================================
# EDGE-GUARDIAN V6 - MASTER PROVISIONING SCRIPT (STB TO CLOUD)
# Tugas: Auto-Install, Auto-Discover NVR, API Handshake, Systemd Daemon Creation
# ==============================================================================

# ------------------------------------------------------------------------------
# [!] KONFIGURASI WAJIB (EDIT DI VSCODE SEBELUM EKSEKUSI)
# ------------------------------------------------------------------------------
# Kredensial baku NVR di seluruh desa (SOP Perusahaan)
SOP_NVR_USER="admin"
SOP_NVR_PASS="Admin123"

# Endpoint Control Plane (ExpressJS Anda di VPS)
API_URL="http://103.133.223.167:4000/api/provision"
API_TOKEN="BOS_SECRET_TOKEN_2026_SUPER_AMAN"
# ------------------------------------------------------------------------------

echo "[+] MEMULAI ZERO-TOUCH PROVISIONING (ZTP) STB..."

# 1. VALIDASI ROOT & KUNCI GANDA
if [ "$EUID" -ne 0 ]; then
  echo "[-] FATAL: Skrip ini wajib dijalankan sebagai root (Gunakan sudo)."
  exit 1
fi

WORK_DIR="/home/cctv-sistem"
if [ -f "$WORK_DIR/.provisioned" ]; then
    echo "[-] STB ini sudah dikonfigurasi sebelumnya. Eksekusi dibatalkan."
    echo "[-] Hapus $WORK_DIR/.provisioned jika ingin mereset."
    exit 0
fi

# 2. INSTALASI DEPENDENSI (Cerdas & Sekali Jalan)
echo "[*] Mengecek kelengkapan senjata mesin..."

MISSING_PKGS=""

# Pengecekan biner vs package yang akurat
if ! command -v ffmpeg &> /dev/null; then MISSING_PKGS+=" ffmpeg"; fi
if ! command -v wg &> /dev/null; then MISSING_PKGS+=" wireguard"; fi
if ! command -v curl &> /dev/null; then MISSING_PKGS+=" curl"; fi
if ! command -v jq &> /dev/null; then MISSING_PKGS+=" jq"; fi
if ! command -v nmap &> /dev/null; then MISSING_PKGS+=" nmap"; fi

if [ -n "$MISSING_PKGS" ]; then
    echo "[-] Ditemukan dependensi yang kurang:$MISSING_PKGS"
    echo "[*] Memperbarui repositori dan menginstal (Harap tunggu)..."
    apt-get update -y > /dev/null
    apt-get install -y $MISSING_PKGS > /dev/null
    echo "[+] Instalasi senjata tambahan selesai."
else
    echo "[+] Seluruh sistem dasar (FFmpeg, WireGuard, dll) sudah terinstal. Melewati fase ini."
fi

# 3. IDENTITAS HARDWARE (MAC ADDRESS)
mkdir -p $WORK_DIR
STB_SERIAL=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' || cat /sys/class/net/end0/address 2>/dev/null | tr -d ':')
if [ -z "$STB_SERIAL" ]; then
    STB_SERIAL=$(cat /proc/cpuinfo | grep Serial | awk '{print $3}')
fi
echo "[+] Serial/ID STB Terdeteksi: $STB_SERIAL"

# 4. AUTO-DISCOVERY NVR (Pemindaian Subnet Lokal)
echo "[*] Memindai jaringan lokal (Port 37777/554) untuk mencari NVR Dahua..."
SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1)
NVR_IP=$(nmap -p 37777,554 --open $SUBNET | grep "Nmap scan report" | awk '{print $NF}' | tr -d '()' | head -n 1)

if [ -z "$NVR_IP" ]; then
    echo "[-] FATAL: NVR tidak ditemukan di jaringan $SUBNET."
    exit 1
fi
echo "[+] NVR Ditemukan di IP: $NVR_IP"

# 5. PENCIPTAAN KUNCI ENKRIPSI
echo "[*] Menempa kunci VPN WireGuard..."
mkdir -p /etc/wireguard
cd /etc/wireguard
umask 077
wg genkey | tee privatekey | wg pubkey > publickey
STB_PRIV=$(cat privatekey)
STB_PUB=$(cat publickey)

# 6. HANDSHAKE KE CONTROL PLANE (EXPRESS JS)
echo "[*] Menghubungi Control Plane di awan..."
RESPONSE=$(curl -s -X POST $API_URL \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"$API_TOKEN\", \"serial\":\"$STB_SERIAL\", \"stbPublicKey\":\"$STB_PUB\"}")

IS_SUCCESS=$(echo $RESPONSE | jq -r '.success')

if [ "$IS_SUCCESS" != "true" ]; then
    echo "[-] FATAL: Registrasi API Ditolak oleh Server!"
    echo "[-] Pesan Error API: $(echo $RESPONSE | jq -r '.error')"
    exit 1
fi

VPS_PUB=$(echo $RESPONSE | jq -r '.vpsPublicKey')
VPS_ENDPOINT=$(echo $RESPONSE | jq -r '.vpsEndpoint')
STB_VPN_IP=$(echo $RESPONSE | jq -r '.stbVpnIp')
TARGET_IP=$(echo $RESPONSE | jq -r '.mediaMtxTarget')
PREFIX=$(echo $RESPONSE | jq -r '.streamPrefix')

echo "[+] Registrasi Sukses! Mendapat IP VPN: $STB_VPN_IP dan Jalur: $PREFIX"

# 7. MERAKIT ARSITEKTUR KONEKSI
echo "[*] Merakit file konfigurasi internal..."

# File Konfigurasi WireGuard
cat << EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $STB_PRIV
Address = $STB_VPN_IP

[Peer]
PublicKey = $VPS_PUB
Endpoint = $VPS_ENDPOINT
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
EOF

# File Variabel Lingkungan
cat << EOF > $WORK_DIR/koneksi.env
IP_NVR="$NVR_IP"
USER_NVR="$SOP_NVR_USER"
PASS_NVR="$SOP_NVR_PASS"
IP_TARGET="$TARGET_IP"
PREFIX="$PREFIX"
EOF

# 8. MERAKIT MESIN PENDORONG (AUTOPUSHER)
echo "[*] Merakit mesin Autopusher..."
cat << 'EOF_SCRIPT' > $WORK_DIR/autopusher.sh
#!/bin/bash
source /home/cctv-sistem/koneksi.env

TOTAL_SCAN=4 # Ubah ke 8 atau 16 jika STB kuat
pkill ffmpeg

for (( i=1; i<=$TOTAL_SCAN; i++ ))
do
    IS_ONLINE=$(ffprobe -v error -rtsp_transport tcp -i "rtsp://$USER_NVR:$PASS_NVR@$IP_NVR:554/cam/realmonitor?channel=$i&subtype=1" -show_entries stream=codec_name -of csv=p=0 2>&1)
    
    if [[ $IS_ONLINE == *"h264"* ]] || [[ $IS_ONLINE == *"hevc"* ]]; then
        ffmpeg -hide_banner -loglevel error -rtsp_transport tcp \
          -i "rtsp://$USER_NVR:$PASS_NVR@$IP_NVR:554/cam/realmonitor?channel=$i&subtype=1" \
          -c:v copy -c:a libopus -b:a 48k \
          -f rtsp -rtsp_transport tcp "rtsp://$IP_TARGET:8554/${PREFIX}_ch$i" &
    fi
done
wait
EOF_SCRIPT
chmod +x $WORK_DIR/autopusher.sh

# 9. PENCIPTAAN LAYANAN ABADI (SYSTEMD)
echo "[*] Menanamkan layanan ke dalam kernel OS..."
cat << EOF > /etc/systemd/system/cctv-pusher.service
[Unit]
Description=Layanan Pendorong Video CCTV
After=network.target wg-quick@wg0.service
Wants=wg-quick@wg0.service

[Service]
Type=simple
User=root
WorkingDirectory=$WORK_DIR
ExecStart=$WORK_DIR/autopusher.sh
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

# 10. EKSEKUSI MUTLAK & PENGUNCIAN
echo "[*] Menyalakan seluruh sistem operasi CCTV..."
systemctl daemon-reload

# Nyalakan VPN
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Tunggu 3 detik agar rute VPN mapan
sleep 3

# Nyalakan Pusher
systemctl enable cctv-pusher
systemctl start cctv-pusher

# Kunci skrip agar tidak dieksekusi ulang secara tak sengaja
touch $WORK_DIR/.provisioned

echo "========================================================================"
echo "[+] INSTALASI RAMPUNG, BOS!"
echo "[+] VPN Aktif, NVR Terdeteksi ($NVR_IP), FFmpeg Sedang Berjalan."
echo "[+] Cek log layanan jika butuh audit: journalctl -u cctv-pusher -f"
echo "========================================================================"