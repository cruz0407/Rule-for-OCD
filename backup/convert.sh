#!/usr/bin/env bash
set -euo pipefail
# set -x   # 调试时可启用

#####################################
# 配置
#####################################
REPO_ROOT="$(pwd)"
LOCAL_DIR="./rule/Clash"
LOG_FILE="$REPO_ROOT/convert.log"
CHANGED_LIST="$REPO_ROOT/changed_mrs_files.txt"

#####################################
# 辅助
#####################################
ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }

fix_cidr_in_file() {
  local file="$1"
  sed -i -E 's/^(IP-CIDR,([0-9]{1,3}(\.[0-9]{1,3}){3}))(,no-resolve)$/\1\/24\4/' "$file" || true
  sed -i -E 's/^(IP-CIDR6,([0-9a-fA-F:]+))(,no-resolve)$/\1\/128\3/' "$file" || true
}

# 将 payload（各种形式）规范化成标准 yaml（version:1 + rules:）
normalize_payload_yaml_to_out() {
  local in="$1" out="$2"
  awk '
  BEGIN{mode=0; added_version=0}
  {
    line=$0
    if(mode==0 && line ~ /^[[:space:]]*(version|rules)[[:space:]]*:/){ print line; mode=3; next }
    if(mode==0 && line ~ /^[[:space:]]*payload[[:space:]]*:[[:space:]]*\[.*\][[:space:]]*$/){
      if(!added_version){ print "version: 1"; added_version=1 }
      sub(/^[[:space:]]*payload[[:space:]]*:/,"rules:"); print line; next
    }
    if(mode==0 && line ~ /^[[:space:]]*payload[[:space:]]*:(\s*[|>][[:space:]]*)?$/){
      if(!added_version){ print "version: 1"; added_version=1 }
      print "rules:"; mode=1; next
    }
    if(mode==0){ print line; next }
    if(mode==1){
      if(line ~ /^[[:space:]]*$/) next
      if(line !~ /^[[:space:]]+/){
        print line; mode=3; next
      }
      sub(/^[ \t]+/,"",line)
      if(line ~ /^-/){ sub(/^-+[ \t]*/,"- ",line); print "  " line }
      else { print "  - " line }
      next
    }
    print line
  }
  ' "$in" > "$out"
}

# txt -> yaml
txt_to_yaml_to_out() {
  local in="$1" out="$2"
  {
    echo "version: 1"
    echo "rules:"
    while IFS= read -r line || [ -n "$line" ]; do
      trimmed="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      if [[ -z "$trimmed" ]] || [[ "$trimmed" =~ ^# ]]; then
        continue
      fi
      echo "  - $trimmed"
    done < "$in"
  } > "$out"
}

# 下载并生成标准 YAML（优先），若是纯文本则先保存为 txt 回退并生成 yaml
download_and_check() {
  local yaml_final="$1"
  local url="$2"
  local text_fallback="$3"

  local raw_tmp
  raw_tmp="$(mktemp)" || { log "❌ 无法创建临时文件"; return 1; }

  if ! wget -q --no-proxy -O "$raw_tmp" "$url"; then
    log "❌ 下载失败：$url"
    rm -f "$raw_tmp"
    return 1
  fi

  local old_md5=""
  [[ -f "$yaml_final" ]] && old_md5=$(md5sum "$yaml_final" | awk '{print $1}')

  if grep -qE '^[[:space:]]*(version|rules)[[:space:]]*:' "$raw_tmp"; then
    sed -i 's/\r$//' "$raw_tmp" || true
    local new_md5; new_md5=$(md5sum "$raw_tmp" | awk '{print $1}')
    if [[ "$new_md5" == "$old_md5" ]]; then
      log "无变化（标准 YAML）：$yaml_final (md5=$new_md5)，跳过保存"
      rm -f "$raw_tmp"; return 0
    fi
    mv "$raw_tmp" "$yaml_final"
    log "下载并保存标准 YAML -> $yaml_final (md5 $new_md5)"
    return 0

  elif grep -qE '^[[:space:]]*payload[[:space:]]*:' "$raw_tmp"; then
    local norm_tmp; norm_tmp="$(mktemp)" || { rm -f "$raw_tmp"; log "❌ 无法创建临时文件"; return 1; }
    normalize_payload_yaml_to_out "$raw_tmp" "$norm_tmp" || { log "⚠️ payload 规范化失败：$url"; rm -f "$raw_tmp" "$norm_tmp"; return 1; }
    local new_md5; new_md5=$(md5sum "$norm_tmp" | awk '{print $1}')
    if [[ "$new_md5" == "$old_md5" ]]; then
      log "无变化（payload -> 标准 YAML）：$yaml_final (md5=$new_md5)，跳过保存"
      rm -f "$raw_tmp" "$norm_tmp"; return 0
    fi
    mv "$norm_tmp" "$yaml_final"; rm -f "$raw_tmp"
    log "下载并规范化 payload -> $yaml_final (md5 $new_md5)"
    return 0

  else
    # 纯文本
    mv "$raw_tmp" "$text_fallback"
    log "检测为纯文本，已保存为回退文本 -> $text_fallback"
    local tmp_yaml; tmp_yaml="$(mktemp)" || { log "❌ 无法创建临时文件"; return 1; }
    txt_to_yaml_to_out "$text_fallback" "$tmp_yaml" || { log "⚠️ txt -> yaml 转换失败：$text_fallback"; rm -f "$tmp_yaml"; return 1; }
    local new_md5; new_md5=$(md5sum "$tmp_yaml" | awk '{print $1}')
    if [[ "$new_md5" == "$old_md5" ]]; then
      log "无变化（txt->yaml 与现有相同）：$yaml_final (md5=$new_md5)，跳过保存"
      rm -f "$tmp_yaml"; return 0
    fi
    mv "$tmp_yaml" "$yaml_final"
    log "txt -> yaml 并保存 -> $yaml_final (md5 $new_md5)"
    return 0
  fi
}

#####################################
# 主流程
#####################################
: > "$LOG_FILE"
: > "$CHANGED_LIST"
log "开始执行 convert.sh"
log "工作目录：$REPO_ROOT"
log "规则目录：$LOCAL_DIR"

if ! cd "$LOCAL_DIR"; then log "❌ 无法切换到规则目录：$LOCAL_DIR"; exit 1; fi

log "阶段：.list -> .yaml/.txt（下载并规范化）"
while IFS= read -r -d '' listfile; do
  log "处理 list 文件：$listfile"
  fix_cidr_in_file "$listfile"
  RAW_URL="http://127.0.0.1:8080/Clash/${listfile#./}"
  RAW_URL_BASE64=$(printf '%s' "$RAW_URL" | openssl base64 -A)

  OUT_DOMAIN_YAML="${listfile%.list}_OCD_Domain.yaml"
  OUT_DOMAIN_TXT="${listfile%.list}_OCD_Domain.txt"
  OUT_IP_YAML="${listfile%.list}_OCD_IP.yaml"
  OUT_IP_TXT="${listfile%.list}_OCD_IP.txt"

  download_and_check "$OUT_DOMAIN_YAML" "http://127.0.0.1:25500/getruleset?type=3&url=$RAW_URL_BASE64" "$OUT_DOMAIN_TXT" || log "（警告）下载域名规则出错：$listfile"
  download_and_check "$OUT_IP_YAML" "http://127.0.0.1:25500/getruleset?type=4&url=$RAW_URL_BASE64" "$OUT_IP_TXT" || log "（警告）下载 IP 规则出错：$listfile"
done < <(find . -type f -name "*.list" -print0)
log "结束阶段：.list -> .yaml/.txt"

# 不再调用 --version，避免不兼容 flag
if [[ -x "/usr/bin/mihomo" ]]; then
  log "检测到 /usr/bin/mihomo 可执行文件：/usr/bin/mihomo"
else
  log "⚠️ 未检测到 /usr/bin/mihomo 可执行文件，请确认 CI 已安装 mihomo"
fi

log "阶段：yaml -> mrs（优先 YAML）"
while IFS= read -r -d '' yamlfile; do
  filename=$(basename "$yamlfile" .yaml)
  file_dir=$(dirname "$yamlfile")

  case "$filename" in
    *_OCD_Domain*) param="domain" ;;
    *_OCD_IP*)     param="ipcidr" ;;
    *) log "⚠️ 未识别的 YAML 文件类型：$yamlfile，跳过"; continue ;;
  esac

  output_file="$file_dir/$filename.mrs"
  tmp_output="${output_file}.tmp"
  per_log="$file_dir/$filename.mrs.log"

  old_md5=""
  [[ -f "$output_file" ]] && old_md5=$(md5sum "$output_file" | awk '{print $1}')
  log "开始转换：$yamlfile -> $output_file （临时 $tmp_output），之前 md5=${old_md5:-<无>}"

  if /usr/bin/mihomo convert-ruleset "$param" yaml "$yamlfile" "$tmp_output" >"$per_log" 2>&1; then
    new_md5=$(md5sum "$tmp_output" | awk '{print $1}')
    if [[ "$new_md5" != "$old_md5" ]]; then
      mv "$tmp_output" "$output_file"
      echo "$output_file $old_md5 -> $new_md5" >> "$CHANGED_LIST"
      log "✅ 转换并更新：$output_file （$old_md5 -> $new_md5）"
      [[ -f "$per_log" ]] && rm -f "$per_log" && log "已删除成功转换产生的日志文件：$per_log"
    else
      rm -f "$tmp_output"
      log "ℹ️ 转换结果与现有 .mrs 相同，未更新：$output_file (md5 $new_md5)"
      [[ -f "$per_log" ]] && rm -f "$per_log" && log "转换无变化，已删除 per-log：$per_log"
    fi
  else
    log "❌ 转换失败（yaml）：$yamlfile；请查看 $per_log"
    if [[ -f "$per_log" ]]; then
      log "------ $per_log 内容（前 400 行）开始 ------"
      sed -n '1,400p' "$per_log" | sed 's/^/    /' | tee -a "$LOG_FILE"
      log "------ $per_log 内容结束 ------"
    else
      log "（未生成 per-log 文件：$per_log）"
    fi
    # 继续处理下一个文件（不退出脚本）
  fi
done < <(find . -type f -name "*_OCD_*.yaml" -print0)
log "结束阶段：yaml -> mrs"

log "阶段：txt -> mrs（回退，仅当无同名 YAML）"
while IFS= read -r -d '' txtfile; do
  base="${txtfile%.txt}"
  if [[ -f "${base}.yaml" ]]; then
    log "跳过 TXT：$txtfile（存在同名 YAML ${base}.yaml）"
    continue
  fi

  if head -n1 "$txtfile" | grep -q "payload"; then sed -i '1d' "$txtfile" || true; fi
  sed -i "s/'//g; s/-//g; s/[[:space:]]//g" "$txtfile" || true

  filename=$(basename "$txtfile" .txt)
  file_dir=$(dirname "$txtfile")

  case "$filename" in
    *_OCD_Domain*) param="domain" ;;
    *_OCD_IP*)     param="ipcidr" ;;
    *) log "⚠️ 未识别的 TXT 文件类型：$txtfile，跳过"; continue ;;
  esac

  output_file="$file_dir/$filename.mrs"
  tmp_output="${output_file}.tmp"
  per_log="$file_dir/$filename.mrs.log"

  old_md5=""
  [[ -f "$output_file" ]] && old_md5=$(md5sum "$output_file" | awk '{print $1}')
  log "开始 TXT 转换：$txtfile -> $output_file （临时 $tmp_output），之前 md5=${old_md5:-<无>}"

  if /usr/bin/mihomo convert-ruleset "$param" text "$txtfile" "$tmp_output" >"$per_log" 2>&1; then
    new_md5=$(md5sum "$tmp_output" | awk '{print $1}')
    if [[ "$new_md5" != "$old_md5" ]]; then
      mv "$tmp_output" "$output_file"
      echo "$output_file $old_md5 -> $new_md5" >> "$CHANGED_LIST"
      log "✅ TXT 转换并更新：$output_file （$old_md5 -> $new_md5）"
      [[ -f "$per_log" ]] && rm -f "$per_log" && log "已删除成功 TXT 转换产生的日志文件：$per_log"
    else
      rm -f "$tmp_output"
      log "ℹ️ TXT 转换结果未改变 .mrs：$output_file (md5 $new_md5)"
      [[ -f "$per_log" ]] && rm -f "$per_log" && log "TXT 转换无变化，已删除 per-log：$per_log"
    fi
  else
    log "❌ TXT 转换失败：$txtfile；请查看 $per_log"
    if [[ -f "$per_log" ]]; then
      log "------ $per_log 内容（前 400 行）开始 ------"
      sed -n '1,400p' "$per_log" | sed 's/^/    /' | tee -a "$LOG_FILE"
      log "------ $per_log 内容结束 ------"
    fi
  fi
done < <(find . -type f -name "*_OCD_*.txt" -print0)
log "结束阶段：txt -> mrs（回退）"

log "convert.sh 执行完毕，变更列表（$CHANGED_LIST）："
if [[ -s "$CHANGED_LIST" ]]; then cat "$CHANGED_LIST" | tee -a "$LOG_FILE"; else log "（本次没有更新任何 .mrs）"; fi
log "脚本结束。"
