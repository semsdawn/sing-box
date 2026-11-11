#!/bin/bash

# sb api —— 机器通道（proxyaio fork 新增）
#
# 设计原则（见 proxyAIO/docs/team/singbox-fork-plan.md）：
#   1. 人类交互零变化：本文件只在 `sb api ...` 时被 `load`，人类子命令一行不改。
#   2. stdout 只输出一个 JSON 对象；人类提示一律走 stderr。
#   3. 退出码是契约：0 成功 / 2 需要交互或参数不足 / 3 校验或执行失败 / 4 未找到 / 1 其它。
#   4. 凭据只走 stdin，永不进 argv、永不回显、永不写日志。

is_fork_ver="v1.20-proxyaio.1"
is_api_mode=1
is_backup_dir=$is_core_dir/backup

# ---------------------------------------------------------------- 输出与退出码

api_ok() {
    if [[ $is_api_has_jq ]]; then
        jq -cn --arg cmd "$1" --argjson data "${2:-null}" '{ok:true,cmd:$cmd,data:$data,warnings:[]}'
    else
        printf '{"ok":true,"cmd":"%s","data":%s,"warnings":[]}\n' "$1" "${2:-null}"
    fi
    exit 0
}

api_error() {
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
    api_error 1 NO_JQ "本机缺少 jq，无法使用 sb api" "apt-get install -y jq"
}

# ---------------------------------------------------------------- 工具函数

api__have() { command -v "$1" >/dev/null 2>&1; }

api__now() { date +%Y%m%d-%H%M%S; }

# 解析 conf 路径：复用 core.sh 的 conf_candidates（精确优先、只认 *.json）
api_resolve_conf() {
    local want=$1
    [[ ! $want ]] && api_error 2 NEED_INPUT "缺少配置文件参数" "sb api show <file|tag>"
    local base=$is_conf_dir
    [[ ! -d $base ]] && api_error 4 NOT_FOUND "配置目录不存在: $base" "sb add r 39049"

    local hits=() v
    while IFS= read -r v; do
        [[ $v ]] && hits+=("$v")
    done < <(conf_candidates "$want")

    case ${#hits[@]} in
    1) printf '%s' "$base/${hits[0]}" ;;
    0) api_error 4 NOT_FOUND "找不到配置文件: $want" "sb api list" ;;
    *) api_error 2 AMBIGUOUS "匹配到多个配置文件，请给出完整文件名: ${hits[*]}" "sb api list" ;;
    esac
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

# 由 conf 计算摘要（不依赖固定下标；凭据只报布尔）
api_derived() {
    local path=$1
    jq -c '
    def user_items: ((.users // []) | map({
        uuid: (.uuid // null),
        flow: (.flow // null),
        username: (.username // null),
        has_password: ((.password // null) != null)
    }));
    def inbound_item: {
        index: .key,
        type: (.value.type // null),
        tag: (.value.tag // null),
        listen_port: (.value.listen_port // null),
        users: (.value | user_items)
    };
    def outbound_item: {
        index: .key,
        type: (.value.type // null),
        tag: (.value.tag // null),
        server: (.value.server // null),
        server_port: (.value.server_port // null),
        has_auth: (((.value.username // null) != null) or ((.value.password // null) != null))
    };
    {
        inbounds: ((.inbounds // []) | to_entries | map(inbound_item)),
        outbounds: ((.outbounds // []) | to_entries | map(outbound_item)),
        route: {
            rules: ((.route.rules // []) | map({
                inbound: (.inbound // null),
                outbound: (.outbound // null),
                action: (.action // null)
            })),
            final: (.route.final // null)
        },
        tls: (((.inbounds // []) | map(.tls) | map(select(. != null))) as $t
            | if ($t | length) > 0 then {
                server_name: ($t[0].server_name // null),
                has_private_key: (((($t[0].reality) // {}).private_key) != null),
                has_public_key: (((($t[0].reality) // {}).public_key) != null),
                short_id: (((($t[0].reality) // {}).short_id) // null)
            } else null end)
    }' "$path"
}

api__restart_core() {
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
        return 1
    fi
    [[ $state == active || $state == started || $state == running ]] && return 0
    return 1
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
          features:["api","version","port-free","restart","check","show","list","get","outbound-set","outbound-unset"]}')"
}

api_cmd_port_free() {
    get_port
    [[ ! $tmp_port ]] && api_error 3 PORT_FAILED "未能分配空闲端口" "ss -ltn"
    api_ok port.free "$(jq -cn --argjson p "$tmp_port" '{port:$p}')"
}

api_cmd_restart() {
    if api__restart_core; then
        api_ok restart "$(jq -cn --arg s "$(api_uptime_state)" '{restarted:true,state:$s}')"
    fi
    api_error 3 RESTART_FAILED "重启后状态: $(api_uptime_state)" "journalctl -u $is_core -n 50 --no-pager"
}

api_cmd_check() {
    local file=$1 path
    path=$(api_resolve_conf "$file") || exit $?
    [[ ! -x $is_core_bin ]] && api_error 1 NO_CORE "核心不存在: $is_core_bin" "sb update --with-core"

    local out rc
    out=$($is_core_bin check -c "$path" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        api_ok check "$(jq -cn --arg f "$(basename "$path")" '{file:$f,checked:true}')"
    fi
    api_error 3 CHECK_FAILED "$(printf '%s' "$out" | tail -n 3 | tr '\n' ' ' | sed 's/  */ /g')" "sb api check $file"
}

api_cmd_list() {
    api_need_jq
    local jsons=() f item
    while IFS= read -r f; do
        [[ ! $f ]] && continue
        item=$(jq -c --arg file "$f" '{
            file: $file,
            protocol: ((.inbounds[0].type) // null),
            port: ((.inbounds[0].listen_port) // null),
            inbound_tag: ((.inbounds[0].tag) // null),
            inbound_tags: ((.inbounds // []) | map(.tag) | map(select(. != null))),
            outbound_tags: ((.outbounds // []) | map(.tag) | map(select(. != null))),
            route_outbounds: ((.route.rules // []) | map(.outbound) | map(select(. != null))),
            has_route_rules: (((.route.rules // []) | length) > 0)
        }' "$is_conf_dir/$f" 2>/dev/null) || item=""
        [[ $item ]] && jsons+=("$item")
    done < <(api_conf_list)

    if [[ ${#jsons[@]} -eq 0 ]]; then
        api_ok list '{"total":0,"items":[]}'
    fi
    api_ok list "$(printf '%s\n' "${jsons[@]}" | jq -sc '{total:length,items:.}')"
}

api_cmd_show() {
    local file=$1
    shift
    local path is_raw=0 a
    path=$(api_resolve_conf "$file") || exit $?
    for a in "$@"; do
        [[ $a == --raw ]] && is_raw=1
    done
    # --raw 是显式 opt-in：吐整份文件（可能含凭据，调用方不得落日志）
    if [[ $is_raw -eq 1 ]]; then
        cat "$path"
        exit 0
    fi
    api_need_jq
    local derived
    derived=$(api_derived "$path")
    [[ ! $derived ]] && api_error 3 PARSE_FAILED "无法解析配置: $(basename "$path")" "sb api check $file"
    api_ok show "$(jq -cn --arg file "$(basename "$path")" --argjson derived "$derived" \
        '{file:$file,derived:$derived}')"
}

api_cmd_get() {
    local file=$1 expr=$2
    shift 2
    local def=""
    while [[ $# -gt 0 ]]; do
        case $1 in
        --default)
            def=$2
            shift 2
            ;;
        *) shift ;;
        esac
    done

    [[ ! $expr ]] && api_error 2 NEED_INPUT "缺少 jq 路径，例如 .route.rules[0].outbound" "sb api get <file> .inbounds[0].tag"
    local path
    path=$(api_resolve_conf "$file") || exit $?
    api_need_jq

    local val rc
    val=$(jq -c "$expr" "$path" 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]]; then
        api_error 3 BAD_QUERY "jq 表达式无效: $(printf '%s' "$val" | head -n1)" "sb api show $file"
    fi
    if [[ $val == null && $def != "" ]]; then
        val=$(jq -cn --arg s "$def" '$s')
    fi
    api_ok get "$(jq -cn --argjson v "$val" '{value:$v}')"
}

# ---------------------------------------------------------------- Part 3：写入/移除出口配置

# 把 $2（新内容文件）落到 $1（conf），带备份/校验/可选重启/幂等判定
# 参数: <path> <work> <tag> <mode> <do_check> <do_restart> <is_dry> <extra-json> [cred-file]
api__commit_conf() {
    local path=$1 work=$2 tag=$3 mode=$4 do_check=$5 do_restart=$6 is_dry=$7 extra=${8:-null}
    local name old_norm new_norm backup="" checked="false" restarted="false"
    name=$(basename "$path")

    old_norm=$(jq -S -c . "$path" 2>/dev/null)
    new_norm=$(jq -S -c . "$work" 2>/dev/null)
    if [[ -n $new_norm && $old_norm == "$new_norm" ]]; then
        rm -f "$work"
        api_ok outbound "$(jq -cn --arg f "$name" --arg t "$tag" --arg m "$mode" --argjson extra "$extra" \
            '{file:$f,outbound_tag:$t,mode:$m,changed:false,applied:false,checked:true,restarted:false,dry_run:false} + $extra')"
    fi

    if [[ $is_dry -eq 1 ]]; then
        local diff
        diff=$(diff <(jq -S . "$path" 2>/dev/null) <(jq -S . "$work" 2>/dev/null) | head -n 60)
        rm -f "$work"
        api_ok outbound "$(jq -cn --arg f "$name" --arg t "$tag" --arg m "$mode" --arg d "$diff" --argjson extra "$extra" \
            '{file:$f,outbound_tag:$t,mode:$m,changed:true,applied:false,checked:false,restarted:false,dry_run:true,diff:$d} + $extra')"
    fi

    if [[ $do_check -eq 1 && -x $is_core_bin ]]; then
        local cout crc
        cout=$($is_core_bin check -c "$work" 2>&1)
        crc=$?
        if [[ $crc -ne 0 ]]; then
            rm -f "$work"
            api_error 3 CHECK_FAILED "sing-box check 未通过，未做任何改动: $(printf '%s' "$cout" | tail -n 2 | tr '\n' ' ')" "sb api check $name"
        fi
        checked="true"
    fi

    mkdir -p "$is_backup_dir" 2>/dev/null
    if [[ -d $is_backup_dir ]]; then
        backup="$is_backup_dir/$name.$(api__now).bak"
        cp -p "$path" "$backup" 2>/dev/null || backup=""
    fi

    if ! mv -f "$work" "$path" 2>/dev/null; then
        api_error 3 WRITE_FAILED "原子替换失败（原文件未改）" "ls -l $is_conf_dir"
    fi

    if [[ $do_restart -eq 1 ]]; then
        if api__restart_core; then
            restarted="true"
        else
            api_error 3 RESTART_FAILED "配置已写入但重启失败，请人工检查（备份: ${backup:-无}）" "journalctl -u $is_core -n 50 --no-pager"
        fi
    fi

    api_ok outbound "$(jq -cn --arg f "$name" --arg t "$tag" --arg m "$mode" --arg b "$backup" \
        --arg json_checked "$checked" --arg json_restarted "$restarted" --argjson extra "$extra" \
        '{file:$f,outbound_tag:$t,mode:$m,changed:true,applied:true,
          checked:($json_checked=="true"),restarted:($json_restarted=="true"),dry_run:false,
          backup:(if $b=="" then null else $b end)} + $extra')"
}

api_cmd_outbound() {
    local action=${1:-}
    shift || true
    case $action in
    set | unset) ;;
    "" | help | --help | -h) api_error 2 NEED_INPUT "缺少 outbound 子命令" "sb api outbound set <file> --server H --port P --tag T" ;;
    *) api_error 2 UNKNOWN_COMMAND "未知的 outbound 子命令: $action" "sb api outbound set|unset" ;;
    esac

    local file="" type="socks" server="" port="" tag="" auth_stdin=0 rfi=0 do_check=1 do_restart=0 is_dry=0
    while [[ $# -gt 0 ]]; do
        case $1 in
        --type) type=$2; shift 2 ;;
        --server) server=$2; shift 2 ;;
        --port) port=$2; shift 2 ;;
        --tag) tag=$2; shift 2 ;;
        --auth-stdin) auth_stdin=1; shift ;;
        --route-from-inbound) rfi=1; shift ;;
        --no-check) do_check=0; shift ;;
        --restart) do_restart=1; shift ;;
        --dry-run) is_dry=1; shift ;;
        -*) api_error 2 BAD_ARG "未知参数: $1" "sb api outbound help" ;;
        *) if [[ $file ]]; then api_error 2 BAD_ARG "多余参数: $1" "sb api outbound help"; else file=$1; fi; shift ;;
        esac
    done

    [[ ! $file ]] && api_error 2 NEED_INPUT "缺少配置文件参数" "sb api outbound set <file> --tag T"
    [[ ! $tag ]] && api_error 2 NEED_INPUT "缺少 --tag" "sb api outbound set <file> --tag isp-socks-39049"
    api_need_jq

    local path
    path=$(api_resolve_conf "$file") || exit $?

    local work cred_file
    work=$(mktemp 2>/dev/null || mktemp -t sbwork)
    cred_file=$(mktemp 2>/dev/null || mktemp -t sbcred)
    chmod 600 "$cred_file" 2>/dev/null
    printf '{}' >"$cred_file"

    if [[ $action == set && $auth_stdin -eq 1 ]]; then
        cat >"$cred_file"
        if ! jq -e . "$cred_file" >/dev/null 2>&1; then
            rm -f "$work" "$cred_file"
            api_error 2 BAD_CREDENTIAL 'stdin 不是合法 JSON（应为 {"username":..,"password":..}）' "echo '{\"username\":\"u\",\"password\":\"p\"}' | sb api outbound set ..."
        fi
    fi

    if [[ $action == set ]]; then
        if [[ ! $server || ! $port ]]; then
            rm -f "$work" "$cred_file"
            api_error 2 NEED_INPUT "缺少 --server / --port" "sb api outbound set <file> --server 1.2.3.4 --port 51524 --tag isp-socks-<port>"
        fi
        if ! jq -c --arg tag "$tag" --arg type "$type" --arg server "$server" --arg sport "$port" --argjson rfi "$rfi" \
            --slurpfile cred "$cred_file" '
            ($cred[0] // {}) as $c
            | .outbounds = (((.outbounds // []) | map(select(.tag != $tag))) + [{
                type: $type,
                tag: $tag,
                server: $server,
                server_port: ($sport | tonumber),
                version: "5",
                username: ($c.username // null),
                password: ($c.password // null)
              } | with_entries(select(.value != null))])
            | (if $rfi == 1 then
                 (.inbounds[0].tag) as $inb
                 | .route = ((.route // {}) |
                     .rules = (((.rules // []) | map(select((((.inbound // []) | index($inb)) | not)))) +
                               [{"inbound": [$inb], "action": "route", "outbound": $tag}]))
               else . end)
            | (if ((.route.final // null) == null) then .route.final = "direct" else . end)
            ' "$path" >"$work" 2>/dev/null; then
            rm -f "$work" "$cred_file"
            api_error 3 TRANSFORM_FAILED "配置变换失败（原文件未改）" "sb api check $(basename "$path")"
        fi
        local extra
        extra=$(jq -cn --argjson rfi "$rfi" '{route_from_inbound:($rfi==1)}')
        rm -f "$cred_file"
        api__commit_conf "$path" "$work" "$tag" "set" "$do_check" "$do_restart" "$is_dry" "$extra"
    else
        if ! jq -c --arg tag "$tag" '
            .outbounds = ((.outbounds // []) | map(select(.tag != $tag)))
            | (if ((.route.rules // []) | length) > 0 then
                 .route.rules = ((.route.rules // []) | map(select((.outbound // null) != $tag)))
               else . end)
            | (if ((.route.final // null) == $tag) then .route.final = "direct" else . end)
            ' "$path" >"$work" 2>/dev/null; then
            rm -f "$work" "$cred_file"
            api_error 3 TRANSFORM_FAILED "配置变换失败（原文件未改）" "sb api check $(basename "$path")"
        fi
        rm -f "$cred_file"
        api__commit_conf "$path" "$work" "$tag" "unset" "$do_check" "$do_restart" "$is_dry" '{"route_from_inbound":false}'
    fi
}

api_cmd_help() {
    cat <<'EOF' >&2
sb api —— 机器通道（输出单个 JSON 对象，退出码即契约）

  sb api version                  版本与能力（含 fork_ver）
  sb api list                     列出全部配置文件及其摘要
  sb api show <file|tag> [--raw]  整份配置（默认只给 derived 摘要；--raw 才吐原文）
  sb api get <file> <jq路径>      任意路径取值（--default X 兜底）
  sb api check <file>             sing-box check 结构化结果
  sb api port free                分配空闲端口
  sb api restart                  重启并返回 is-active
  sb api outbound set <file> --server H --port P --tag T [--auth-stdin]
                     [--route-from-inbound] [--no-check] [--restart] [--dry-run]
  sb api outbound unset <file> --tag T [--no-check] [--restart] [--dry-run]

退出码: 0 成功 / 2 需要交互或参数不足 / 3 校验或执行失败 / 4 未找到 / 1 其它
EOF
    exit 2
}

# ---------------------------------------------------------------- 入口

api_main() {
    is_api_cmd=${1:-help}
    if api__have jq; then is_api_has_jq=1; fi

    case $1 in
    version | --version | -v) api_cmd_version ;;
    port)
        case ${2:-} in
        free | get) api_cmd_port_free ;;
        *) api_error 2 NEED_INPUT "未知的 port 子命令: ${2:-}" "sb api port free" ;;
        esac
        ;;
    restart) api_cmd_restart ;;
    check) api_cmd_check "${2:-}" ;;
    list) api_cmd_list ;;
    show) api_cmd_show "${2:-}" "${@:3}" ;;
    get) api_cmd_get "${2:-}" "${3:-}" "${@:4}" ;;
    outbound) api_cmd_outbound "${@:2}" ;;
    help | --help | -h | "") api_cmd_help ;;
    *) api_error 2 UNKNOWN_COMMAND "未知的 api 子命令: $1" "sb api help" ;;
    esac
}
