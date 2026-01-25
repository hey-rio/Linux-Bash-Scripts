#!/bin/bash

# ==============================================================================
# CONFIG TELEGRAM
# ==============================================================================
TELEGRAM_TOKEN=8076276713:AAGYYR9PQyP-l29Skd7mQS0897HsrTAOtZs
TELEGRAM_CHAT_ID=-5019262799


# ==============================================================================
# 1. SYSTEM INFO
# ==============================================================================
IP_ADDR=$(hostname -I | awk '{print $1}')
HOSTNAME=$(hostname)
UPTIME=$(uptime -p | sed 's/up //')
RAM_TOTAL=$(free -m | awk '/Mem:/ { print $2 }')
RAM_USED=$(free -m | awk '/Mem:/ { print $3 }')
RAM_PERCENT=$(awk "BEGIN {printf \"%.1f\", $RAM_USED*100/$RAM_TOTAL}")
CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/")
CPU_USAGE=$(awk "BEGIN {print 100 - $CPU_IDLE}")

# ==============================================================================
# 2. XỬ LÝ PJSIP (LOGIC: ONLY 'Avail' IS UP)
# ==============================================================================

if ! pgrep asterisk > /dev/null; then
    MSG="🚨 <b>CẢNH BÁO:</b> Asterisk trên $IP_ADDR KHÔNG CHẠY!"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d parse_mode="HTML" \
        -d text="$MSG" > /dev/null
    exit 1
fi

# Dùng show contacts để khớp với log CLI bạn cung cấp
RAW_DATA=$(rasterisk -x "pjsip show contacts" 2>/dev/null | grep "^  Contact:" | grep -v "<Aor")

TRUNK_UP=()
TRUNK_DOWN=()
EXT_ONLINE=()
EXT_OFFLINE_COUNT=0

while read -r line; do
    # Mẫu: Contact:  sip2ai/sip:...  NonQual   nan
    
    # 1. Lấy tên (Cắt trước dấu /) và làm sạch
    FULL_NAME=$(echo "$line" | awk '{print $2}')
    NAME_RAW=$(echo "$FULL_NAME" | cut -d'/' -f1)
    NAME=$(echo "$NAME_RAW" | tr -cd '[:alnum:]_-')

    if [ -z "$NAME" ]; then continue; fi

    # 2. XÁC ĐỊNH TRẠNG THÁI (STRICT MODE)
    # Điều kiện: Phải chứa chữ "Avail" VÀ KHÔNG chứa "Unavail".
    # NonQual -> Sẽ không thỏa mãn điều kiện này -> DOWN
    if [[ "$line" == *"Avail"* ]] && [[ "$line" != *"Unavail"* ]]; then
        STATUS="UP"
    else
        STATUS="DOWN"
    fi

    # 3. Phân loại
    if [[ "$NAME" =~ ^[0-9]+$ ]]; then
        # EXTENSION
        if [ "$STATUS" == "UP" ]; then
            EXT_ONLINE+=("$NAME")
        else
            ((EXT_OFFLINE_COUNT++))
        fi
    else
        # TRUNK
        if [ "$STATUS" == "UP" ]; then
            TRUNK_UP+=("$NAME")
        else
            TRUNK_DOWN+=("$NAME")
        fi
    fi
done <<< "$RAW_DATA"

# ==============================================================================
# 3. FORMAT TIN NHẮN (LIST DỌC)
# ==============================================================================
MSG="🤖 <b>BÁO CÁO: $HOSTNAME</b>%0A"
MSG+="IP: <code>$IP_ADDR</code>%0A"
MSG+="RAM: ${RAM_PERCENT}% | CPU: ${CPU_USAGE}%% | Up: $UPTIME%0A%0A"

MSG+="📡 <b>TRUNKS STATUS:</b>%0A"

# --- LIST DOWN ---
if [ ${#TRUNK_DOWN[@]} -gt 0 ]; then
    MSG+="🔴 <b>DOWN (${#TRUNK_DOWN[@]}):</b>%0A"
    for trunk in "${TRUNK_DOWN[@]}"; do
        MSG+="  • $trunk%0A"
    done
else
    MSG+="🔴 <b>DOWN:</b> -%0A"
fi

MSG+="%0A"

# --- LIST UP ---
if [ ${#TRUNK_UP[@]} -gt 0 ]; then
    MSG+="🟢 <b>UP (${#TRUNK_UP[@]}):</b>%0A"
    for trunk in "${TRUNK_UP[@]}"; do
        MSG+="  • $trunk%0A"
    done
else
    MSG+="🟢 <b>UP:</b> -%0A"
fi

MSG+="%0A"

# --- EXTENSIONS ---
MSG+="📞 <b>EXTENSIONS ONLINE:</b>%0A"
if [ ${#EXT_ONLINE[@]} -gt 0 ]; then
    LIST=$(IFS=', '; echo "${EXT_ONLINE[*]}")
    MSG+="✅ $LIST"
else
    MSG+="✅ (Không có)"
fi

# ==============================================================================
# 4. SEND
# ==============================================================================
curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d parse_mode="HTML" \
    -d text="$(echo -e "$MSG")" > /dev/null

echo "Done. Strict mode enforced."
