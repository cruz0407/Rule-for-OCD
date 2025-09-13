#!/usr/bin/env bash
set -euo pipefail
# Debug 模式可打开（开发时启用）
# set -x

REPO_ROOT="$(pwd)"            # 假定脚本从 repo 根调用（CI 是这样）
LOCAL_DIR="./rule/Clash"
LOG_FILE="$REPO_ROOT/convert.log"
CHANGED_LIST="$REPO_ROOT/changed_mrs_files.txt"
ts() { date +"%Y-%m-%d %H:%M:%S"; }

# 初始化日志
echo "[$(ts)] ===== convert.sh start =====" >> "$LOG_FILE"
echo "[$(ts)] CWD: $(pwd), LOCAL_DIR: $LOCAL_DIR" >> "$LOG_FILE"
: > "$CHANGED_LIST"  # 清空上次记录（每次 run 重置）

cd "$LOCAL_DIR" || { echo "Cannot cd to $LOCAL_DIR" >> "$LOG_FILE"; exit 1; }

fix_cidr_in_file() {
    local file="$1"
    sed -i -E 's/^(IP-CIDR,([0-9]{1,3}(\.[0-9]{1,3}){3}))(,no-resolve)$/\1\/24\4/' "$file"
    sed -i -E 's/^(IP-CIDR6,([0-9a-fA-F:]+))(,no-resolve)$/\1\/128\3/' "$file"
}

# 下载到临时文件并比对现有文件（更可靠，不用硬编码 md5）
download_and_check() {
    local final="$1"   # 目标文件名（相对路径）
    local url="$2"
    local text_fallback="$3"

    local tmp="$(mktemp)"
    if ! wget -q --no-proxy -O "$tmp" "$url"; then
        echo "[$(ts)] ❌ download failed: $url" >> "$LOG_FILE"
        rm -f "$tmp"
        return 1
    fi

    # 判断是否和现有文件一致
    if [[ -f "$final" ]]; then
        old_md5=$(md5sum "$final" | awk '{print $1}')
    else
        old_md5=""
    fi
    new_md5=$(md5sum "$tmp" | awk '{print $1}')

    if [[ "$old_md5" == "$new_md5" ]]; then
        echo "[$(ts)] no change for $final (md5=$new_md5)" >> "$LOG_FILE"
        rm -f "$tmp"
        return 0
    fi

    # 简单判断是否是纯文本 payload（兼容旧 provider）
    if head -n1 "$tmp" | grep -qiE '^(payload:|\| payload|payload)'; then
        mv "$tmp" "$text_fallback"
        echo "[$(ts)] downloaded content looks like text -> $text_fallback" >> "$LOG_FILE"
    else
        # 轻度清洗（只去 CRLF）
        sed -i 's/\r$//' "$tmp" || true
        mv "$tmp" "$final"
        echo "[$(ts)] downloaded new/changed YAML -> $final (md5 $new_md5)" >> "$LOG_FILE"
    fi
    return 0
}

# step1: .list -> .yaml/.txt
echo "[$(ts)] list -> yaml/txt start" >> "$LOG_FILE"
find . -type f -name "*.list" | while IFS= read -r file; do
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
echo "[$(ts)] list -> yaml/txt done" >> "$LOG_FILE"

# step2: 优先用 YAML -> .mrs
echo "[$(ts)] yaml -> mrs start" >> "$LOG_FILE"
find . -type f -name "*_OCD_*.yaml" | while IFS= read -r file; do
    filename=$(basename "$file" .yaml)
    file_dir=$(dirname "$file")

    case "$filename" in
        *_OCD_Domain*) param="domain" ;;
        *_OCD_IP*)     param="ipcidr" ;;
        *) echo "[$(ts)] ⚠ unknown yaml type: $file" >> "$LOG_FILE"; continue ;;
    esac

    output_file="$file_dir/$filename.mrs"
    tmp_output="${output_file}.tmp"
    per_log="$file_dir/$filename.mrs.log"

    old_md5=""
    [[ -f "$output_file" ]] && old_md5=$(md5sum "$output_file" | awk '{print $1}')
    echo "[$(ts)] converting yaml: $file -> $tmp_output (old md5: $old_md5)" >> "$LOG_FILE"

    if /usr/bin/mihomo convert-ruleset "$param" yaml "$file" "$tmp_output" >"$per_log" 2>&1; then
        new_md5=$(md5sum "$tmp_output" | awk '{print $1}')
        if [[ "$new_md5" != "$old_md5" ]]; then
            mv "$tmp_output" "$output_file"
            echo "[$(ts)] CHANGED: $output_file ($old_md5 -> $new_md5)" >> "$LOG_FILE"
            echo "$output_file $old_md5 -> $new_md5" >> "$CHANGED_LIST"
        else
            rm -f "$tmp_output"
            echo "[$(ts)] UNCHANGED: $output_file (md5 $new_md5)" >> "$LOG_FILE"
        fi
        # 保留 per-file log for 调试（如果想删除可在此 rm）
    else
        echo "[$(ts)] ❌ convert failed for $file, see $per_log" >> "$LOG_FILE"
    fi
done
echo "[$(ts)] yaml -> mrs done" >> "$LOG_FILE"

# step3: 兼容旧 txt（仅当没有同名 yaml）
echo "[$(ts)] txt -> mrs (fallback) start" >> "$LOG_FILE"
find . -type f -name "*_OCD_*.txt" | while IFS= read -r file; do
    base="${file%.txt}"
    if [[ -f "${base}.yaml" ]]; then
        echo "[$(ts)] skip txt $file because ${base}.yaml exists" >> "$LOG_FILE"
        continue
    fi

    if head -n1 "$file" | grep -q "payload"; then
        sed -i '1d' "$file"
    fi
    sed -i "s/'//g; s/-//g; s/[[:space:]]//g" "$file"

    filename=$(basename "$file" .txt)
    file_dir=$(dirname "$file")

    case "$filename" in
        *_OCD_Domain*) param="domain" ;;
        *_OCD_IP*)     param="ipcidr" ;;
        *) echo "[$(ts)] ⚠ unknown txt type: $file" >> "$LOG_FILE"; continue ;;
    esac

    output_file="$file_dir/$filename.mrs"
    tmp_output="${output_file}.tmp"
    per_log="$file_dir/$filename.mrs.log"

    old_md5=""
    [[ -f "$output_file" ]] && old_md5=$(md5sum "$output_file" | awk '{print $1}')
    echo "[$(ts)] converting txt: $file -> $tmp_output (old md5: $old_md5)" >> "$LOG_FILE"

    if /usr/bin/mihomo convert-ruleset "$param" text "$file" "$tmp_output" >"$per_log" 2>&1; then
        new_md5=$(md5sum "$tmp_output" | awk '{print $1}')
        if [[ "$new_md5" != "$old_md5" ]]; then
            mv "$tmp_output" "$output_file"
            echo "[$(ts)] CHANGED: $output_file ($old_md5 -> $new_md5)" >> "$LOG_FILE"
            echo "$output_file $old_md5 -> $new_md5" >> "$CHANGED_LIST"
        else
            rm -f "$tmp_output"
            echo "[$(ts)] UNCHANGED: $output_file (md5 $new_md5)" >> "$LOG_FILE"
        fi
    else
        echo "[$(ts)] ❌ convert failed for $file, see $per_log" >> "$LOG_FILE"
    fi
done
echo "[$(ts)] txt -> mrs fallback done" >> "$LOG_FILE"

echo "[$(ts)] ===== convert.sh end =====" >> "$LOG_FILE"
# 输出 summary 到 stdout（CI 日志可见）
echo "convert finished. changed list:"
cat "$CHANGED_LIST" || true
