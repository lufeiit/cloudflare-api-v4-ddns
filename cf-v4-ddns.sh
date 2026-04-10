#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# ============================================================
# CloudFlare Dynamic DNS Updater (DDNS)
# ============================================================
# 功能：自动更新 CloudFlare DNS 记录到当前公网 IP
# 支持：IPv4 (A) / IPv6 (AAAA)、自动创建缺失记录、中文域名转码、日志记录
# 依赖：curl, grep, sed, logger, idn (可选，用于中文域名)
# ============================================================

# ------------------------------
# 日志函数（同时输出到 stderr 和 syslog）
# ------------------------------
log_info() {
    local msg="[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"
    echo "$msg" >&2
    logger -t "cf-ddns" "$msg"
}

log_error() {
    local msg="[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*"
    echo "$msg" >&2
    logger -t "cf-ddns" "$msg"
}

# ------------------------------
# 将中文域名转换为 Punycode（IDNA）
# 优先使用 idn 命令，其次使用 Python，否则直接返回原字符串（并警告）
# ------------------------------
to_punycode() {
    local domain="$1"
    local puny=""
    if command -v idn &>/dev/null; then
        puny=$(echo "$domain" | idn -a 2>/dev/null)
    elif command -v python3 &>/dev/null; then
        puny=$(python3 -c "import sys; print(sys.argv[1].encode('idna').decode())" "$domain" 2>/dev/null)
    elif command -v python &>/dev/null; then
        puny=$(python -c "import sys; print(sys.argv[1].encode('idna').decode())" "$domain" 2>/dev/null)
    else
        log_error "未找到 idn 或 python 命令，无法转换中文域名: $domain，将使用原字符串（可能导致 API 失败）"
        echo "$domain"
        return
    fi
    if [[ -z "$puny" ]]; then
        log_error "域名转换 Punycode 失败: $domain"
        echo "$domain"
    else
        echo "$puny"
    fi
}

# ------------------------------
# 检查 IP 地址是否合法（IPv4 或 IPv6 简单格式）
# ------------------------------
is_valid_ip() {
    local ip="$1"
    local type="$2"   # A 或 AAAA
    if [[ "$type" == "A" ]]; then
        # IPv4: 点分十进制，4段 0-255
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            local IFS=.
            local -a octets=($ip)
            for octet in "${octets[@]}"; do
                if (( octet < 0 || octet > 255 )); then
                    return 1
                fi
            done
            return 0
        fi
        return 1
    elif [[ "$type" == "AAAA" ]]; then
        # IPv6: 简单检查是否包含 : 且长度足够（不做完整校验）
        if [[ "$ip" =~ : && ${#ip} -ge 3 ]]; then
            return 0
        fi
        return 1
    else
        return 1
    fi
}

# ------------------------------
# 默认配置（可通过命令行覆盖）
# ------------------------------
CFKEY=
CFUSER=
CFZONE_NAME=
CFRECORD_NAME=
CFRECORD_TYPE=A
CFTTL=60
FORCE=false

# IP 获取站点（支持 IPv4 / IPv6 自动切换）
WANIPSITE_IPV4="http://ipv4.icanhazip.com"
WANIPSITE_IPV6="http://ipv6.icanhazip.com"

# ------------------------------
# 解析命令行参数
# ------------------------------
while getopts k:u:h:z:t:f: opts; do
    case ${opts} in
        k) CFKEY=${OPTARG} ;;
        u) CFUSER=${OPTARG} ;;
        h) CFRECORD_NAME=${OPTARG} ;;
        z) CFZONE_NAME=${OPTARG} ;;
        t) CFRECORD_TYPE=${OPTARG} ;;
        f) FORCE=${OPTARG} ;;
    esac
done

# ------------------------------
# 参数校验
# ------------------------------
if [[ -z "$CFKEY" ]]; then
    log_error "缺少 CloudFlare API Key，请通过 -k 提供，或修改脚本中的 CFKEY 变量"
    exit 2
fi
if [[ -z "$CFUSER" ]]; then
    log_error "缺少 CloudFlare 账户邮箱，请通过 -u 提供，或修改脚本中的 CFUSER 变量"
    exit 2
fi
if [[ -z "$CFRECORD_NAME" ]]; then
    log_error "缺少需要更新的主机名（-h），例如 ddns.example.com"
    exit 2
fi
if [[ -z "$CFZONE_NAME" ]]; then
    log_error "缺少 Zone 名称（-z），例如 example.com"
    exit 2
fi
if [[ "$CFRECORD_TYPE" != "A" && "$CFRECORD_TYPE" != "AAAA" ]]; 键，然后
    log_error "记录类型（-t）只能是 A（IPv4）或 AAAA（IPv6）"
    exit 2
fi

# 转换中文域名为 Punycode
CFZONE_NAME_PUNY=$(to_punycode "$CFZONE_NAME")
CFRECORD_NAME_PUNY=$(to_punycode "$CFRECORD_NAME")
log_info "原始 Zone: $CFZONE_NAME -> Punycode: $CFZONE_NAME_PUNY"
log_info "原始 Host: $CFRECORD_NAME -> Punycode: $CFRECORD_NAME_PUNY"

# 如果主机名不是 FQDN，则自动补全 Zone 后缀
if [[ "$CFRECORD_NAME_PUNY" != "$CFZONE_NAME_PUNY" ]] && [[ ! "$CFRECORD_NAME_PUNY" == *".$CFZONE_NAME_PUNY" ]]; then
    CFRECORD_NAME_PUNY="$CFRECORD_NAME_PUNY.$CFZONE_NAME_PUNY"
    log_info "主机名非 FQDN，已自动补全为: $CFRECORD_NAME_PUNY"
fi

# ------------------------------
# 获取当前公网 IP
# ------------------------------
if [[ "$CFRECORD_TYPE" == "A" ]]; then
    WANIPSITE="$WANIPSITE_IPV4"
else
    WANIPSITE="$WANIPSITE_IPV6"
fi

log_info "正在从 $WANIPSITE 获取 $CFRECORD_TYPE 地址..."
WAN_IP=$(curl -s --connect-timeout 10 --max-time 15 "$WANIPSITE" | tr -d '[:space:]')
if [[ -z "$WAN_IP" ]]; then
    log_error "获取公网 IP 失败（返回为空），请检查网络或更换 WANIPSITE"
    exit 1
fi

if ! is_valid_ip "$WAN_IP" "$CFRECORD_TYPE"; then
    log_error "获取到的 IP 地址无效: $WAN_IP (类型 $CFRECORD_TYPE)"
    exit 1
fi
log_info "当前公网 IP: $WAN_IP"

# ------------------------------
# 读取上次保存的 IP（避免频繁更新）
# ------------------------------
WAN_IP_FILE="$HOME/.cf-wan_ip_${CFRECORD_NAME_PUNY}.txt"
OLD_WAN_IP=""
if [[ -f "$WAN_IP_FILE" ]]; then
    OLD_WAN_IP=$(cat "$WAN_IP_FILE")
    log_info "上次记录的 IP: $OLD_WAN_IP"
else
    log_info "未找到上次 IP 记录文件，将执行更新"
fi

if [[ "$WAN_IP" == "$OLD_WAN_IP" && "$FORCE" != "true" ]]; then
    log_info "IP 地址未发生变化，且未强制更新，脚本退出。"
    exit 0
fi

# ------------------------------
# 获取 Zone ID 和 Record ID（修复 errexit 导致的退出问题）
# ------------------------------
ID_FILE="$HOME/.cf-id_${CFRECORD_NAME_PUNY}.txt"
CFZONE_ID=""
CFRECORD_ID=""

# 如果缓存文件存在且内容完整，则读取
if [[ -f "$ID_FILE" ]] && [[ $(wc -l < "$ID_FILE") -eq 4 ]]; then
    # 使用 read 按行读取
    {
        read -r cached_zone_id
        read -r cached_record_id
        read -r cached_zone_name
        read -r cached_record_name
    } < "$ID_FILE"
    if [[ "$cached_zone_name" == "$CFZONE_NAME_PUNY" && "$cached_record_name" == "$CFRECORD_NAME_PUNY" ]]; then
        CFZONE_ID="$cached_zone_id"
        CFRECORD_ID="$cached_record_id"
        log_info "使用缓存的 Zone ID: $CFZONE_ID, Record ID: $CFRECORD_ID"
    else
        log_info "缓存文件中的 Zone 或 Record 名称不匹配，将重新获取"
    fi
fi

# 如果没有有效缓存，则从 API 获取
if [[ -z "$CFZONE_ID" ]]; then
    log_info "正在获取 Zone ID (域名: $CFZONE_NAME_PUNY)..."
    ZONE_RESP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME_PUNY" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json")
    # 提取第一个 id，使用 || true 防止 grep 无匹配时触发 errexit
    CFZONE_ID=$(echo "$ZONE_RESP" | grep -Po '(?<="id":")[^"]*' | head -1 || true)
    if [[ -z "$CFZONE_ID" ]]; then
        log_error "无法获取 Zone ID，请检查 API Key、邮箱以及 Zone 名称是否正确"
        log_error "API 响应: $ZONE_RESP"
        exit 1
    fi
    log_info "获取到 Zone ID: $CFZONE_ID"
fi

if [[ -z "$CFRECORD_ID" ]]; then
    log_info "正在获取 Record ID (记录: $CFRECORD_NAME_PUNY)..."
    RECORD_RESP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?name=$CFRECORD_NAME_PUNY" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json")
    # 提取 id，使用 || true 防止 grep 无匹配时触发 errexit
    CFRECORD_ID=$(echo "$RECORD_RESP" | grep -Po '(?<="id":")[^"]*' | head -1 || true)
    if [[ -z "$CFRECORD_ID" ]]; then
        log_info "未找到现存的 DNS 记录，将尝试自动创建..."
        # 创建记录
        CREATE_DATA=$(cat <<EOF
{
    "type": "$CFRECORD_TYPE",
    "name": "$CFRECORD_NAME_PUNY",
    "content": "$WAN_IP",
    "ttl": $CFTTL,
    "proxied": false
}
EOF
)
        CREATE_RESP=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records" \
            -H "X-Auth-Email: $CFUSER" \
            -H "X-Auth-Key: $CFKEY" \
            -H "Content-Type: application/json" \
            --data "$CREATE_DATA")
        if echo "$CREATE_RESP" | grep -q '"success":true'; then
            # 提取新创建的记录 ID
            CFRECORD_ID=$(echo "$CREATE_RESP" | grep -Po '(?<="id":")[^"]*' | head -1 || true)
            if [[ -z "$CFRECORD_ID" ]]; then
                log_error "创建记录成功但无法提取 Record ID"
                log_error "API 响应: $CREATE_RESP"
                exit 1
            fi
            log_info "DNS 记录创建成功！Record ID: $CFRECORD_ID"
        else
            log_error "创建 DNS 记录失败"
            log_error "API 响应: $CREATE_RESP"
            exit 1
        fi
    else
        log_info "获取到 Record ID: $CFRECORD_ID"
    fi
fi

# 更新缓存文件
{
    echo "$CFZONE_ID"
    echo "$CFRECORD_ID"
    echo "$CFZONE_NAME_PUNY"
    echo "$CFRECORD_NAME_PUNY"
} > "$ID_FILE"
log_info "已更新缓存文件: $ID_FILE"

# ------------------------------
# 更新 DNS 记录
# ------------------------------
log_info "正在更新 DNS 记录: $CFRECORD_NAME_PUNY ($CFRECORD_TYPE) -> $WAN_IP"
UPDATE_DATA=$(cat <<EOF
{
    "id": "$CFZONE_ID",
    "type": "$CFRECORD_TYPE",
    "name": "$CFRECORD_NAME_PUNY",
    "content": "$WAN_IP",
    "ttl": $CFTTL
}
EOF
)
UPDATE_RESP=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
    -H "X-Auth-Email: $CFUSER" \
    -H "X-Auth-Key: $CFKEY" \
    -H "Content-Type: application/json" \
    --data "$UPDATE_DATA")

if echo "$UPDATE_RESP" | grep -q '"success":true'; then
    log_info "DNS 记录更新成功！"
    echo "$WAN_IP" > "$WAN_IP_FILE"
    log_info "已将当前 IP 写入本地缓存: $WAN_IP_FILE"
else
    log_error "DNS 记录更新失败！"
    log_error "API 响应: $UPDATE_RESP"
    exit 1
fi

exit 0
