#!/bin/bash

# ==============================================================================
#
# 密钥管理器修改版 v1.4 
#
# - 该脚本完全免费，请勿用于任何商业行为
# - 作者: momo & ddddd1996 & KKTsN
#
# - v1.4 更新日志:
#   - 更改了横幅和一些介绍
#   - 延长了等待时间，可能能增加一次开满75的概率
#   - 去掉了配额检查
#
# ==============================================================================

# ===== 全局配置 =====
TIMESTAMP=$(date +%s)
RANDOM_CHARS=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
EMAIL_USERNAME="${RANDOM_CHARS}${TIMESTAMP:(-4)}"
# 生成随机的项目前缀
RANDOM_PREFIX_PART=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 5 | head -n 1)
RANDOM_SUFFIX_PART=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 3 | head -n 1)
PROJECT_PREFIX="${RANDOM_PREFIX_PART}Vul${RANDOM_SUFFIX_PART}"
TOTAL_PROJECTS=50
MAX_PARALLEL_JOBS=40
# 动态全局等待时间计算函数
calculate_global_wait_seconds() {
    local calculated_seconds=$((TOTAL_PROJECTS * 2))
    if [ $calculated_seconds -lt 60 ]; then
        echo 60
    else
        echo $calculated_seconds
    fi
}
MAX_RETRY_ATTEMPTS=3
MAX_RETRY_GLOBAL=1
SECONDS=0

# 文件和目录配置
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_LOG="api_keys_cleanup_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR="/tmp/gcp_script_${TIMESTAMP}"
HEARTBEAT_PID=""

# 启动时创建临时目录
mkdir -p "$TEMP_DIR"

# ===== 工具函数 =====

# 统一日志函数
log() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "${TEMP_DIR}/script.log"
}

# 检查并安装jq
check_and_install_jq() {
    if command -v jq &>/dev/null; then
        log "INFO" "jq已安装，将使用jq进行JSON解析"
        return 0
    fi
    
    log "WARN" "未检测到jq，尝试自动安装..."
    
    # 检测操作系统并尝试安装
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt-get &>/dev/null; then
            log "INFO" "检测到Debian/Ubuntu系统，使用apt-get安装jq..."
            if sudo apt-get update && sudo apt-get install -y jq; then
                log "INFO" "jq安装成功"
                return 0
            fi
        elif command -v yum &>/dev/null; then
            log "INFO" "检测到RHEL/CentOS系统，使用yum安装jq..."
            if sudo yum install -y jq; then
                log "INFO" "jq安装成功"
                return 0
            fi
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &>/dev/null; then
            log "INFO" "检测到macOS系统，使用Homebrew安装jq..."
            if brew install jq; then
                log "INFO" "jq安装成功"
                return 0
            fi
        fi
    fi
    
    log "WARN" "jq安装失败，将使用备用的sed/grep方法解析JSON"
    return 1
}

# 初始化时检查jq
check_and_install_jq

# 心跳机制 - 修复版
start_heartbeat() {
    local message="$1"
    local interval="${2:-20}"
    stop_heartbeat
    (
        while true; do
            # 修复：避免在并行处理时输出心跳，防止与进度条冲突
            if [[ -z "${PROGRESS_ACTIVE:-}" ]]; then
                log "HEARTBEAT" "${message:-"操作进行中，请耐心等待..."}"
            fi
            sleep "$interval"
        done
    ) &
    HEARTBEAT_PID=$!
}

stop_heartbeat() {
    if [[ -n "$HEARTBEAT_PID" && -e /proc/$HEARTBEAT_PID ]]; then
        kill "$HEARTBEAT_PID" 2>/dev/null
        wait "$HEARTBEAT_PID" 2>/dev/null || true
    fi
    HEARTBEAT_PID=""
    # 修复：停止心跳后确保光标位置正确
    printf "\r\033[K"
}

# 优化版JSON解析函数
parse_json() {
    local json_input="$1"
    local field="$2"
    local value=""
    if command -v jq &>/dev/null; then
        value=$(echo "$json_input" | jq -r "$field // \"\"")
    else
        # sed/grep fallback is complex for nested keys, jq is highly recommended.
        # This simplified version will not work for ".response.keyString"
        log "WARN" "jq not found. Using simplified parser which may fail for nested data."
        local simple_field=$(basename "$field")
        value=$(echo "$json_input" | grep -o "\"$simple_field\": *\"[^\"]*\"" | head -n 1 | cut -d'"' -f4)
    fi
    if [[ -n "$value" && "$value" != "null" ]]; then
        echo "$value"; return 0;
    else
        return 1;
    fi
}

# 文件写入函数 (带文件锁)
write_keys_to_files() {
    local api_key="$1"
    if [[ -z "$api_key" ]]; then return 1; fi
    (
        if flock -w 10 200; then
            echo "$api_key" >> "$PURE_KEY_FILE"
            if [[ -s "$COMMA_SEPARATED_KEY_FILE" ]]; then
                echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"
            fi
            echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
        else
            log "ERROR" "写入文件失败: 获取文件锁超时"
            return 1
        fi
    ) 200>"${TEMP_DIR}/key_files.lock"
}

# 改进的重试函数
retry_with_backoff() {
    local max_attempts=$1; shift; local cmd_str="$1"; local attempt=1; local base_timeout=5
    while (( attempt <= max_attempts )); do
        local output; local error_msg;
        exec 3>&1
        error_msg=$({ output=$(eval "$cmd_str" 2>&1 >&3); } 2>&1)
        exec 3>&-
        local exit_code=$?
        if (( exit_code == 0 )); then echo "$output"; return 0; fi
        log "WARN" "命令失败 (尝试 $attempt/$max_attempts): $(echo "$cmd_str" | cut -d' ' -f1-4)..."
        log "WARN" "--> 错误详情: $error_msg"
        if [[ "$error_msg" == *"Permission denied"* || "$error_msg" == *"INVALID_ARGUMENT"* || "$error_msg" == *"already exists"* ]]; then
            log "ERROR" "检测到不可重试错误，停止。"; return $exit_code;
        fi
        if [[ "$error_msg" == *"Quota exceeded"* || "$error_msg" == *"RESOURCE_EXHAUSTED"* ]]; then
            local sleep_time=$((base_timeout * attempt * 2)); log "WARN" "检测到配额限制，等待 ${sleep_time}s"; sleep "$sleep_time"
        elif (( attempt < max_attempts )); then
            local sleep_time=$((base_timeout * attempt)); log "INFO" "等待 ${sleep_time}s 后重试..."; sleep "$sleep_time"
        fi
        ((attempt++))
    done
    log "ERROR" "命令在 $max_attempts 次尝试后最终失败: $cmd_str"; return 1
}


# 进度条显示函数 - 修复版
show_progress() {
    local completed=$1; local total=$2; local op_name=${3:-"进度"}
    if (( total <= 0 )); then return; fi; if (( completed > total )); then completed=$total; fi
    local percent=$((completed * 100 / total)); local bar_len=40
    local filled_len=$((bar_len * percent / 100)); local bar; printf -v bar '%*s' "$filled_len" ''; bar=${bar// /█}
    local empty; printf -v empty '%*s' "$((bar_len - filled_len))" ''; empty=${empty// /░}
    # 修复：使用更兼容的清屏和输出方式
    printf "\r\033[K[%s%s] %d%% (%d/%d) - %s" "$bar" "$empty" "$percent" "$completed" "$total" "$op_name"
    # 确保输出立即刷新
    if [[ "$completed" -eq "$total" ]]; then
        printf "\n"
    fi
}

generate_report() {
    local success=$1 failed=$2 total=$3 operation=${4:-"处理"}; local success_rate=0
    if (( total > 0 )); then success_rate=$(awk "BEGIN {printf \"%.2f\", $success * 100 / $total}"); fi
    local duration=$SECONDS h=$((duration/3600)) m=$(((duration%3600)/60)) s=$((duration%60))
    echo; echo "======================== 执 行 报 告 ========================";
    printf "  操作类型    : %s\n" "$operation"; printf "  总计尝试    : %d\n" "$total"; printf "  成功数量    : %d\n" "$success";
    printf "  失败数量    : %d\n" "$failed"; printf "  成功率      : %.2f%%\n" "$success_rate"; printf "  总执行时间  : %d小时 %d分钟 %d秒\n" "$h" "$m" "$s"
    if (( success > 0 )) && [[ "$operation" == *"密钥"* ]]; then
        local key_count; key_count=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null || echo 0)
        echo; echo "  输出文件:"; echo "  - 纯密钥文件    : $PURE_KEY_FILE ($key_count 个密钥)"; echo "  - 逗号分隔文件  : $COMMA_SEPARATED_KEY_FILE"
    fi
    echo "================================================================"
}

# ===== 健壮的任务函数 =====

task_create_project() {
    local project_id="$1"; local success_file="$2"
    if retry_with_backoff "$MAX_RETRY_ATTEMPTS" "gcloud projects create \"$project_id\" --name=\"$project_id\" --no-set-as-default --quiet"; then
        (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"; return 0
    else return 1; fi
}

task_enable_api() {
    local project_id="$1"; local success_file="$2"
    if retry_with_backoff "$MAX_RETRY_ATTEMPTS" "gcloud services enable generativelanguage.googleapis.com --project=\"$project_id\" --quiet"; then
        (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"; return 0
    else return 1; fi
}

task_create_key() {
    local project_id="$1"; local success_file="$2"; local create_output
    create_output=$(retry_with_backoff "$MAX_RETRY_ATTEMPTS" "gcloud services api-keys create --project=\"$project_id\" --display-name=\"Gemini-API-Key\" --format=json --quiet")
    if [[ -z "$create_output" ]]; then log "ERROR" "为项目 $project_id 创建密钥失败 (无输出)。"; return 1; fi
    local gcp_error_msg; gcp_error_msg=$(parse_json "$create_output" ".error.message")
    if [[ -n "$gcp_error_msg" ]]; then log "ERROR" "为项目 $project_id 创建密钥时GCP返回错误: $gcp_error_msg"; log "DEBUG" "GCP错误详情: $create_output"; return 1; fi
    
    # ===== THE BULLSEYE FIX =====
    local api_key; api_key=$(parse_json "$create_output" ".response.keyString")
    # ===== END OF FIX =====

    if [[ -n "$api_key" ]]; then
        write_keys_to_files "$api_key"; (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"; return 0
    else
        log "ERROR" "为项目 $project_id 提取密钥失败 (无法解析 .response.keyString)。"; log "DEBUG" "gcloud返回内容: $create_output"; return 1
    fi
}

task_delete_project() {
    local project_id="$1"; local success_file="$2"
    if retry_with_backoff 2 "gcloud projects delete \"$project_id\" --quiet"; then
        (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"; return 0
    else return 1; fi
}

task_cleanup_keys() {
    local project_id="$1"; local success_file="$2"; local key_names; readarray -t key_names < <(gcloud services api-keys list --project="$project_id" --format="value(name)" --quiet)
    if [ ${#key_names[@]} -eq 0 ]; then
        (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"; return 0
    fi
    local all_success=true
    for key_name in "${key_names[@]}"; do
        if ! retry_with_backoff 2 "gcloud services api-keys delete \"$key_name\" --quiet"; then all_success=false; fi
        sleep 0.5
    done
    if $all_success; then (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"; return 0; else return 1; fi
}

cleanup_resources() {
    log "INFO" "执行退出清理..."; stop_heartbeat; pkill -P $$ &>/dev/null; rm -rf "$TEMP_DIR";
}

# ===== 并行执行与报告 =====

run_parallel() {
    local task_func="$1"; local description="$2"; local success_file="$3"; shift 3; local items=("$@"); local total_items=${#items[@]}
    if (( total_items == 0 )); then log "INFO" "在 '$description' 阶段无项目处理。"; return; fi
    log "INFO" "开始并行执行 '$description' (最大并发: $MAX_PARALLEL_JOBS)..."
    local pids=(); local completed_count=0
    
    # 修复：标记进度条活跃状态，避免心跳干扰
    export PROGRESS_ACTIVE=1
    export -f log retry_with_backoff parse_json write_keys_to_files "$task_func" show_progress; export MAX_RETRY_ATTEMPTS PURE_KEY_FILE COMMA_SEPARATED_KEY_FILE TEMP_DIR
    > "$success_file"
    
    for i in "${!items[@]}"; do
        if (( ${#pids[@]} >= MAX_PARALLEL_JOBS )); then
            wait -n "${pids[@]}"; for j in "${!pids[@]}"; do if ! kill -0 "${pids[j]}" 2>/dev/null; then unset 'pids[j]'; ((completed_count++)); fi; done
            show_progress "$completed_count" "$total_items" "$description"
        fi
        ( "$task_func" "${items[i]}" "$success_file" ) & pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid"; ((completed_count++)); show_progress "$completed_count" "$total_items" "$description"; done
    wait; show_progress "$total_items" "$total_items" "$description 完成"
    
    # 修复：清除进度条活跃状态
    unset PROGRESS_ACTIVE
    
    local success_count; success_count=$(wc -l < "$success_file" | xargs); local fail_count=$((total_items - success_count))
    printf "\n"; log "INFO" "阶段 '$description' 完成。总数: $total_items, 成功: $success_count, 失败: $fail_count"
}


create_projects_phased() {
    SECONDS=0
    local retry_count=0
    local projects_to_create_count=$TOTAL_PROJECTS
    
    while true; do
        log "INFO" "==================== 功能1: 创建项目并获取密钥 (分阶段) ===================="
        if [ $retry_count -eq 0 ]; then
            log "INFO" "将创建 $projects_to_create_count 个新项目。用户名: $EMAIL_USERNAME, 项目前缀: $PROJECT_PREFIX"
            > "$PURE_KEY_FILE"; > "$COMMA_SEPARATED_KEY_FILE"
        else
            log "INFO" "==================== 全局重试 (第 $retry_count 次) ===================="
            log "INFO" "将重新创建 $projects_to_create_count 个失败的项目"
        fi
        
        # 计算项目ID的起始编号
        local start_num=1
        if [ $retry_count -gt 0 ]; then
            # 在重试时，使用新的项目编号
            start_num=$((TOTAL_PROJECTS - projects_to_create_count + 1))
        fi
        
        local projects_to_create=()
        for i in $(seq $start_num $((start_num + projects_to_create_count - 1))); do
            local p_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-$(printf "%03d" $i)"
            p_id=$(echo "$p_id"|tr -cd 'a-z0-9-'|cut -c 1-30|sed 's/-$//')
            projects_to_create+=("$p_id")
        done
        
        local CREATED_PROJECTS_FILE="${TEMP_DIR}/created_${retry_count}.txt"
        run_parallel task_create_project "阶段1: 创建项目" "$CREATED_PROJECTS_FILE" "${projects_to_create[@]}"
        
        local created_project_ids=()
        mapfile -t created_project_ids < "$CREATED_PROJECTS_FILE"
        if [ ${#created_project_ids[@]} -eq 0 ]; then
            log "ERROR" "项目创建阶段完全失败。"
            return 1
        fi
        
        GLOBAL_WAIT_SECONDS=$(calculate_global_wait_seconds)
        log "INFO" "阶段2: 全局等待 ${GLOBAL_WAIT_SECONDS} 秒... (基于 $TOTAL_PROJECTS 个项目)"
        start_heartbeat "全局等待中..."
        sleep ${GLOBAL_WAIT_SECONDS}
        stop_heartbeat
        # 修复：确保输出格式正确
        printf "\n"
        
        local ENABLED_PROJECTS_FILE="${TEMP_DIR}/enabled_${retry_count}.txt"
        run_parallel task_enable_api "阶段3: 启用API" "$ENABLED_PROJECTS_FILE" "${created_project_ids[@]}"
        
        local enabled_project_ids=()
        mapfile -t enabled_project_ids < "$ENABLED_PROJECTS_FILE"
        if [ ${#enabled_project_ids[@]} -eq 0 ]; then
            log "ERROR" "API启用阶段完全失败。"
            return 1
        fi
        
        local KEYS_CREATED_FILE="${TEMP_DIR}/keys_created_${retry_count}.txt"
        run_parallel task_create_key "阶段4: 创建密钥" "$KEYS_CREATED_FILE" "${enabled_project_ids[@]}"
        
        local successful_keys
        successful_keys=$(wc -l < "$KEYS_CREATED_FILE" 2>/dev/null || echo 0)
        local failed_keys=$((${#enabled_project_ids[@]} - successful_keys))
        
        generate_report "$successful_keys" "$failed_keys" "${#enabled_project_ids[@]}" "创建并获取密钥"
        
        # 检查是否有失败的项目
        if [ $failed_keys -gt 0 ] && [ $retry_count -lt $MAX_RETRY_GLOBAL ]; then
            echo
            log "WARN" "检测到 $failed_keys 个项目提取密钥失败"
            read -p "是否要重试创建这些失败的项目? [y/N]: " retry_choice
            
            if [[ "$retry_choice" =~ ^[Yy]$ ]]; then
                ((retry_count++))
                projects_to_create_count=$failed_keys
                log "INFO" "准备重试创建 $projects_to_create_count 个项目..."
                sleep 3
                continue
            else
                log "INFO" "用户选择不重试"
                break
            fi
        else
            if [ $failed_keys -gt 0 ] && [ $retry_count -ge $MAX_RETRY_GLOBAL ]; then
                log "WARN" "已达到最大全局重试次数 ($MAX_RETRY_GLOBAL)，不再重试"
            fi
            break
        fi
    done
    
    # 生成最终统计
    if [ $retry_count -gt 0 ]; then
        echo
        log "INFO" "==================== 最终统计 ===================="
        local total_keys
        total_keys=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null || echo 0)
        log "INFO" "总共成功获取密钥数: $total_keys"
        log "INFO" "执行了 $retry_count 次全局重试"
    fi
}

# 兼容旧函数名
create_projects_and_get_keys_fast() {
    create_projects_phased
}

create_projects_only() {
    SECONDS=0
    log "INFO" "======================================================"
    log "INFO" "功能: 仅创建项目（不提取API密钥）"
    log "INFO" "======================================================"
    log "INFO" "使用随机生成的用户名: ${EMAIL_USERNAME}"
    
    # 询问要创建的项目数量
    read -p "请输入要创建的项目数量 (1-75，默认为$TOTAL_PROJECTS): " custom_count
    custom_count=${custom_count:-$TOTAL_PROJECTS}
    
    if ! [[ "$custom_count" =~ ^[1-9][0-9]*$ ]] || [ "$custom_count" -gt 75 ]; then
        log "ERROR" "无效的项目数量。请输入1-75之间的数字。"
        return 1
    fi
    
    log "INFO" "将创建 $custom_count 个项目"
    log "INFO" "在 3 秒后开始执行..."; sleep 3
    
    local projects_to_create=()
    for i in $(seq 1 $custom_count); do
        local project_num=$(printf "%03d" $i)
        local base_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-${project_num}"
        local project_id=$(echo "$base_id" | tr -cd 'a-z0-9-' | cut -c 1-30 | sed 's/-$//')
        if ! [[ "$project_id" =~ ^[a-z] ]]; then
            project_id="g${project_id:1}"
            project_id=$(echo "$project_id" | cut -c 1-30 | sed 's/-$//')
        fi
        projects_to_create+=("$project_id")
    done
    
    # 创建项目
    local CREATED_PROJECTS_FILE="${TEMP_DIR}/created_projects_only.txt"
    > "$CREATED_PROJECTS_FILE"
    
    export -f task_create_project log retry_with_backoff
    export TEMP_DIR MAX_RETRY_ATTEMPTS
    
    run_parallel task_create_project "创建项目" "$CREATED_PROJECTS_FILE" "${projects_to_create[@]}"
    
    local created_project_ids=()
    if [ -f "$CREATED_PROJECTS_FILE" ]; then
        mapfile -t created_project_ids < "$CREATED_PROJECTS_FILE"
    fi
    
    local success_count=${#created_project_ids[@]}
    local failed_count=$((custom_count - success_count))
    
    # 生成报告
    echo ""
    echo "========== 创建项目报告 =========="
    echo "计划创建: $custom_count 个项目"
    echo "成功创建: $success_count 个项目"
    echo "创建失败: $failed_count 个项目"
    
    if [ $success_count -gt 0 ]; then
        echo ""
        echo "成功创建的项目ID:"
        for project_id in "${created_project_ids[@]}"; do
            echo "  - $project_id"
        done
    fi
    
    echo "=========================="
    
    log "INFO" "======================================================"
    log "INFO" "项目创建完成。未启用API，未创建API密钥。"
    log "INFO" "如需获取API密钥，请使用功能3从现有项目中提取。"
    log "INFO" "======================================================"
}

delete_all_existing_projects() {
  SECONDS=0
  log "INFO" "==================== 功能4: 删除所有项目 ===================="
  local project_list; project_list=$(gcloud projects list --format='value(projectId)' --filter='projectId!~^sys-' --quiet)
  if [ -z "$project_list" ]; then log "INFO" "未找到任何用户项目。"; return 0; fi
  local projects_array; readarray -t projects_array <<< "$project_list"; log "WARN" "找到 ${#projects_array[@]} 个项目。"
  read -p "!!! 危险 !!! 输入 'DELETE-ALL' 确认删除: " r; [[ "$r" == "DELETE-ALL" ]] || { log "INFO" "操作取消。"; return 1; }
  local DELETED_FILE="${TEMP_DIR}/deleted.txt"; run_parallel task_delete_project "删除项目" "$DELETED_FILE" "${projects_array[@]}"
  local success_count; success_count=$(wc -l < "$DELETED_FILE" | xargs); generate_report "$success_count" $((${#projects_array[@]} - success_count)) "${#projects_array[@]}" "删除项目"
}

cleanup_project_api_keys() {
    SECONDS=0; log "INFO" "==================== 功能5: 清理API密钥 ===================="
    local project_list; project_list=$(gcloud projects list --format='value(projectId)' --filter='projectId!~^sys-' --quiet)
    if [ -z "$project_list" ]; then log "INFO" "未找到任何用户项目。"; return 0; fi
    local projects_array; readarray -t projects_array <<< "$project_list"; log "WARN" "将清理 ${#projects_array[@]} 个项目中所有的API密钥。"
    read -p "确认继续吗? [y/N]: " r; [[ "$r" =~ ^[Yy]$ ]] || { log "INFO" "操作取消。"; return 1; }
    echo "API密钥清理日志 - $(date)" > "$CLEANUP_LOG"; local CLEANED_FILE="${TEMP_DIR}/cleaned.txt"
    run_parallel task_cleanup_keys "清理API密钥" "$CLEANED_FILE" "${projects_array[@]}"
    local success_count; success_count=$(wc -l < "$CLEANED_FILE" | xargs); generate_report "$success_count" $((${#projects_array[@]} - success_count)) "${#projects_array[@]}" "清理API密钥"
}

# 列出项目中现有的API密钥
list_existing_api_keys() {
    local project_id="$1"
    local error_log="${TEMP_DIR}/list_keys_${project_id}_error.log"
    
    # 尝试列出现有的API密钥
    local keys_output
    if keys_output=$(gcloud services api-keys list --project="$project_id" --format="value(name,keyString)" --quiet 2>"$error_log"); then
        if [ -n "$keys_output" ]; then
            echo "$keys_output"
            rm -f "$error_log"
            return 0
        fi
    fi
    
    rm -f "$error_log"
    return 1
}

extract_keys_from_existing_projects() {
    SECONDS=0; log "INFO" "==================== 功能2: 从现有项目中提取密钥 ===================="
    log "INFO" "正在获取项目列表..."; local project_list; project_list=$(gcloud projects list --format='value(projectId)' --filter='projectId!~^sys-' --quiet)
    if [ -z "$project_list" ]; then log "INFO" "未找到任何用户项目。"; return 0; fi
    local projects_array; readarray -t projects_array <<< "$project_list"; > "$PURE_KEY_FILE"; > "$COMMA_SEPARATED_KEY_FILE"
    local projects_to_process=(); log "INFO" "正在检查 ${#projects_array[@]} 个项目的密钥状态..."
    start_heartbeat "检查密钥状态..." 10
    for project_id in "${projects_array[@]}"; do
        if ! gcloud services api-keys list --project="$project_id" --format="value(name)" --quiet | grep -q "."; then
            projects_to_process+=("$project_id")
        fi
    done
    stop_heartbeat
    if [ ${#projects_to_process[@]} -eq 0 ]; then log "INFO" "所有项目均已有密钥，无需操作。"; return 0; fi
    log "INFO" "将为 ${#projects_to_process[@]} 个没有密钥的项目创建新密钥。"
    read -p "确认继续吗? [y/N]: " r; [[ "$r" =~ ^[Yy]$ ]] || { log "INFO" "操作已取消。"; return 1; }
    local ENABLED_PROJECTS_FILE="${TEMP_DIR}/existing_enabled.txt"; run_parallel task_enable_api "启用API" "$ENABLED_PROJECTS_FILE" "${projects_to_process[@]}"
    local enabled_project_ids=(); mapfile -t enabled_project_ids < "$ENABLED_PROJECTS_FILE"; if [ ${#enabled_project_ids[@]} -eq 0 ]; then log "ERROR" "API启用阶段失败。"; return 1; fi
    local KEYS_CREATED_FILE="${TEMP_DIR}/existing_keys.txt"; run_parallel task_create_key "创建密钥" "$KEYS_CREATED_FILE" "${enabled_project_ids[@]}"
    local successful_keys; successful_keys=$(wc -l < "$KEYS_CREATED_FILE" 2>/dev/null || echo 0); generate_report "$successful_keys" $((${#projects_to_process[@]} - successful_keys)) "${#projects_to_process[@]}" "提取现有密钥"
}

show_menu() {
  clear; local current_account; current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n1)
  echo "   ______   ______   ____     __  __           __                        "; echo "  / ____/  / ____/  / __ \   / / / /  ___     / /  ____     ___     _____";
  echo " / / __   / /      / /_/ /  / /_/ /  / _ \   / /  / __ \   / _ \   / ___/"; echo "/ /_/ /  / /___   / ____/  / __  /  /  __/  / /  / /_/ /  /  __/  / /    ";
  echo "\____/   \____/  /_/      /_/ /_/   \___/  /_/  / .___/   \___/  /_/     "; echo "                                               /_/                      v2.0"
  echo "========================================================================"; echo "  当前账号: ${current_account:-未登录} | 并发数: $MAX_PARALLEL_JOBS | 等待时间: $(calculate_global_wait_seconds)s (动态)"
  echo "========================================================================"
  echo "  1. 一键创建 ${TOTAL_PROJECTS} 个项目并获取密钥 (推荐, 强健)"; echo "  2. 从现有项目中提取密钥 (智能检查)"; echo "  3. 仅创建项目 (不启用API，不取密钥)"
  echo "  4. 删除所有现有项目 (危险操作)"; echo "  5. 清理所有项目中的API密钥 (危险操作)"; echo "  6. 修改配置参数"; echo; echo "  0. 退出程序"
  echo "========================================================================"
  read -p "请选择功能 [0-6]: " choice
  case $choice in
    1) create_projects_phased ;; 2) extract_keys_from_existing_projects ;; 3) create_projects_only ;; 4) delete_all_existing_projects ;;
    5) cleanup_project_api_keys ;; 6) configure_settings ;; 0) log "INFO" "程序已退出。"; exit 0 ;; *) echo "无效选项。" && sleep 1 ;;
  esac
  read -p "按回车键返回主菜单..."
}

configure_settings() {
  while true; do
      clear; echo "======================== 配置参数 ========================"
      echo " 1. 项目创建数量       : $TOTAL_PROJECTS"; echo " 2. 项目前缀           : $PROJECT_PREFIX (随机生成)"; echo " 3. 最大并发数         : $MAX_PARALLEL_JOBS"
      echo " 4. 全局等待时间(秒)   : $(calculate_global_wait_seconds) (动态: 项目数×2, 最少60秒)"; echo " 5. 最大重试次数       : $MAX_RETRY_ATTEMPTS"
      echo " 6. 最大全局重试次数   : $MAX_RETRY_GLOBAL"; echo; echo " 0. 返回主菜单"
      echo "================================================================"
      read -p "选择要修改的设置 [0-6]: " choice
      case $choice in
          1) read -p "输入新的项目数量 (1-200): " val; if [[ "$val" =~ ^[1-9][0-9]*$ && "$val" -le 200 ]]; then TOTAL_PROJECTS=$val; log "INFO" "配置更新: 项目数量 -> $TOTAL_PROJECTS"; fi;;
          2) echo "项目前缀现在是随机生成的，无法手动修改。" && sleep 2;;
          3) read -p "输入最大并发数 (5-50): " val; if [[ "$val" =~ ^[0-9]+$ && "$val" -ge 5 && "$val" -le 50 ]]; then MAX_PARALLEL_JOBS=$val; log "INFO" "配置更新: 最大并发数 -> $MAX_PARALLEL_JOBS"; fi;;
          4) echo "等待时间现在是动态计算的 (项目数×2, 最少60秒)，无法手动修改。" && sleep 2;;
          5) read -p "输入最大重试次数 (1-5): " val; if [[ "$val" =~ ^[1-5]$ ]]; then MAX_RETRY_ATTEMPTS=$val; log "INFO" "配置更新: 重试次数 -> $MAX_RETRY_ATTEMPTS"; fi;;
          6) read -p "输入最大全局重试次数 (0-5): " val; if [[ "$val" =~ ^[0-5]$ ]]; then MAX_RETRY_GLOBAL=$val; log "INFO" "配置更新: 全局重试次数 -> $MAX_RETRY_GLOBAL"; fi;;
          0) return;;
          *) echo "无效选项。" && sleep 1;;
      esac
  done
}

check_prerequisites() {
    log "INFO" "执行前置检查..."; if ! command -v gcloud &> /dev/null; then log "ERROR" "未找到 'gcloud' 命令。"; return 1; fi
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "."; then log "WARN" "未检测到活跃GCP账号，请先登录。"; gcloud auth login || return 1; fi
    if ! command -v jq &>/dev/null; then log "WARN" "强烈建议安装 'jq' 以获得最可靠的JSON解析！"; fi
    log "INFO" "前置检查通过。"; return 0
}

# ===== 程序入口 =====
trap cleanup_resources EXIT SIGINT SIGTERM
if ! check_prerequisites; then log "ERROR" "前置检查失败，程序退出。"; exit 1; fi
log "INFO" "密钥管理器增强版 v2.0 已启动！"
sleep 1
while true; do show_menu; done
