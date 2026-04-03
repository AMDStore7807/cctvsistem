#!/bin/bash

# Load variabel dari file env yang kita buat tadi
source /home/root/koneksi.env

echo "===================================================="
echo "      SCANNER CCTV DESA - RADAR DIAGNOSTIK          "
echo "===================================================="
echo "Target NVR : $IP_NVR"
echo "User       : $USER_NVR"
echo "----------------------------------------------------"
printf "%-10s | %-10s | %-10s | %-10s\n" "CHANNEL" "STATUS" "CODEC" "RESOLUSI"
echo "----------------------------------------------------"

for (( i=1; i<=$CH_TOTAL; i++ ))
do
    # Jalankan ffprobe untuk cek stream dalam waktu 3 detik saja
    RESULT=$(ffprobe -v error -rtsp_transport tcp -select_streams v:0 \
        -show_entries stream=codec_name,width,height \
        -of csv=p=0 \
        "rtsp://$USER_NVR:$PASS_NVR@$IP_NVR:554/cam/realmonitor?channel=$i&subtype=1" 2>&1)

    if [[ $RESULT == *"Invalid data"* ]] || [[ $RESULT == *"404"* ]]; then
        printf "%-10s | %-10s | %-10s | %-10s\n" "CH $i" "OFFLINE" "-" "-"
    elif [[ $RESULT == *"401 Unauthorized"* ]]; then
        printf "%-10s | %-10s | %-10s | %-10s\n" "CH $i" "WRONG PASS" "-" "-"
    else
        # Parsing hasil: h264,1280,720
        CODEC=$(echo $RESULT | cut -d',' -f1)
        WIDTH=$(echo $RESULT | cut -d',' -f2)
        HEIGHT=$(echo $RESULT | cut -d',' -f3)
        
        # Beri peringatan jika masih H.265 (HEVC)
        if [[ $CODEC == "hevc" ]] || [[ $CODEC == "h265" ]]; then
            CODEC_OUT="!H265!"
        else
            CODEC_OUT="$CODEC"
        fi
        
        printf "%-10s | %-10s | %-10s | %-10sx%-10s\n" "CH $i" "ONLINE" "$CODEC_OUT" "$WIDTH" "$HEIGHT"
    fi
done
echo "----------------------------------------------------"