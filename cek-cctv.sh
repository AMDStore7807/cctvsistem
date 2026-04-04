#!/bin/bash
# =========================================================
# EDGE-GUARDIAN V4 - ISOLATED ARCHITECTURE
# Direktori Kerja: /home/cctv-sistem
# =========================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] ERROR: Skrip ini wajib dijalankan sebagai root (Gunakan sudo)."
  exit 1
fi

echo "[+] MEMULAI INSTALASI INFRASTRUKTUR CCTV DESA..."

# 1. PENGECEKAN & ISOLASI DIREKTORI KERJA
WORK_DIR="/home/cctv-sistem"
echo "[*] Menyiapkan direktori terisolasi di $WORK_DIR..."
if [ ! -d "$WORK_DIR" ]; then
    mkdir -p "$WORK_DIR"
    echo "[+] Direktori $WORK_DIR berhasil dibuat."
else
    echo "[+] Direktori $WORK_DIR sudah ada. Sistem akan menggunakan folder ini."
fi

# 2. PENGECEKAN DEPENDENCIES
echo "[*] Mengecek dependensi sistem..."
DEPS="ffmpeg wireguard curl jq nmap cron"
for DEP in $DEPS; do
    if ! command -v $DEP &> /dev/null; then
        echo "[-] $DEP tidak ditemukan. Menginstal..."
        apt-get update -y && apt-get install $DEP -y
    else
        echo "[+] $DEP sudah terinstal."
    fi
done

# 3. SETUP WIREGUARD CLIENT
echo "========================================================="
echo "[*] FASE SETUP VPN (WIREGUARD)"
echo "========================================================="
if [ ! -f /etc/wireguard/wg0.conf ]; then
    mkdir -p /etc/wireguard
    cd /etc/wireguard
    umask 077
    wg genkey | tee privatekey | wg pubkey > publickey
    
    STB_PRIV=$(cat privatekey)
    STB_PUB=$(cat publickey)
    
    echo "========================================================="
    echo "KUNCI PUBLIK STB ANDA (Masukkan ini ke Server VPS nanti):"
    echo -e "\e[1;32m$STB_PUB\e[0m"
    echo "========================================================="
    
    read -p "Masukkan IP Publik VPS Anda: " VPS_IP
    read -p "Masukkan Kunci Publik (Public Key) VPS: " VPS_PUB
    read -p "Masukkan IP VPN STB ini (misal: 10.8.0.2/24): " STB_VPN_IP
    
    cat << EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $STB_PRIV
Address = $STB_VPN_IP

[Peer]
PublicKey = $VPS_PUB
Endpoint = $VPS_IP:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
EOF
else
    echo "[+] WireGuard sudah terkonfigurasi. Melewati fase ini."
fi

# 4. INTEROGASI DATA NVR
echo "========================================================="
echo "[*] FASE PENGAITAN HARDWARE CCTV"
echo "========================================================="
read -p "Masukkan IP NVR/XVR (misal: 172.168.10.145): " NVR_IP
read -p "Masukkan Username NVR: " NVR_USER
read -s -p "Masukkan Password NVR: " NVR_PASS
echo ""
read -p "Masukkan IP Target MediaMTX (IP VPN VPS, misal: 10.8.0.1): " TARGET_IP

cat << EOF > $WORK_DIR/koneksi.env
IP_NVR="$NVR_IP"
USER_NVR="$NVR_USER"
PASS_NVR="$NVR_PASS"
IP_TARGET="$TARGET_IP"
EOF

# 5. MEMBUAT SCRIPT ENGINE (Autopusher)
echo "[*] Merakit mesin pemindai CCTV (autopusher.sh)..."
cat << 'EOF_SCRIPT' > $WORK_DIR/autopusher.sh
#!/bin/bash
# Pointer ke direktori kerja yang baru
source /home/cctv-sistem/koneksi.env

CH_TOTAL=$(curl -s --digest -u $USER_NVR:$PASS_NVR "http://$IP_NVR/cgi-bin/render.cgi?action=getLanguage&name=Language" | grep -o 'OK' || echo "FAIL")
TOTAL_SCAN=16
pkill ffmpeg

for (( i=1; i<=$TOTAL_SCAN; i++ ))
do
    IS_ONLINE=$(ffprobe -v error -rtsp_transport tcp -i "rtsp://$USER_NVR:$PASS_NVR@$IP_NVR:554/cam/realmonitor?channel=$i&subtype=1" -show_entries stream=codec_name -of csv=p=0 2>&1)
    
    if [[ $IS_ONLINE == *"h264"* ]]; then
        ffmpeg -hide_banner -loglevel error -rtsp_transport tcp \
          -i "rtsp://$USER_NVR:$PASS_NVR@$IP_NVR:554/cam/realmonitor?channel=$i&subtype=1" \
          -c:v copy -c:a libopus -b:a 48k \
          -f rtsp -rtsp_transport tcp "rtsp://$IP_TARGET:8554/desa_ch$i" &
    fi
done
wait
EOF_SCRIPT
chmod +x $WORK_DIR/autopusher.sh

# 6. MENJADIKAN SERVICE ABADI (Systemd)
echo "[*] Memasang layanan Systemd CCTV-Desa..."
cat << EOF > /etc/systemd/system/cctv-desa.service
[Unit]
Description=Layanan Push CCTV Desa dengan VPN
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

systemctl daemon-reload
systemctl enable cctv-desa

# 7. AUTO REBOOT FISIK (Pukul 03:00 Pagi)
echo "[*] Menanam jadwal Auto-Reboot fisik pada STB..."
crontab -l | grep -v '/sbin/reboot' > /tmp/cron_backup
echo "0 3 * * * /sbin/reboot" >> /tmp/cron_backup
crontab /tmp/cron_backup
rm /tmp/cron_backup
echo "[+] Auto-Reboot dijadwalkan setiap jam 03:00 pagi."

echo "========================================================="
echo "[+] SETUP SELESAI!"
echo "Semua file sistem kini diisolasi di: $WORK_DIR"
echo "========================================================="