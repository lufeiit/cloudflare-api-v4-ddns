#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# Automatically update your CloudFlare DNS record to the IP, Dynamic DNS
# Can retrieve cloudflare Domain id and list zone's, because, lazy

# Place at:
# curl https://raw.githubusercontent.com/aipeach/cloudflare-api-v4-ddns/dev/cf-v4-ddns.sh > /usr/local/bin/cf-ddns.sh && chmod +x /usr/local/bin/cf-ddns.sh
# run `crontab -e` and add next line:
# */1 * * * * /usr/local/bin/cf-ddns.sh >/dev/null 2>&1
# or you need log:
# */1 * * * * /usr/local/bin/cf-ddns.sh >> /var/log/cf-ddns.log 2>&1


# Usage:
# cf-ddns.sh -k cloudflare-api-key \
#            -h host.example.com \     # fqdn of the record you want to update
#            -z example.com \          # will show you all zones if forgot, but you need this
#            -t A|AAAA                 # specify ipv4/ipv6, default: ipv4

# Optional flags:
#            -f false|true \           # force dns update, disregard local stored ip

# default config

# API key, see https://dash.cloudflare.com/profile/api-tokens,
# incorrect api-key results in E_UNAUTH error
CFKEY=

# Zone name, eg: example.com
CFZONE_NAME=

# Hostname to update, eg: homeserver.example.com
CFRECORD_NAME=

# Record type, A(IPv4)|AAAA(IPv6), default IPv4
CFRECORD_TYPE=A

# Cloudflare TTL for record, between 120 and 86400 seconds
CFTTL=60

# Ignore local file, update ip anyway
FORCE=false

# 根据类型设置 IP 获取地址
if [ "$CFRECORD_TYPE" = "A" ]; then
    WANIPSITE="http://ipv4.icanhazip.com"
elif [ "$CFRECORD_TYPE" = "AAAA" ]; then
    WANIPSITE="http://ipv6.icanhazip.com"
else
    echo "错误: 记录类型必须是 A 或 AAAA"
    exit 2
fi

# 参数解析
while getopts k:h:z:t:f: opts; do
  case ${opts} in
    k) CFKEY=${OPTARG} ;;
    h) CFRECORD_NAME=${OPTARG} ;;
    z) CFZONE_NAME=${OPTARG} ;;
    t) CFRECORD_TYPE=${OPTARG} ;;
    f) FORCE=${OPTARG} ;;
  esac
done

# 校验基础参数
if [ -z "$CFKEY" ] || [ -z "$CFRECORD_NAME" ] || [ -z "$CFZONE_NAME" ]; then
    echo "错误: 缺少必要参数 (Key, Hostname 或 Zone)"
    exit 2
fi

# 补全 FQDN
if [ "$CFRECORD_NAME" != "$CFZONE_NAME" ] && ! [[ "$CFRECORD_NAME" == *"$CFZONE_NAME" ]]; then
    CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
fi

# 1. 获取当前 WAN IP 并检测
WAN_IP=$(curl -s -m 10 "${WANIPSITE}" || echo "")
if [ -z "$WAN_IP" ]; then
    echo "错误: 无法获取当前的 $CFRECORD_TYPE 地址。请检查网络或该设备是否支持 IPv6。"
    exit 1
fi
echo "当前本地 IP: $WAN_IP"

# 2. 获取 Zone ID
CFZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" \
    -H "Authorization: Bearer $CFKEY" \
    -H "Content-Type: application/json" | grep -Eo '"id":"[^"]*' | sed 's/"id":"//' | head -1)

if [ -z "$CFZONE_ID" ]; then
    echo "错误: 找不到 Zone $CFZONE_NAME，请检查 API Token 权限或 Zone 名称。"
    exit 1
fi

# 3. 获取 Record ID (检测是否存在)
CFRECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?name=$CFRECORD_NAME&type=$CFRECORD_TYPE" \
    -H "Authorization: Bearer $CFKEY" \
    -H "Content-Type: application/json" | grep -Eo '"id":"[^"]*' | sed 's/"id":"//' | head -1)

# 4. 执行 更新 或 创建
if [ -z "$CFRECORD_ID" ]; then
    echo "检测到子域名 $CFRECORD_NAME 不存在，正在自动创建..."
    # 使用 POST 协议创建新记录
    RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records" \
        -H "Authorization: Bearer $CFKEY" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\",\"ttl\":$CFTTL}")
else
    # 检查 IP 是否有变化 (简单对比，不依赖本地文件以提高可靠性)
    OLD_IP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
        -H "Authorization: Bearer $CFKEY" \
        -H "Content-Type: application/json" | grep -Eo '"content":"[^"]*' | sed 's/"content":"//')

    if [ "$WAN_IP" = "$OLD_IP" ] && [ "$FORCE" = false ]; then
        echo "IP 未变化，跳过更新。"
        exit 0
    fi

    echo "正在更新 $CFRECORD_NAME 的 IP..."
    # 使用 PUT 协议更新现有记录
    RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
        -H "Authorization: Bearer $CFKEY" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\",\"ttl\":$CFTTL}")
fi

# 5. 结果校验
if [[ "$RESPONSE" == *"\"success\":true"* ]]; then
    echo "操作成功！"
else
    echo "操作失败，API 返回结果:"
    echo "$RESPONSE"
    exit 1
fi
