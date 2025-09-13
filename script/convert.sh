#!/usr/bin/env bash
set -euo pipefail

BASE_URL="http://127.0.0.1:8080/Clash"
LOCAL_DIR="./rule/Clash"
ts() { date +"%Y-%m-%d %H:%M:%S"; }

cd "$LOCAL_DIR" || exit 1

fix_cidr_in_file() {
    local file="$1"
    # 修复缺少 CIDR 的 IP-CIDR (IPv4)
    sed -i -E 's/^(IP-CIDR,([0-9]{1,3}(\.[0-9]{1,3}){3}))(,no-resolve)$/\1\/24\4/' "$file"
    # 修复缺少 CIDR 的 IP-CIDR6 (IPv6)
    sed -i -E 's/^(IP-CIDR6,([0-9a-fA-F:]+))(,no-resolve)$/\1\/128\3/' "$file"
}

# 下载并判断（改动：把主要产物看作 YAML；只有在服务器返回纯文本/带 payload 的情况下，才写入 .txt 回退）
download_and_check() {
    local yaml_file="$1"
    local expected_md5="$2"
    local url="$3"
    local text_fallback="$4"

    if wget -q --no-proxy -O "$yaml_file" "$url"; then
        local actual_md5
        actual_md5=$(md5sum "$yaml_file" | awk '{print $1}')
        if [[ "$actual_md5" == "$expected_md5" ]]; then
            # 与预期的“无变化文件”一致 —— 删除，表示无更新
            rm -f "$yaml_file"
        else
            # 如果返回的内容看起来像纯文本（例如第一行包含 payload 或不是合法 yaml list）
            # 我们把它当作 text 回退（保留旧流程兼容性）
            if head -n1 "$yaml_file" | grep -qiE '^(payload:|\| payload|payload)'; then
                cp "$yaml_file" "$text_fallback"
            else
                # 保留 YAML 原始输出，供后面直接以 yaml -> mrs 转换
                # 但先做些轻微清理：去除 Windows CRLF
                sed -i 's/\r$//' "$yaml_file" || true
            fi
        fi
    else
        echo "❌ 下载失败: $url" >&2
    fi
}

# .list -> .txt/.yaml
echo "[$(ts)] 开始: list -> txt/yaml 阶段"
find . -type f -name "*.list" | while IFS= read -r file; do
    fix_cidr_in_file "$file"
    RAW_URL="$BASE_URL/${file#./}"
    RAW_URL_BASE64=$(printf '%s' "$RAW_URL" | openssl base64 -A)

    OUTPUT_FILE_DOMAIN_YAML="${file%.list}_OCD_Domain.yaml"
    OUTPUT_FILE_DOMAIN_TEXT="${file%.list}_OCD_Domain.txt"
    OUTPUT_FILE_IP_YAML="${file%.list}_OCD_IP.yaml"
    OUTPUT_FILE_IP_TEXT="${file%.list}_OCD_IP.txt"

    # type=3 域名, type=4 IP
    download_and_check "$OUTPUT_FILE_DOMAIN_YAML" \
        "0c04407cd072968894bd80a426572b13" \
        "http://127.0.0.1:25500/getruleset?type=3&url=$RAW_URL_BASE64" \
        "$OUTPUT_FILE_DOMAIN_TEXT"

    download_and_check "$OUTPUT_FILE_IP_YAML" \
        "3d6eaeec428ed84741b4045f4b85eee3" \
        "http://127.0.0.1:25500/getruleset?type=4&url=$RAW_URL_BASE64" \
        "$OUTPUT_FILE_IP_TEXT"
done
echo "[$(ts)] 结束: list -> txt/yaml 阶段"

# yaml -> .mrs （优先处理 YAML；仅当没有 YAML 可用时再处理 .txt 回退）
echo "[$(ts)] 开始: yaml/text -> mrs 阶段 (优先 YAML)"
# 优先处理 YAML 文件
find . -type f -name "*_OCD_*.yaml" | while IFS= read -r file; do
    filename=$(basename "$file" .yaml)
    file_dir=$(dirname "$file")

    case "$filename" in
        *_OCD_Domain*) param="domain" ;;
        *_OCD_IP*)     param="ipcidr" ;;
        *) echo "⚠️ 未识别的 YAML 文件类型: $file" >&2; continue ;;
    esac

    output_file="$file_dir/$filename.mrs"
    log_file="$file_dir/$filename.mrs.log"

    # 使用 mihomo 的 yaml 输入模式转换
    if /usr/bin/mihomo convert-ruleset "$param" yaml "$file" "$output_file" >"$log_file" 2>&1; then
        echo "✅ 转换成功 (yaml->mrs): $output_file"
        rm -f "$log_file"   # 成功就删除日志文件，避免目录里多余文件
    else
        echo "❌ 转换失败 (yaml): $file, 日志见 $log_file" >&2
    fi
done

# 再处理没有对应 YAML 的旧式 txt（兼容旧流程）
find . -type f -name "*_OCD_*.txt" | while IFS= read -r file; do
    base="${file%.txt}"
    if [[ -f "${base}.yaml" ]]; then
        echo "ℹ️ 跳过 $file，存在同名 YAML ${base}.yaml" >&2
        continue
    fi

    # 旧逻辑的清理（仅在处理 txt 时保留）
    if head -n1 "$file" | grep -q "payload"; then
        sed -i '1d' "$file"
    fi
    # 清理字符（保留原来逻辑；如果后面发现导致错误可以去掉）
    sed -i "s/'//g; s/-//g; s/[[:space:]]//g" "$file"

    filename=$(basename "$file" .txt)
    file_dir=$(dirname "$file")

    case "$filename" in
        *_OCD_Domain*) param="domain" ;;
        *_OCD_IP*)     param="ipcidr" ;;
        *) echo "⚠️ 未识别的 TXT 文件类型: $file" >&2; continue ;;
    esac

    output_file="$file_dir/$filename.mrs"
    log_file="$file_dir/$filename.mrs.log"

    if /usr/bin/mihomo convert-ruleset "$param" text "$file" "$output_file" >"$log_file" 2>&1; then
        echo "✅ 转换成功 (txt->mrs): $output_file"
        rm -f "$log_file"
    else
        echo "❌ 转换失败 (txt): $file, 日志见 $log_file" >&2
    fi
done
echo "[$(ts)] 结束: yaml/text -> mrs 阶段"
