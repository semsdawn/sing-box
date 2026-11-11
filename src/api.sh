#!/bin/bash

# sb api —— 机器通道（proxyaio fork 新增）
#
# 设计原则（见 proxyAIO/docs/team/singbox-fork-plan.md）：
#   1. 人类交互零变化：本文件只在 `sb api ...` 时被 `load`，人类子命令一行不改。
#   2. stdout 只输出一个 JSON 对象；人类提示一律走 stderr。
#   3. 退出码是契约：0 成功 / 2 需要交互但当前非交互 / 3 校验失败 / 4 未找到 / 1 其它。
#   4. 凭据只走 stdin，永不进 argv、永不回显、永不写日志。

is_fork_ver="v1.20-proxyaio.1"
is_api_mode=1
is_backup_dir=$is_core_dir/backup

# ---------------------------------------------------------------- 输出与退出码

api__json_str() {
    # 把任意字符串安全转成 JSON 字符串字面量（优先 jq，退化到 sed）
    if [[ $is_api_has_jq ]]; then
        jq -cn --arg s "$1" '$s'
    else
        printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')"
    fi
}

api_ok() {
    # api_ok <cmd> <data-json>
    if [[ $is_api_has_jq ]]; then
        jq -cn --arg cmd "$1" --argjson data "${2:-null}" '{ok:true,cmd:$cmd,data:$data,warnings:[]}'
    else
        printf '{"ok":true,"cmd":"%s","data":%s,"warnings":[]}\n' "$1" "${2:-null}"
    fi
    exit 0
}

api_warn_ok() {
    # api_ok 的带 warnings 版本：api_warn_ok <cmd> <data-json> <warning...>
    local cmd=$1 data=$2
    shift 2
    local warnings="[]"
    if [[ $is_api_has_jq ]]; then
        warnings=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
        jq -cn --arg cmd "$cmd" --argjson data "${data:-null}" --argjson w "$warnings" '{ok:true,cmd:$cmd,data:$data,warnings:$w}'
    else
        printf '{"ok":true,"cmd":"%s","data":%s,"warnings":%s}\n' "$cmd" "${data:-null}" "$warnings"
    fi
    exit 0
}

api_error() {
    # api_error <exit-code> <CODE> <message> [hint]
    local code=$1 name=$2 message=$3 hint=${4:-}
    if [[ $is_api_has_jq ]]; then
        jq -cn --arg cmd "${is_api_cmd:-api}" --arg code "$name" --arg msg "$message" --arg hint "$hint" \
            '{ok:false,cmd:$cmd,code:$code,message:$msg,hint:(if $hint=="" then null else $hint end)}'
    else
        printf '{"ok":false,"cmd":"%s","code":"%s","message":"%s"}\n' "${is_api_cmd:-api}" "$name" "$message"
    fi
    exit "$code"
}

api_need_jq() {
    [[ $is_api_has_jq ]] && return 0
    api_error 1 NO_JQ "本机缺少 jq，无法使用 sb api（安装: apt-get install -y jq）" "apt-get install -y jq"
}

# ---------------------------------------------------------------- 工具函数

api__have() {
    command -v "$1" >/dev/null 2>&1
}

# 精确解析 conf 文件：先精确、再 .json 后缀、最后才是唯一前缀匹配。
# 永远排除 .bak / .tmp / .json.json（历史坑：子串匹配把 .bak 也算成候选）。
api_resolve_conf() {
    local want=$1
    [[ ! $want ]] && api_error 2 NEED_INPUT "缺少配置文件参数" "sb api show <file|tag>"

    local base=$is_conf_dir
    [[ ! -d $base ]] && api_error 4 NOT_FOUND "配置目录不存在: $base" "sb add r 39049"

    local name
    name=$(basename "$want")

    # 1) 精确命中（允许带或不带 .json）
    local cand
    for cand in "$name" "${name%.json}.json"; do
        [[ -f "$base/$cand" ]] && {
            printf '%s' "$base/$cand"
            return 0
        }
    done

    # 2) 唯一前缀匹配（只认 *.json，排除备份/临时文件）
    local hits=()
    while IFS= read -r f; do
        [[ $f ]] && hits+=("$f")
    done < <(ls -1 "$base" 2>/dev/null | grep -E '\.json$' | grep -v -E '\.json\.(bak|tmp)$|\.json\.json$' | grep -F "$name")

    if [[ ${#hits[@]} -eq 1 ]]; then
        printf '%s' "$base/${hits[0]}"
        return 0
    fi
    if [[ ${#hits[@]} -gt 1 ]]; then
        api_error 2 AMBIGUOUS "匹配到多个配置文件，请给出完整文件名: ${hits[*]}" "sb api list"
    fi
    api_error 4 NOT_FOUND "找不到配置文件: $want" "sb api list"
}

api_conf_list() {
    local base=$is_conf_dir
    [[ ! -d $base ]] && return 0
    ls -1 "$base" 2>/dev/null | grep -E '\.json$' | grep -v -E '\.json\.(bak|tmp)$|\.json\.json$'
}

api_core_version() {
    if [[ -x $is_core_bin ]]; then
        $is_core_bin version 2>/dev/null | head -n1 | awk '{print $3}'
    fi
}

api_uptime_state() {
    if [[ $is_systemd ]]; then
        systemctl is-active $is_core 2>/dev/null | head -n1
    elif [[ $is_openrc ]]; then
        rc-service $is_core status 2>&1 | head -n1
    else
        pgrep -f $is_core_bin >/dev/null 2>&1 && echo running || echo stopped
    fi
}

# ---------------------------------------------------------------- 子命令

api_cmd_version() {
    local core
    core=$(api_core_version)
    api_ok version "$(jq -cn \
        --arg sh "${is_sh_ver:-}" \
        --arg fork "$is_fork_ver" \
        --arg core "$core" \
        --arg conf "$is_conf_dir" \
        --arg backup "$is_backup_dir" \
        '{sh_ver:$sh,fork_ver:$fork,core_ver:$core,conf_dir:$conf,backup_dir:$backup,
          features:["api","version","port-free","restart","check","show","list","get","outbound-set"]}')"
}

api_cmd_port_free() {
    get_port
    [[ ! $tmp_port ]] && api_error 3 PORT_FAILED "未能分配空闲端口" "ss -ltn"
    api_ok port.free "$(jq -cn --argjson p "$tmp_port" '{port:$p}')"
}

api_cmd_restart() {
    local state
    if [[ $is_systemd ]]; then
        systemctl restart $is_core >/dev/null 2>&1
        sleep 1
        state=$(systemctl is-active $is_core 2>/dev/null | head -n1)
    elif [[ $is_openrc ]]; then
        rc-service $is_core restart >/dev/null 2>&1
        sleep 1
        state=$(api_uptime_state)
    else
        api_error 1 UNSUPPORTED "当前系统不支持服务管理（无 systemctl/rc-service）"
    fi
    if [[ $state == active || $state == started || $state == running ]]; then
        api_ok restart "$(jq -cn --arg s "$state" '{restarted:true,state:$s}')"
    fi
    api_error 3 RESTART_FAILED "重启后状态: ${state:-unknown}" "journalctl -u $is_core -n 50 --no-pager"
}

api_cmd_check() {
    local file=$1
    local path
    path=$(api_resolve_conf "$file")
    [[ ! -x $is_core_bin ]] && api_error 1 NO_CORE "核心不存在: $is_core_bin" "sb update --with-core"

    local out rc
    out=$($is_core_bin check -c "$path" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        api_ok check "$(jq -cn --arg f "$(basename "$path")" '{file:$f,checked:true}')"
    fi
    api_error 3 CHECK_FAILED "$(printf '%s' "$out" | tail -n 3 | tr '\n' ' ' | sed 's/  */ /g')" "sb api check $file"
}

# 以下四个子命令在后续提交中实现（Part 2: list/show/get，Part 3: outbound）
api_cmd_list() {
    api_error 1 NOT_IMPLEMENTED "sb api list 尚未实现（Part 2）" "sb list"
}

api_cmd_show() {
    api_error 1 NOT_IMPLEMENTED "sb api show 尚未实现（Part 2）" "sb info"
}

api_cmd_get() {
    api_error 1 NOT_IMPLEMENTED "sb api get 尚未实现（Part 2）" "sb info"
}

api_cmd_outbound() {
    api_error 1 NOT_IMPLEMENTED "sb api outbound 尚未实现（Part 3）" "sb api show <file>"
}

api_cmd_help() {
    cat <<'EOF' >&2
sb api —— 机器通道（输出单个 JSON 对象，退出码即契约）

  sb api version                 版本与能力（含 fork_ver）
  sb api list                    列出全部配置文件及其摘要
  sb api show <file|tag> [--raw] 整份配置（--raw 时只有原文 JSON）
  sb api get <file> <jq路径>     任意路径取值
  sb api check <file>            sing-box check 结构化结果
  sb api port free               分配空闲端口
  sb api restart                 重启并返回 is-active
  sb api outbound set|unset ...  写入/移除出口配置（凭据走 stdin）

退出码: 0 成功 / 2 需要交互或参数不足 / 3 校验或执行失败 / 4 未找到 / 1 其它
EOF
    exit 2
}

# ---------------------------------------------------------------- 入口

api_main() {
    is_api_cmd=${1:-help}
    [[ ! -t 0 ]] || true # 交互终端也允许 api 模式，只是不提供 prompt 保底

    if api__have jq; then is_api_has_jq=1; fi

    case $1 in
    version | --version | -v) api_cmd_version ;;
    port)
        case $2 in
        free | get) api_cmd_port_free ;;
        *) api_error 2 NEED_INPUT "未知的 port 子命令: ${2:-}" "sb api port free" ;;
        esac
        ;;
    restart) api_cmd_restart ;;
    check) api_cmd_check "$2" ;;
    list) api_cmd_list ;;
    show) api_cmd_show "$2" "${@:3}" ;;
    get) api_cmd_get "$2" "$3" ;;
    outbound) api_cmd_outbound "${@:2}" ;;
    help | --help | -h | "") api_cmd_help ;;
    *) api_error 2 UNKNOWN_COMMAND "未知的 api 子命令: $1" "sb api help" ;;
    esac
}
