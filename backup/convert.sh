#!/usr/bin/env bash
set -euo pipefail
# set -x  # 开发调试时可打开

# ---------- 配置 ----------
REPO_ROOT="$(pwd)"                    # 假定 workflow 从仓库根目录调用脚本
LOCAL_DIR="./rule/Clash"
LOG_FILE="$REPO_ROOT/convert.log"
CHANGED_LIST="$REPO_ROOT/changed_mrs_files.txt"

# ---------- 工具函数 ----------
ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }

# 等待本地服务就绪（subconverter:25500, http:8080），最多尝试 N 次
wait_for_services() {
  local tries=30
  local i
  for i in $(seq 1 $tries); do
    if curl -sSf --max-time 2 http://127.0.0.1:25500/ >/dev/null 2>&1 && \
       curl -sSf --max-time 2 http://127.0.0.1:8080/Clash/ >/dev/null 2>&1; then
      log "本地服务就绪（25500 与 8080 可访问）"
      return 0
    fi
    sleep 1
  done
  log "⚠️ 本地服务未完全就绪，继续运行可能会导致下载失败"
  return 1
}

# 简单清洗 list 文件里的可能缺失 CIDR 的 IP 条目
fix_cidr_in_file() {
  local file="$1"
  sed -i -E 's/^(IP-CIDR,([0-9]{1,3}(\.[0-9]{1,3}){3}))(,no-resolve)$/\1\/24\4/' "$file" || true
  sed -i -E 's/^(IP-CIDR6,([0-9a-fA-F:]+))(,no-resolve)$/\1\/128\3/' "$file" || true
}

# 下载并判断：如果内容包含 payload|version|rules 则当作 YAML 保存（payload 视为合法 YAML）
# 否则当作纯 text 回退保存
# download_and_check <yaml_target> <url> <text_fallback>
download_and_check() {
  local yaml_target="$1" url="$2" text_fallback="$3"
  local raw tmp_md5 old_md5

  raw="$(mktemp)" || { log "❌ 无法创建临时文件"; return 1; }
  if ! wget -q --no-proxy -O "$raw" "$url"; then
    log "❌ 下载失败：$url"
    rm -f "$raw"
    return 1
  fi

  # 目标文件已有 md5（若存在）
  old_md5=""
  if [[ -f "$yaml_target" ]]; then
    old_md5=$(md5sum "$yaml_target" | awk '{print $1}')
  fi

  # 判断：符合 YAML（含 payload/version/rules）则保存为 yaml_target（直接原样）
  if grep -qE '^[[:space:]]*(payload|version|rules)[[:space:]]*:' "$raw"; then
    # 轻度清理 CRLF
    sed -i 's/\r$//' "$raw" || true
    tmp_md5=$(md5sum "$raw" | awk '{print $1}')
    if [[ "$tmp_md5" == "$old_md5" ]]; then
      log "无变化（YAML）：$yaml_target (md5=$tmp_md5)，跳过保存"
      rm -f "$raw"
      return 0
    fi
    mv "$raw" "$yaml_target"
    log "下载并保存 YAML -> $yaml_target (md5 $tmp_md5)"
    return 0
  else
    # 作为纯文本回退保存（保持原始格式），后续会用 text -> mrs 转换
    mv "$raw" "$text_fallback"
    log "检测为纯文本（无 payload/version/rules），已保存为回退文本 -> $text_fallback"
    return 0
  fi
}

# 在转换失败时，回显 per-log 的前 N 行到主日志与 stdout
dump_per_log_head() {
  local per_log="$1" nlines="${2:-400}"
  if [[ -f "$per_log" ]]; then
    log "------ $per_log 内容（前 $nlines 行）开始 ------"
    sed -n "1,${nlines}p" "$per_log" | sed 's/^/    /' | tee -a "$LOG_FILE"
    log "------ $per_log 内容结束 ------"
  else
    log "（未生成 per-log：$per_log）"
  fi
}

# ---------- 主流程 ----------
: > "$LOG_FILE"
: > "$CHANGED_LIST"
log "开始执行 convert.sh"
log "工作目录：$REPO_ROOT"
log "规则目录：$LOCAL_DIR"

# 进入目录
if ! cd "$LOCAL_DIR"; then
  log "❌ 无法切换到规则目录：$LOCAL_DIR，退出"
  exit 1
fi

# 等待本地服务（尝试性，避免 race）
wait_for_services || log "（继续执行，注意可能会有下载失败）"

# list -> yaml/txt
log "阶段：.list -> .yaml/.txt（下载并判定 payload 作为合法 YAML）"
while IFS= read -r -d '' listfile; do
  log "处理 list 文件：$listfile"
  fix_cidr_in_file "$listfile"

  RAW_URL="http://127.0.0.1:8080/Clash/${listfile#./}"
  RAW_URL_BASE64=$(printf '%s' "$RAW_URL" | openssl base64 -A)

  OUT_DOMAIN_YAML="${listfile%.list}_OCD_Domain.yaml"
  OUT_DOMAIN_TXT="${listfile%.list}_OCD_Domain.txt"
  OUT_IP_YAML="${listfile%.list}_OCD_IP.yaml"
  OUT_IP_TXT="${listfile%.list}_OCD_IP.txt"

  download_and_check "$OUT_DOMAIN_YAML" "http://127.0.0.1:25500/getruleset?type=3&url=$RAW_URL_BASE64" "$OUT_DOMAIN_TXT" \
    || log "（警告）处理域名规则时下载/判断失败：$listfile"
  download_and_check "$OUT_IP_YAML" "http://127.0.0.1:25500/getruleset?type=4&url=$RAW_URL_BASE64" "$OUT_IP_TXT" \
    || log "（警告）处理 IP 规则时下载/判断失败：$listfile"
done < <(find . -type f -name "*.list" -print0)
log "结束阶段：.list -> .yaml/.txt"

# 检查 mihomo 可执行性（不要调用 --version，避免某些发行版报错）
if [[ -x "/usr/bin/mihomo" ]]; then
  log "检测到 /usr/bin/mihomo 可执行文件：/usr/bin/mihomo"
else
  log "⚠️ 未检测到 /usr/bin/mihomo，可执行文件缺失会导致转换失败"
fi

# yaml -> mrs（优先 YAML，payload: 会直接被当作 yaml）
log "阶段：yaml -> mrs（优先 YAML，payload: 视为合法 YAML）"
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
    else
      rm -f "$tmp_output"
      log "ℹ️ 转换结果与现有 .mrs 相同，未更新：$output_file (md5 $new_md5)"
    fi
    # 成功则删除 per-log（按你的要求）
    [[ -f "$per_log" ]] && rm -f "$per_log" && log "已删除成功转换产生的日志文件：$per_log"
  else
    log "❌ 转换失败（yaml）：$yamlfile；保留日志：$per_log"
    dump_per_log_head "$per_log" 400
    # 继续处理下一个文件（不退出）
  fi
done < <(find . -type f -name "*_OCD_*.yaml" -print0)
log "结束阶段：yaml -> mrs"

# txt -> mrs 回退（仅当无同名 yaml）
log "阶段：txt -> mrs（回退，仅在无同名 YAML 时）"
while IFS= read -r -d '' txtfile; do
  base="${txtfile%.txt}"
  if [[ -f "${base}.yaml" ]]; then
    log "跳过 TXT：$txtfile（存在同名 YAML ${base}.yaml）"
    continue
  fi

  # 如果第一行为 payload，去掉（历史格式）
  if head -n1 "$txtfile" | grep -qi '^payload'; then
    sed -i '1d' "$txtfile" || true
  fi

  # 原脚本对 txt 做的轻度清洗（保留）
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
    else
      rm -f "$tmp_output"
      log "ℹ️ TXT 转换结果未改变 .mrs：$output_file (md5 $new_md5)"
    fi
    [[ -f "$per_log" ]] && rm -f "$per_log" && log "已删除成功 TXT 转换产生的日志文件：$per_log"
  else
    log "❌ TXT 转换失败：$txtfile；保留日志：$per_log"
    dump_per_log_head "$per_log" 400
  fi
done < <(find . -type f -name "*_OCD_*.txt" -print0)
log "结束阶段：txt -> mrs（回退）"

# Summary
log "convert.sh 执行完毕，变更列表（$CHANGED_LIST）："
if [[ -s "$CHANGED_LIST" ]]; then
  cat "$CHANGED_LIST" | tee -a "$LOG_FILE"
else
  log "（本次没有更新任何 .mrs）"
fi
log "脚本结束。"
