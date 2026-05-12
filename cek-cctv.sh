#!/bin/bash
# =========================================================
# EDGE-GUARDIAN V5 - ZERO TOUCH PROVISIONING (ZTP)
# =========================================================

# 1. PENCEGAHAN EKSEKUSI GANDA
if [ -f "/home/cctv-sistem/.provisioned" ]; then
    echo "[-] STB ini sudah ter-provisioning. Keluar."
    exit 0
fi

# 2. EKSTRAKSI IDENTITAS HARDWARE (SERIAL)
# Menggunakan MAC Address eth0 tanpa titik dua (contoh: 0242ac110002)
STB_SERIAL=$(cat /sys/class/net/eth0/address | tr -d ':')
if [ -z "$STB_SERIAL" ]; then
    # Fallback jika eth0 tidak ada
    STB_SERIAL=$(cat /proc/cpuinfo | grep Serial | awk '{print $3}')
fi

WORK_DIR="/home/cctv-sistem"
mkdir -p $WORK_DIR

# 3. KREDENSIAL NVR BAKU (SOP PERUSAHAAN ANDA)
# Ini adalah harga mati. Hardware di lapangan HARUS disetting seperti ini
NVR_USER="admin"
NVR_PASS="Admin123"

# 4. AUTO-DISCOVERY IP NVR (Pemindaian Subnet)
echo "[*] Memindai subnet lokal untuk mencari NVR Dahua..."
# Ambil subnet STB saat ini (misal 192.168.1.0/24)
SUBNET=$(ip -o -f inet addr show eth0 | awk '/scope global/ {print $4}')
# Cari IP yang membuka port 37777 (Dahua) atau 554 (RTSP)
NVR_IP=$(nmap -p 37777 --open $SUBNET | grep "Nmap scan report" | awk '{print $NF}' | tr -d '()' | head -n 1)

if [ -z "$NVR_IP" ]; then
    echo "[-] FATAL: NVR tidak ditemukan di jaringan. ZTP Gagal."
    exit 1
fi
echo "[+] NVR Ditemukan di IP: $NVR_IP"

# 5. PEMBUATAN KUNCI WIREGUARD
mkdir -p /etc/wireguard
cd /etc/wireguard
umask 077
wg genkey | tee privatekey | wg pubkey > publickey
STB_PRIV=$(cat privatekey)
STB_PUB=$(cat publickey)

# 6. AUTO-REGISTRASI KE CONTROL PLANE EXPRESSJS
API_URL="http://103.133.223.167:3000/api/provision"
API_TOKEN="BOS_SECRET_TOKEN_2026_SUPER_AMAN"

echo "[*] Mendaftarkan Serial $STB_SERIAL ke Control Plane..."

RESPONSE=$(curl -s -X POST $API_URL \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"$API_TOKEN\", \"serial\":\"$STB_SERIAL\", \"stbPublicKey\":\"$STB_PUB\"}")

IS_SUCCESS=$(echo $RESPONSE | jq -r '.success')

if [ "$IS_SUCCESS" != "true" ]; then
    echo "[-] FATAL: Registrasi API Ditolak -> $(echo $RESPONSE | jq -r '.error')"
    exit 1
fi

VPS_PUB=$(echo $RESPONSE | jq -r '.vpsPublicKey')
VPS_ENDPOINT=$(echo $RESPONSE | jq -r '.vpsEndpoint')
STB_VPN_IP=$(echo $RESPONSE | jq -r '.stbVpnIp')
STREAM_PREFIX=$(echo $RESPONSE | jq -r '.streamPrefix')
TARGET_IP=$(echo $RESPONSE | jq -r '.mediaMtxTarget')

echo "[+] Registrasi Berhasil. IP VPN: $STB_VPN_IP, Prefix: $STREAM_PREFIX"

# 7. MERAKIT KONFIGURASI DAN SCRIPT STREAMING
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

cat << EOF > $WORK_DIR/koneksi.env
IP_NVR="$NVR_IP"
USER_NVR="$NVR_USER"
PASS_NVR="$NVR_PASS"
IP_TARGET="$TARGET_IP"
PREFIX="$STREAM_PREFIX"
EOF

# 8. MERAKIT AUTOPUSHER (Dengan Prefix URL Bebas Tumbukan)
cat << 'EOF_SCRIPT' > $WORK_DIR/autopusher.sh
#!/bin/bash
source /home/cctv-sistem/koneksi.env

TOTAL_SCAN=16
pkill ffmpeg

for (( i=1; i<=$TOTAL_SCAN; i++ ))
do
    IS_ONLINE=$(ffprobe -v error -rtsp_transport tcp -i "rtsp://$USER_NVR:$PASS_NVR@$IP_NVR:554/cam/realmonitor?channel=$i&subtype=1" -show_entries stream=codec_name -of csv=p=0 2>&1)
    
    if [[ $IS_ONLINE == *"h264"* ]]; then
        # PERHATIKAN: URL target menggunakan PREFIX dari ExpressJS
        ffmpeg -hide_banner -loglevel error -rtsp_transport tcp \
          -i "rtsp://$USER_NVR:$PASS_NVR@$IP_NVR:554/cam/realmonitor?channel=$i&subtype=1" \
          -c:v copy -c:a libopus -b:a 48k \
          -f rtsp -rtsp_transport tcp "rtsp://$IP_TARGET:8554/${PREFIX}_ch$i" &
    fi
done
wait
EOF_SCRIPT
chmod +x $WORK_DIR/autopusher.sh

# 9. EKSEKUSI DAN PENGUNCIAN SYSTEM
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# (Lewati pembuatan cctv-desa.service jika sudah ada di image awal, atau buat di sini seperti skrip sebelumnya)
systemctl start cctv-desa

touch $WORK_DIR/.provisioned
echo "[+] ZTP Selesai. Sistem Terkunci dan Sedang Streaming!"