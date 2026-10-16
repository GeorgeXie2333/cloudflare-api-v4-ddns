#!/usr/bin/env bash
# Cloudflare DDNS: 首次运行按提示配置，以后直接使用已保存的配置。
set -euo pipefail
umask 077

((BASH_VERSINFO[0] >= 4)) || { printf '需要 Bash 4 或更新版本。\n' >&2; exit 1; }
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cloudflare-ddns/config.json"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/cloudflare-ddns"
SCRIPT_SOURCE=${BASH_SOURCE[0]}
MODE=auto
CFKEY= CFZONE_NAME= CFRECORD_NAME=
CFRECORD_TYPE=A CFTTL=1 FORCE=false
KEY_ARG= ZONE_ARG= RECORD_ARG= TYPE_ARG= TTL_ARG=
INPUT_FD=0

info() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'HELP'
Cloudflare DDNS 中文配置向导

首次使用：bash cf-v4-ddns.sh
再次更新：bash cf-v4-ddns.sh --run
修改配置：bash cf-v4-ddns.sh --configure

选项：
  --configure          重新引导配置，回车保留原值
  --run                使用现有配置执行一次，不进行交互（适合定时任务）
  -c, --config 文件    指定配置文件，支持配置多个域名
  -k API_TOKEN         Cloudflare API 令牌（建议在向导中输入）
  -z example.com       Cloudflare 中的区域名称
  -h home.example.com  记录名称，也可填写 @ 或 home
  -t A|AAAA            IPv4 / IPv6，默认 A
  --ttl 秒数           1 表示自动，或填写 60～86400，默认 1
  -f true|false        忽略本地 IP 缓存，默认 false
  --help               显示帮助（-h 仍然用于记录名称）
HELP
}

while (($#)); do
  case "$1" in
    --help) usage; exit 0 ;;
    --configure) MODE=configure; shift ;;
    --run) MODE=run; shift ;;
    -k|-z|-h|-t|-f|-c|--config|--ttl)
      (($# >= 2)) || die "$1 后面缺少参数。使用 --help 查看帮助。"
      case "$1" in
        -k) KEY_ARG=$2 ;;
        -z) ZONE_ARG=$2 ;;
        -h) RECORD_ARG=$2 ;;
        -t) TYPE_ARG=$2 ;;
        -f) FORCE=$2 ;;
        -c|--config) CONFIG_FILE=$2 ;;
        --ttl) TTL_ARG=$2 ;;
      esac
      shift 2 ;;
    *) die "不认识的参数：$1。使用 --help 查看帮助。" ;;
  esac
done

[[ $CONFIG_FILE != *[[:cntrl:]]* && -n $CONFIG_FILE ]] || die '配置文件路径不能为空或包含控制字符。'
[[ $CONFIG_FILE == /* ]] || CONFIG_FILE="$PWD/$CONFIG_FILE"
[[ $DATA_DIR == /* && $DATA_DIR != *[[:cntrl:]]* ]] || die 'XDG_DATA_HOME 必须是绝对路径，且不能包含控制字符。'

open_input() {
  # 兼容下载后运行、进程替换和管道执行；没有终端时也可从标准输入读取。
  if [[ ! -t 0 ]] && { exec 3<>/dev/tty; } 2>/dev/null; then INPUT_FD=3; fi
}

ask() {
  local name=$1 label=$2 default=${3:-} secret=${4:-false} input_value
  printf '%s' "$label" >&2
  if [[ -n $default ]]; then
    if [[ $secret == true ]]; then printf ' [已保存，回车保留]' >&2
    else printf ' [%s]' "$default" >&2; fi
  fi
  printf '：' >&2
  if [[ $secret == true && -t $INPUT_FD ]]; then
    IFS= read -r -s -u "$INPUT_FD" input_value || die '输入已取消，未完成配置。'
    printf '\n' >&2
  else
    IFS= read -r -u "$INPUT_FD" input_value || die '未读到输入。请在终端运行脚本；定时任务请使用 --run。'
  fi
  printf -v "$name" '%s' "${input_value:-$default}"
}

yes() { [[ $1 == [yY] || $1 == [yY][eE][sS] || $1 == 是 ]]; }

as_admin() {
  if ((EUID == 0)); then "$@"; else sudo "$@"; fi
}

ensure_dependencies() {
  local allow_install=$1 dep answer manager= missing=()
  for dep in curl jq; do command -v "$dep" >/dev/null 2>&1 || missing+=("$dep"); done
  [[ -n ${missing[*]-} ]] || return 0
  [[ $allow_install == true ]] || die "缺少依赖：${missing[*]}。请先安装 curl 和 jq。"
  info "缺少依赖：${missing[*]}，需要先安装。"
  ask answer '是否使用系统包管理器安装？Y/n' Y
  yes "$answer" || die '请自行安装 curl 和 jq 后重新运行。'
  if ((EUID != 0)); then
    command -v sudo >/dev/null 2>&1 || die '自动安装需要 sudo；也可请管理员安装 curl 和 jq。'
  fi
  for dep in apt-get dnf yum apk pacman opkg; do
    if command -v "$dep" >/dev/null 2>&1; then manager=$dep; break; fi
  done
  case "$manager" in
    apt-get) as_admin apt-get update && as_admin apt-get install -y "${missing[@]}" ;;
    dnf|yum) as_admin "$manager" install -y "${missing[@]}" ;;
    apk) as_admin apk add --no-cache "${missing[@]}" ;;
    pacman) as_admin pacman -S --needed --noconfirm "${missing[@]}" ;;
    opkg) as_admin opkg update && as_admin opkg install "${missing[@]}" ;;
    *) die '无法识别包管理器，请自行安装 curl 和 jq。' ;;
  esac
  for dep in curl jq; do command -v "$dep" >/dev/null 2>&1 || die "依赖 $dep 安装失败。"; done
}

WIZARD=false
if [[ $MODE == configure ]] || { [[ $MODE == auto && ! -f $CONFIG_FILE ]] && [[ -z $KEY_ARG || -z $ZONE_ARG || -z $RECORD_ARG ]]; }; then
  WIZARD=true
  open_input
fi
ensure_dependencies "$WIZARD"

if [[ -e $CONFIG_FILE ]]; then
  [[ -f $CONFIG_FILE && -r $CONFIG_FILE ]] || die "无法读取配置文件：$CONFIG_FILE"
  jq -e 'type == "object" and
    (.api_token | type == "string" and length > 0) and
    (.zone | type == "string" and length > 0) and
    (.record | type == "string" and length > 0) and
    (.record_type == "A" or .record_type == "AAAA") and
    (.ttl | type == "number" and floor == .)' "$CONFIG_FILE" >/dev/null 2>&1 || die "配置文件格式有误：$CONFIG_FILE，请检查或移走该文件后重新配置。"
  CFKEY=$(jq -r '.api_token' "$CONFIG_FILE")
  CFZONE_NAME=$(jq -r '.zone' "$CONFIG_FILE")
  CFRECORD_NAME=$(jq -r '.record' "$CONFIG_FILE")
  CFRECORD_TYPE=$(jq -r '.record_type' "$CONFIG_FILE")
  CFTTL=$(jq -r '.ttl' "$CONFIG_FILE")
fi
CFKEY=${KEY_ARG:-$CFKEY}
CFZONE_NAME=${ZONE_ARG:-$CFZONE_NAME}
CFRECORD_NAME=${RECORD_ARG:-$CFRECORD_NAME}
CFRECORD_TYPE=${TYPE_ARG:-$CFRECORD_TYPE}
CFTTL=${TTL_ARG:-$CFTTL}

valid_domain() {
  local domain=$1 label labels
  [[ ${#domain} -le 253 && $domain == *.* && $domain != *..* && $domain != .* && $domain != *. ]] || return 1
  IFS=. read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
  done
}

normalize_record() {
  CFZONE_NAME=${CFZONE_NAME,,}
  CFZONE_NAME=${CFZONE_NAME%.}
  CFRECORD_NAME=${CFRECORD_NAME,,}
  CFRECORD_NAME=${CFRECORD_NAME%.}
  if [[ $CFRECORD_NAME == @ ]]; then CFRECORD_NAME=$CFZONE_NAME
  elif [[ $CFRECORD_NAME != *.* ]]; then CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"; fi
}

valid_record() {
  local domain=${CFRECORD_NAME#\*.}
  valid_domain "$domain" && [[ $domain == "$CFZONE_NAME" || $domain == *."$CFZONE_NAME" ]]
}

valid_ttl() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 == 1 || (10#$1 >= 60 && 10#$1 <= 86400))); }

if [[ $WIZARD == true ]]; then
  info '========== Cloudflare DDNS 配置向导 =========='
  info '按提示填写，方括号内为默认值，直接回车即可采用。按 Ctrl+C 取消。'
  info '创建 API 令牌：https://dash.cloudflare.com/profile/api-tokens'
  info '权限：区域 → 区域 → 读取、区域 → DNS → 编辑；区域资源选择你的域名。'
  while :; do
    ask CFKEY '1. API 令牌（输入不显示）' "$CFKEY" true
    [[ -n $CFKEY && $CFKEY != *[[:space:][:cntrl:]]* ]] && break
    info '令牌不能为空，也不能包含空格或换行，请重新输入。'
  done
  while :; do
    ask CFZONE_NAME '2. 主域名，例如 example.com' "$CFZONE_NAME"
    CFZONE_NAME=${CFZONE_NAME,,}; CFZONE_NAME=${CFZONE_NAME%.}
    valid_domain "$CFZONE_NAME" && break
    info '请输入主域名，不要带 https:// 或路径；中文域名请使用 Punycode。'
  done
  while :; do
    ask CFRECORD_NAME '3. 解析记录，@ 表示主域名，也可填 home 或完整域名' "${CFRECORD_NAME:-@}"
    normalize_record
    valid_record && break
    info "记录必须是 $CFZONE_NAME 或其子域名，请重新输入。"
    CFRECORD_NAME=
  done
  while :; do
    ask CFRECORD_TYPE '4. IP 类型：A=IPv4，AAAA=IPv6（也可输入 4 或 6）' "$CFRECORD_TYPE"
    CFRECORD_TYPE=${CFRECORD_TYPE^^}
    case "$CFRECORD_TYPE" in A|4) CFRECORD_TYPE=A; break ;; AAAA|6) CFRECORD_TYPE=AAAA; break ;; esac
    info '请输入 A、AAAA、4 或 6。'
  done
  while :; do
    ask CFTTL '5. TTL：1=自动，或 60～86400 秒' "$CFTTL"
    valid_ttl "$CFTTL" && break
    info 'TTL 必须为 1，或 60～86400 之间的整数。'
  done
fi

[[ -n $CFKEY && $CFKEY != *[[:space:][:cntrl:]]* ]] || die '缺少有效的 API 令牌，请运行 --configure。'
[[ -n $CFRECORD_NAME ]] || die '缺少记录名称，请运行 --configure。'
normalize_record
valid_domain "$CFZONE_NAME" || die '主域名格式有误，请使用 -z example.com 或 --configure。'
valid_record || die "记录名称必须属于 $CFZONE_NAME。"
CFRECORD_TYPE=${CFRECORD_TYPE^^}
[[ $CFRECORD_TYPE == A || $CFRECORD_TYPE == AAAA ]] || die '记录类型只能是 A 或 AAAA。'
valid_ttl "$CFTTL" || die 'TTL 必须为 1，或 60～86400 之间的整数。'
CFTTL=$((10#$CFTTL))
[[ $FORCE == true || $FORCE == false ]] || die '-f 只能填写 true 或 false。'

save_config() {
  local config_dir temp
  config_dir=$(dirname -- "$CONFIG_FILE")
  mkdir -p -- "$config_dir"
  temp=$(mktemp "$config_dir/.config.XXXXXX")
  # 不 source 配置文件；令牌作为 JSON 数据保存，不会被当成 Shell 命令执行。
  if ! printf '%s' "$CFKEY" | jq -Rs --arg zone "$CFZONE_NAME" --arg record "$CFRECORD_NAME" \
    --arg type "$CFRECORD_TYPE" --argjson ttl "$CFTTL" \
    '{api_token: ., zone: $zone, record: $record, record_type: $type, ttl: $ttl}' > "$temp"; then
    rm -f -- "$temp"
    die '保存配置失败。'
  fi
  chmod 600 "$temp"
  mv -f -- "$temp" "$CONFIG_FILE"
  info "配置已保存：$CONFIG_FILE（仅当前用户可读写）"
}

if [[ $WIZARD == true ]]; then
  save_config
  FORCE=true
fi

api() {
  local method=$1 path=$2 payload=${3:-} response errors
  local args=(--fail --silent --show-error --connect-timeout 10 --max-time 30
    --request "$method" --url "https://api.cloudflare.com/client/v4/$path"
    --header 'Content-Type: application/json')
  [[ -z $payload ]] || args+=(--data "$payload")
  # 从标准输入传认证头，避免令牌出现在 curl 的进程参数中。
  if ! response=$(printf 'Authorization: Bearer %s\n' "$CFKEY" | curl "${args[@]}" --header @-); then
    die 'Cloudflare 请求失败，请检查网络、API 令牌及区域权限。'
  fi
  if ! jq -e 'type == "object" and .success == true' <<< "$response" >/dev/null 2>&1; then
    errors=$(jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")' <<< "$response" 2>/dev/null) || errors='返回的内容不是有效 JSON'
    die "Cloudflare 操作失败：${errors:-未知错误}。请检查令牌权限、主域名和记录。"
  fi
  printf '%s' "$response"
}

valid_ipv4() {
  local octet parts
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$1"
  for octet in "${parts[@]}"; do
    [[ ${#octet} -le 3 ]] && ((10#$octet <= 255)) || return 1
  done
}

valid_ipv6() {
  local ip=$1 group groups left right count=0
  [[ $ip == *:* && $ip != *:::* && $ip =~ ^[0-9a-fA-F:]+$ ]] || return 1
  [[ $ip != :: ]] || return 0
  if [[ $ip == *::* ]]; then
    left=${ip%%::*}; right=${ip#*::}
    [[ $right != *::* && $left != :* && $left != *: && $right != :* && $right != *: ]] || return 1
    ip=${left:+$left:}$right
  else
    [[ $ip != :* && $ip != *: ]] || return 1
    count=8
  fi
  IFS=: read -r -a groups <<< "$ip"
  for group in "${groups[@]}"; do [[ $group =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1; done
  if ((count == 8)); then ((${#groups[@]} == 8)); else ((${#groups[@]} < 8)); fi
}

update_dns() {
  local wan_ip wan_site family checksum cache_file old_ip= response zone_id record_id count payload
  if [[ $CFRECORD_TYPE == A ]]; then wan_site=https://ipv4.icanhazip.com; family=--ipv4
  else wan_site=https://ipv6.icanhazip.com; family=--ipv6; fi
  info "正在获取公网 IP（$CFRECORD_TYPE）……"
  wan_ip=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 "$family" "$wan_site") || die '无法获取公网 IP，请检查网络及相应 IP 协议是否可用。'
  wan_ip=${wan_ip//$'\r'/}
  if [[ $CFRECORD_TYPE == A ]]; then valid_ipv4 "$wan_ip" || die '公网 IP 服务未返回有效的 IPv4 地址。'
  else valid_ipv6 "$wan_ip" || die '公网 IP 服务未返回有效的 IPv6 地址。'; fi

  mkdir -p -- "$DATA_DIR/cache"
  checksum=$(printf '%s\n' "$CFKEY" "$CFZONE_NAME" "$CFRECORD_NAME" "$CFRECORD_TYPE" "$CFTTL" | cksum)
  cache_file="$DATA_DIR/cache/${checksum%% *}.ip"
  if [[ -f $cache_file ]]; then old_ip=$(cat -- "$cache_file"); fi
  if [[ $FORCE == false && $wan_ip == "$old_ip" ]]; then
    info "公网 IP 未变化：$wan_ip，无需更新。"
    return 0
  fi

  response=$(api GET "zones?name=$CFZONE_NAME")
  jq -e '.result | type == "array"' <<< "$response" >/dev/null || die 'Cloudflare 返回的区域列表无效。'
  count=$(jq '.result | length' <<< "$response")
  [[ $count == 1 ]] || die "没有找到唯一的区域 $CFZONE_NAME，请检查主域名和令牌的区域读取权限。"
  zone_id=$(jq -er '.result[0].id | select(type == "string" and test("^[a-fA-F0-9]{32}$"))' <<< "$response") || die 'Cloudflare 返回的区域 ID 无效。'
  response=$(api GET "zones/$zone_id/dns_records?type=$CFRECORD_TYPE&name=$CFRECORD_NAME")
  jq -e '.result | type == "array"' <<< "$response" >/dev/null || die 'Cloudflare 返回的记录列表无效。'
  count=$(jq '.result | length' <<< "$response")
  [[ $count == 0 || $count == 1 ]] || die '同名同类型有多条记录，请先在 Cloudflare 中保留一条需要更新的记录。'
  if [[ $count == 0 ]]; then
    payload=$(jq -n --arg type "$CFRECORD_TYPE" --arg name "$CFRECORD_NAME" --arg ip "$wan_ip" --argjson ttl "$CFTTL" \
      '{type: $type, name: $name, content: $ip, ttl: $ttl, proxied: false}')
    response=$(api POST "zones/$zone_id/dns_records" "$payload")
    info "已创建：$CFRECORD_NAME → $wan_ip（$CFRECORD_TYPE）"
  else
    record_id=$(jq -er '.result[0].id | select(type == "string" and test("^[a-fA-F0-9]{32}$"))' <<< "$response") || die 'Cloudflare 返回的记录 ID 无效。'
    # PATCH 只改 IP 和 TTL，保留已有的小黄云代理、备注等设置。
    payload=$(jq -n --arg ip "$wan_ip" --argjson ttl "$CFTTL" '{content: $ip, ttl: $ttl}')
    response=$(api PATCH "zones/$zone_id/dns_records/$record_id" "$payload")
    info "已更新：$CFRECORD_NAME → $wan_ip（$CFRECORD_TYPE）"
  fi
  local temp
  temp=$(mktemp "$DATA_DIR/cache/.ip.XXXXXX")
  printf '%s\n' "$wan_ip" > "$temp"
  mv -f -- "$temp" "$cache_file"
}

shell_quote() {
  local value=${1//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

offer_cron() {
  local answer installed old_table error_file new_table marker checksum line cron_line
  if ! command -v crontab >/dev/null 2>&1; then
    info '未检测到 crontab，本次更新已完成。安装并启动 cron/crond 后，重新运行 --configure 即可设置自动更新。'
    return 0
  fi
  ask answer '是否启用每 5 分钟自动更新？Y/n' Y
  yes "$answer" || { info '已完成本次更新；以后可使用 --run 手动执行。'; return 0; }
  if [[ ! -f $SCRIPT_SOURCE ]]; then
    info '请先将脚本下载为本地文件再运行 --configure，以便保存定时任务使用的脚本。'
    return 0
  fi
  installed="$DATA_DIR/cf-v4-ddns.sh"
  local temp
  temp=$(mktemp "$DATA_DIR/.script.XXXXXX")
  cp -- "$SCRIPT_SOURCE" "$temp"
  chmod 700 "$temp"
  mv -f -- "$temp" "$installed"
  old_table=$(mktemp "$DATA_DIR/.cron-old.XXXXXX")
  error_file=$(mktemp "$DATA_DIR/.cron-error.XXXXXX")
  new_table=$(mktemp "$DATA_DIR/.cron-new.XXXXXX")
  if ! LC_ALL=C crontab -l > "$old_table" 2> "$error_file"; then
    if ! grep -q 'no crontab for' "$error_file"; then
      rm -f -- "$old_table" "$error_file" "$new_table"
      info '无法读取现有 crontab，未添加定时任务。请检查 crontab 是否可用后重试 --configure。'
      return 0
    fi
    : > "$old_table"
  fi
  checksum=$(printf '%s' "$CONFIG_FILE" | cksum)
  marker="# cloudflare-ddns:${checksum%% *}"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *" $marker" ]] || printf '%s\n' "$line" >> "$new_table"
  done < "$old_table"
  cron_line="*/5 * * * * XDG_DATA_HOME=$(shell_quote "${DATA_DIR%/cloudflare-ddns}") $(shell_quote "$BASH") $(shell_quote "$installed") --run --config $(shell_quote "$CONFIG_FILE") >> $(shell_quote "$DATA_DIR/ddns.log") 2>&1"
  cron_line=${cron_line//%/\\%}
  printf '%s %s\n' "$cron_line" "$marker" >> "$new_table"
  if crontab "$new_table"; then
    info "已添加每 5 分钟更新一次的定时任务。日志：$DATA_DIR/ddns.log"
    info '请确保系统的 cron/crond 服务正在运行。'
  else
    info '本次更新成功，但写入定时任务失败，请检查 crontab 权限后重试 --configure。'
  fi
  rm -f -- "$old_table" "$error_file" "$new_table"
}

update_dns
if [[ $WIZARD == true ]]; then offer_cron; fi
