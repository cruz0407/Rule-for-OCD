#!/usr/bin/env bash
set -euo pipefail
# 如果想看详细执行过程，取消下一行注释
# set -x

REPO_ROOT="$(pwd)"            # 假定 workflow 从仓库根目录调用脚本
LOCAL_DIR="./rule/Clash"
LOG_FILE="$REPO_ROOT/convert.log"
CHANGED_LIST="$REPO_ROOT/changed_mrs_files.txt"

ts() { date +"%Y-%m-%d %H:%M:%S"; }
# 同时输出到 stdout（workflow 日志）和 convert.log
log() {
    echo "[$(ts)] $*" | tee -a "$LOG_FILE"
}

# 初始化
: > "$LOG_FILE"
: > "$CHANGED_LIST"
log "开始执行 convert.sh"
log "工作目录：$REPO_ROOT"
log "规则目录：$LOCAL_DIR"

# 切换到规则目录
if ! cd "$LOCAL_DIR"; then
    log "❌ 无法切换到规则目录：$LOCAL_DIR，退出"
    exit 1
fi

# 修复缺省 CIDR 的简单规则（供 list -> yaml 前清洗）
fix_cidr_in_file() {
    local file="$1"
    sed -i -E 's/^(IP-CIDR,([0-9]{1,3}(\.[0-9]{1,3}){3}))(,no-resolve)$/\1\/24\4/' "$file" || true
    sed -i -E 's/^(IP-CIDR6,([0-9a-fA-F:]+))(,no-resolve)$/\1\/128\3/' "$file" || true
}

# 下载到临时文件并与现有目标比较，避免硬编码 md5
download_and_check() {
    local final="$1"   # 目标文件名（相对路径）
    local url="$2"
    local text_fallback="$3"

    local tmp
    tmp="$(mktemp)" || { log "❌ 无法创建临时文件"; return 1; }

    if ! wget -q --no-proxy -O "$tmp" "$url"; then
        log "❌ 下载失败：$url"
        rm -f "$tmp"
        return 1
    fi

    # 计算 md5 比对
    local old_md5="" new_md5
    if [[ -f "$final" ]]; then old_md5=$(md5sum "$final" | awk '{print $1}'); fi
    new_md5=$(md5sum "$tmp" | awk '{print $1}')

    if [[ "$old_md5" == "$new_md5" ]]; then
        log "无变化：$final (md5=$new_md5)，跳过覆盖"
        rm -f "$tmp"
        return 0
    fi

    # 检查是否是纯文本 payload（兼容老返回）
    if head -n1 "$tmp" | grep -qiE '^(payload:|\| payload|payload)'; then
        mv "$tmp" "$text_fallback"
        log "检测到 text payload，已保存为回退文本 -> $text_fallback"
    else
        # 轻度清洗：去 CRLF
        sed -i 's/\r$//' "$tmp" || true
        mv "$tmp" "$final"
        log "下载并保存新的 YAML -> $final (md5 $new_md5)"
    fi
    return 0
}

# .list -> .yaml/.txt 阶段
log "开始阶段：.list -> .yaml/.txt"
find . -type f -name "*.list" | while IFS= read -r file; do
    log "处理 list 文件：$file"
    fix_cidr_in_file "$file"
    RAW_URL="http://127.0.0.1:8080/Clash/${file#./}"
    RAW_URL_BASE64=$(printf '%s' "$RAW_URL" | openssl base64 -A)

    OUT_DOMAIN_YAML="${file%.list}_OCD_Domain.yaml"
    OUT_DOMAIN_TXT="${file%.list}_OCD_Domain.txt"
    OUT_IP_YAML="${file%.list}_OCD_IP.yaml"
    OUT_IP_TXT="${file%.list}_OCD_IP.txt"

    download_and_check "$OUT_DOMAIN_YAML" "http://127.0.0.1:25500/getruleset?type=3&url=$RAW_URL_BASE64" "$OUT_DOMAIN_TXT"
    download_and_check "$OUT_IP_YAML" "http://127.0.0.1:25500/getruleset?type=4&url=$RAW_URL_BASE64" "$OUT_IP_TXT"
done
log "结束阶段：.list -> .yaml/.txt"

# 检查 mihomo 是否存在（提前提示）
if ! command -v /usr/bin/mihomo >/dev/null 2>&1; then
    log "⚠️ 未检测到 /usr/bin/mihomo 可执行文件，请确认 CI 中已安装 mihomo"
else
    log "检测到 mihomo：$(/usr/bin/mihomo --version 2>&1 | head -n1 || true)"
fi

# yaml -> mrs（优先 YAML）
log "开始阶段：yaml -> mrs（优先 YAML）"
find . -type f -name "*_OCD_*.yaml" | while IFS= read -r file; do
    filename=$(basename "$file" .yaml)
    file_dir=$(dirname "$file")

    case "$filename" in
        *_OCD_Domain*) param="domain" ;;
        *_OCD_IP*)     param="ipcidr" ;;
        *) log "⚠️ 未识别的 YAML 文件类型：$file，跳过"; continue ;;
    esac

    output_file="$file_dir/$filename.mrs"
    tmp_output="${output_file}.tmp"
    per_log="$file_dir/$filename.mrs.log"

    local old_md5=""
    [[ -f "$output_file" ]] && old_md5=$(md5sum "$output_file" | awk '{print $1}')
    log "开始转换：$file -> $output_file （临时文件 $tmp_output），之前 md5=${old_md5:-<无>}"

    # 调用 mihomo，将 stdout/stderr 写入 per_log
    if /usr/bin/mihomo convert-ruleset "$param" yaml "$file" "$tmp_output" >"$per_log" 2>&1; then
        new_md5=$(md5sum "$tmp_output" | awk '{print $1}')
        if [[ "$new_md5" != "$old_md5" ]]; then
            mv "$tmp_output" "$output_file"
            log "✅ 转换并更新：$output_file （$old_md5 -> $new_md5）"
            echo "$output_file $old_md5 -> $new_md5" >> "$CHANGED_LIST"
            # 转换成功且有变更，删除该文件的 .mrs.log（保持目录整洁）
            if [[ -f "$per_log" ]]; then
                rm -f "$per_log" && log "已删除成功转换产生的日志文件：$per_log"
            fi
        else
            # 内容无变化，删除临时输出
            rm -f "$tmp_output"
            log "ℹ️ 转换结果与现有 .mrs 相同，未更新：$output_file (md5 $new_md5)"
            # 转换成功但无变化，删除 per_log（按你要求）
            if [[ -f "$per_log" ]]; then
                rm -f "$per_log" && log "转换无变化，已删除 per-log：$per_log"
            fi
        fi
    else
        log "❌ 转换失败：$file；请查看日志：$per_log"
        log "（已保留 $per_log 以便排查）"
    fi
done
log "结束阶段：yaml -> mrs"

# 回退处理：如果没有 YAML，用 TXT（兼容旧流程）
log "开始阶段：txt -> mrs（仅在无同名 YAML 时回退）"
find . -type f -name "*_OCD_*.txt" | while IFS= read -r file; do
    base="${file%.txt}"
    if [[ -f "${base}.yaml" ]]; then
        log "跳过 TXT：$file（存在同名 YAML ${base}.yaml）"
        continue
    fi

    if head -n1 "$file" | grep -q "payload"; then
        sed -i '1d' "$file"
    fi
    # 保留原脚本对 txt 的轻度清洗（必要时可改）
    sed -i "s/'//g; s/-//g; s/[[:space:]]//g" "$file" || true

    filename=$(basename "$file" .txt)
    file_dir=$(dirname "$file")

    case "$filename" in
        *_OCD_Domain*) param="domain" ;;
        *_OCD_IP*)     param="ipcidr" ;;
        *) log "⚠️ 未识别的 TXT 文件类型：$file，跳过"; continue ;;
    esac

    output_file="$file_dir/$filename.mrs"
    tmp_output="${output_file}.tmp"
    per_log="$file_dir/$filename.mrs.log"

    old_md5=""
    [[ -f "$output_file" ]] && old_md5=$(md5sum "$output_file" | awk '{print $1}')
    log "开始转换 TXT：$file -> $output_file （临时 $tmp_output），之前 md5=${old_md5:-<无>}"

    if /usr/bin/mihomo convert-ruleset "$param" text "$file" "$tmp_output" >"$per_log" 2>&1; then
        new_md5=$(md5sum "$tmp_output" | awk '{print $1}')
        if [[ "$new_md5" != "$old_md5" ]]; then
            mv "$tmp_output" "$output_file"
            log "✅ TXT 转换并更新：$output_file （$old_md5 -> $new_md5）"
            echo "$output_file $old_md5 -> $new_md5" >> "$CHANGED_LIST"
            # 成功则删除 per_log
            if [[ -f "$per_log" ]]; then
                rm -f "$per_log" && log "已删除成功转换产生的日志文件：$per_log"
            fi
        else
            rm -f "$tmp_output"
            log "ℹ️ TXT 转换结果未改变 .mrs：$output_file (md5 $new_md5)"
            if [[ -f "$per_log" ]]; then
                rm -f "$per_log" && log "TXT 转换无变化，已删除 per-log：$per_log"
            fi
        fi
    else
        log "❌ TXT 转换失败：$file；请查看 $per_log"
    fi
done
log "结束阶段：txt -> mrs（回退）"

log "convert.sh 执行完毕，变更列表（$CHANGED_LIST）："
if [[ -s "$CHANGED_LIST" ]]; then
    cat "$CHANGED_LIST" | tee -a "$LOG_FILE"
else
    log "（本次没有更新任何 .mrs）"
fi

log "脚本结束。"
