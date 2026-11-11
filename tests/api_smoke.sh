#!/usr/bin/env bash
# sb api 冒烟测试（不依赖真实 sing-box / systemd / 网络）
# 用法: bash tests/api_smoke.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t sbapi)
trap 'rm -rf "$tmp"' EXIT

is_conf_dir=$tmp/conf
is_core_dir=$tmp/core
is_backup_dir=$is_core_dir/backup
is_sh_ver="v1.20"
is_core=sing-box
is_systemd=""
is_openrc=""
mkdir -p "$is_conf_dir" "$is_core_dir"

# 假核心：version 固定；check 由 FAKE_CHECK_RC 控制
cat >"$is_core_dir/sing-box" <<'EOS'
#!/usr/bin/env bash
case "$1" in
version) echo "sing-box version 1.14.4"; exit 0 ;;
check)
    if [[ ${FAKE_CHECK_RC:-0} == 0 ]]; then exit 0; else echo "FATAL decode config at line 3: unknown field"; exit 1; fi
    ;;
esac
exit 0
EOS
chmod +x "$is_core_dir/sing-box"
is_core_bin=$is_core_dir/sing-box

# 只抽被测函数，不 source core.sh（有副作用）
eval "$(sed -n '/^conf_candidates()/,/^}/p' "$root/src/core.sh")"
# shellcheck disable=SC1091
. "$root/src/api.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
has() { [[ $2 == *"$3"* ]] && ok "$1" || no "$1" "期望包含 [$3]，实际: ${2:0:200}"; }
lacks() { [[ $2 != *"$3"* ]] && ok "$1" || no "$1" "不应包含 [$3]"; }
eq() { [[ $2 == "$3" ]] && ok "$1" || no "$1" "期望 [$3]，实际 [$2]"; }

run() { ( api_main "$@" ) 2>/dev/null; }
rc_of() { ( api_main "$@" ) >/dev/null 2>&1; echo $?; }

# ---------------------------------------------------------------- 夹具
cat >"$is_conf_dir/VLESS-REALITY-39049.json" <<'EOJ'
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "vless", "tag": "VLESS-REALITY-39049.json", "listen": "::", "listen_port": 39049,
     "users": [{"uuid": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision"}],
     "tls": {"server_name": "aws.amazon.com", "reality": {"private_key": "S3CRET_PRIV", "short_id": ""}}}
  ],
  "outbounds": [
    {"type": "socks", "tag": "isp-socks-39049", "server": "136.162.193.215", "server_port": 51524,
     "version": "5", "username": "socksuser", "password": "S3CRET_PASS"},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"rules": [{"inbound": ["VLESS-REALITY-39049.json"], "action": "route", "outbound": "isp-socks-39049"}], "final": "direct"}
}
EOJ
# 历史坑：同名 .bak 与 .tmp 不能被当成候选
echo '{"inbounds":[]}' >"$is_conf_dir/VLESS-REALITY-39049.json.bak"
echo '{}' >"$is_conf_dir/VLESS-REALITY-39049.json.tmp"

# ---------------------------------------------------------------- 解析

out=$(run show VLESS-REALITY-39049.json)
has "show 传完整文件名不会被 .bak 干扰" "$out" '"ok":true'
has "show 返回文件名" "$out" '"file":"VLESS-REALITY-39049.json"'
eq "show 不因 .bak 报 AMBIGUOUS" "$(rc_of show VLESS-REALITY-39049.json)" "0"

out=$(run show VLESS-REALITY-39049)
has "show 短名命中" "$out" '"file":"VLESS-REALITY-39049.json"'

out=$(run show VLESS-REALITY-39049.json.bak)
has "show 显式 .bak 也能读（但不在 list 里）" "$out" '"file":"VLESS-REALITY-39049.json.bak"'

eq "show 找不到的退出码=4" "$(rc_of show nosuchfile)" "4"

# ---------------------------------------------------------------- 摘要与凭据

out=$(run show VLESS-REALITY-39049.json)
has "derived.inbounds 带 listen_port" "$out" '"listen_port":39049'
has "derived.inbounds 带 flow" "$out" '"flow":"xtls-rprx-vision"'
has "derived.outbounds 认证只报布尔" "$out" '"has_auth":true'
has "derived.route.rules 命中" "$out" '"outbound":"isp-socks-39049"'
has "derived.tls 私钥只报布尔" "$out" '"has_private_key":true'
has "derived.tls 带 sni" "$out" '"server_name":"aws.amazon.com"'
lacks "默认 show 不含口令明文" "$out" "S3CRET_PASS"
lacks "默认 show 不含私钥明文" "$out" "S3CRET_PRIV"

out=$(run show VLESS-REALITY-39049.json --raw)
has "--raw 返回原文" "$out" '"listen_port": 39049'

# ---------------------------------------------------------------- list

out=$(run list)
has "list 有 total" "$out" '"total":1'
has "list 带 inbound_tag" "$out" '"inbound_tag":"VLESS-REALITY-39049.json"'
has "list 带 outbound_tags" "$out" '"outbound_tags":["isp-socks-39049","direct"]'
lacks "list 不含 .bak" "$out" '.json.bak'
lacks "list 不含口令" "$out" "S3CRET_PASS"

# ---------------------------------------------------------------- get

out=$(run get VLESS-REALITY-39049.json '.route.rules[0].outbound')
has "get 任意路径" "$out" '"value":"isp-socks-39049"'

out=$(run get VLESS-REALITY-39049.json '.no.such.path' --default fallback)
has "get --default 兜底" "$out" '"value":"fallback"'

eq "get 非法表达式退出码=3" "$(rc_of get VLESS-REALITY-39049.json '.[bad')" "3"
out=$(run get VLESS-REALITY-39049.json '.[bad')
has "get 非法表达式给出 BAD_QUERY" "$out" '"code":"BAD_QUERY"'

# ---------------------------------------------------------------- check

eq "check 通过退出码=0" "$(rc_of check VLESS-REALITY-39049.json)" "0"
out=$(FAKE_CHECK_RC=1 run check VLESS-REALITY-39049.json)
has "check 失败返回 CHECK_FAILED" "$out" '"code":"CHECK_FAILED"'
eq "check 失败退出码=3" "$(FAKE_CHECK_RC=1 rc_of check VLESS-REALITY-39049.json)" "3"

# ---------------------------------------------------------------- 契约

eq "未知子命令退出码=2" "$(rc_of nope)" "2"
out=$(run nope)
has "未知子命令返回 UNKNOWN_COMMAND" "$out" '"code":"UNKNOWN_COMMAND"'

eq "show 缺参数退出码=2" "$(rc_of show)" "2"

out=$(run version)
has "version 带 fork_ver" "$out" '"fork_ver":"v1.20-proxyaio.2"'
has "version 带 core_ver" "$out" '"core_ver":"1.14.4"'
has "version 带 features" "$out" '"outbound-set"'

eq "outbound 缺子命令退出码=2" "$(rc_of outbound)" "2"

# ---------------------------------------------------------------- outbound set/unset

conf=$is_conf_dir/VLESS-REALITY-39049.json
before=$(cat "$conf")

# 无认证的裸出站先测：不带 --auth-stdin
out=$(run outbound set VLESS-REALITY-39049.json --type socks --server 10.0.0.9 --port 1080 --tag isp-socks-test --route-from-inbound)
has "set 首次 changed=true" "$out" '"changed":true'
has "set applied=true" "$out" '"applied":true'
has "set 记录 route_from_inbound" "$out" '"route_from_inbound":true'
has "set 返回 backup 路径" "$out" '"backup":"'; has "backup 是 .bak 文件" "$out" '.bak"'
lacks "set 输出不含口令" "$out" "S3CRET"

# 第二次同参数 → 幂等
out=$(run outbound set VLESS-REALITY-39049.json --type socks --server 10.0.0.9 --port 1080 --tag isp-socks-test --route-from-inbound)
has "set 重复执行 changed=false" "$out" '"changed":false'
has "set 重复执行 applied=false" "$out" '"applied":false'

# 结构验证：出站已写入、route 指向它
out=$(run get VLESS-REALITY-39049.json '[.outbounds[] | select(.tag=="isp-socks-test") | .server_port]|.[0]')
has "出站写入 server_port" "$out" '1080'
out=$(run get VLESS-REALITY-39049.json '[.route.rules[] | select(.outbound=="isp-socks-test")]|length')
has "route 规则已加" "$out" '1'

# 带凭据（--auth-stdin）
out=$(echo '{"username":"u1","password":"p1"}' | run outbound set VLESS-REALITY-39049.json --type socks --server 10.0.0.10 --port 1081 --tag isp-socks-auth --auth-stdin)
has "set --auth-stdin 生效" "$out" '"applied":true'
lacks "set --auth-stdin 不回显口令" "$out" "p1"
out=$(run get VLESS-REALITY-39049.json '[.outbounds[] | select(.tag=="isp-socks-auth") | .username]|.[0]')
has "凭据已写入 username" "$out" 'u1'

# 非法凭据 JSON
eq "非法凭据 JSON 退出码=2" "$(echo 'not-json' | ( api_main outbound set VLESS-REALITY-39049.json --server 1.1.1.1 --port 1 --tag t --auth-stdin ) >/dev/null 2>&1; echo $?)" "2"

# --dry-run 不落盘
snapshot=$(cat "$conf")
out=$(run outbound set VLESS-REALITY-39049.json --type socks --server 10.0.0.11 --port 1082 --tag isp-socks-dry --dry-run)
has "dry-run 标记" "$out" '"dry_run":true'
has "dry-run 给出 diff" "$out" '"diff":'
eq "dry-run 未改文件" "$(cat "$conf")" "$snapshot"

# check 失败 → 不落盘
snapshot=$(cat "$conf")
out=$(FAKE_CHECK_RC=1 run outbound set VLESS-REALITY-39049.json --type socks --server 10.0.0.12 --port 1083 --tag isp-socks-bad)
has "check 失败返回 CHECK_FAILED" "$out" '"code":"CHECK_FAILED"'
eq "check 失败未改文件" "$(cat "$conf")" "$snapshot"

# unset
out=$(run outbound unset VLESS-REALITY-39049.json --tag isp-socks-test)
has "unset applied" "$out" '"applied":true'
out=$(run get VLESS-REALITY-39049.json '[.outbounds[] | select(.tag=="isp-socks-test")]|length')
has "unset 后出站已移除" "$out" '0'
out=$(run get VLESS-REALITY-39049.json '[.route.rules[] | select(.outbound=="isp-socks-test")]|length')
has "unset 后 route 规则已清理" "$out" '0'

# 备份目录卫生：不得写进 conf 目录
eq "conf 目录只有夹具那一个 .bak（脚本没写进 conf）" "$(ls "$is_conf_dir" | grep -c '\.bak$')" "1"
if ls "$is_backup_dir"/*.bak >/dev/null 2>&1; then ok "backup 目录里有 .bak 文件"; else no "backup 目录里有 .bak 文件" "空"; fi
[[ -d $is_backup_dir ]] && ok "backup 目录已创建" || no "backup 目录已创建" "$is_backup_dir 不存在"


# ---------------------------------------------------------------- Part 4: add / del

# 测试桩：模拟脚本内部的 add()（按端口生成一个 conf 文件）
add() {
    local alias=$1 port=${2:-50000}
    [[ $port == auto || -z $port ]] && port=50000
    cat >"$is_conf_dir/VLESS-REALITY-$port.json" <<EOJ
{"inbounds":[{"type":"vless","tag":"VLESS-REALITY-$port.json","listen_port":$port}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}
EOJ
}

out=$(run add reality 50000)
has "api add 返回文件名" "$out" '"file":"VLESS-REALITY-50000.json"'
has "api add 返回端口" "$out" '"port":50000'
has "api add 返回协议" "$out" '"protocol":"vless"'
has "api add 默认不重启" "$out" '"restarted":false'
lacks "api add 的 stdout 只有 JSON（人类输出已转 stderr）" "$out" "-------------" 

out=$(run del VLESS-REALITY-50000.json)
has "api del 删除成功" "$out" '"deleted":true'
has "api del 返回剩余文件数" "$out" '"remaining_files":'
eq "api del 后文件消失" "$(ls "$is_conf_dir" | grep -c 50000)" "0"
eq "api del 找不到退出码=4" "$(rc_of del nosuchfile)" "4"
eq "api del 缺参数退出码=2" "$(rc_of del)" "2"

# ---- Part 4b: add 同时配出口（一次性） ----
out=$(echo '{"username":"uo","password":"po"}' | run add reality 50001 --addr 1.2.3.4 --outbound-server 10.0.0.9 --outbound-port 1080 --outbound-tag isp-socks-50001 --auth-stdin --route-from-inbound)
has "add+outbound 返回文件" "$out" '"file":"VLESS-REALITY-50001.json"'
has "add+outbound 标记 applied" "$out" '"applied":true'
has "add+outbound 带 route_from_inbound" "$out" '"route_from_inbound":true'
lacks "add+outbound 不回显口令" "$out" '"po"'
out=$(run get VLESS-REALITY-50001.json '[.outbounds[]|select(.tag=="isp-socks-50001")|.username]|.[0]')
has "add+outbound 凭据已写入" "$out" 'uo'
out=$(run get VLESS-REALITY-50001.json '[.route.rules[]|select(.outbound=="isp-socks-50001")]|length')
has "add+outbound 路由已写入" "$out" '1'

# 缺 --outbound-port 应报参数不足
eq "add+outbound 缺 port 退出码=2" "$(rc_of add reality 50002 --outbound-server 1.1.1.1 --outbound-tag t)" "2"

# ---------------------------------------------------------------- 汇总
printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[[ $fail -eq 0 ]]
