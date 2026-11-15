#!/bin/sh
# Nikki+ 一行安装脚本，由 scripts/gen-install.sh 生成；不要直接编辑生成产物。
set -eu
BUILD_TS=1794737139

# dnsmasq 替换逻辑，spec 第 3 节第 5 步：dns-upgrade 的全部内容原样作为子 shell 函数，
# 用法 <id> <结果文件>，结果 JSON 的 error 为 null 或 download/install/restart。
dns_upgrade() (
# dnsmasq 不支持 nftset 时替换为 dnsmasq-full。由 task-start 在后台启动（向导「升级 DNS 组件」，spec 第 15 节），
# 安装脚本（spec 第 3 节第 5 步）复用同一份替换逻辑，仓库中不得出现第二份（tests/run.sh 静态检查）。
# 用法：dns-upgrade <id> <结果文件>。结果为 { id, time, error }，error 为空或 download、install、restart。
# 替换前备份 /etc/config/dhcp 到 /tmp/dhcp.bak-nikkiplus；下载失败时不留任何改动，备份也删除。
# opkg 先 --download-only 再 remove 再装本地包；apk 在同一事务中替换，--cache-dir --cache-predownload
# 让它在提交事务前下载完全部包，下载失败时事务中止（research/openwrt-packaging.md §4）。
set -e
id=$1 result=$2

# 与 detect.uc 的 nftset_supported 相同的判断：Compile time options 行中的完整单词 nftset。
nftset() {
	dnsmasq --version 2>/dev/null | sed -n 's/^Compile time options: //p' | tr ' ' '\n' | grep -qx nftset
}

error=
if nftset; then
	:
else
	if command -v apk >/dev/null; then
		cache=/tmp/nikkiplus-apk-cache
		rm -rf "$cache"
		mkdir -p "$cache"
		# 单个源不可达不该拦下替换，成败由下载步骤决定。
		apk update >/dev/null 2>&1 || true
		if [ -f /etc/config/dhcp ]; then
			cp /etc/config/dhcp /tmp/dhcp.bak-nikkiplus
		fi
		if apk add --cache-dir "$cache" --cache-predownload dnsmasq-full >/dev/null 2>&1; then
			nftset || error=install
		else
			rm -f /tmp/dhcp.bak-nikkiplus
			# apk 下载失败时事务中止、系统未被改动；二进制缺失说明提交阶段失败，属 install。
			if [ -x /usr/sbin/dnsmasq ] && ! nftset; then
				error=download
			else
				error=install
			fi
		fi
		rm -rf "$cache"
	else
		dir=/tmp/nikkiplus-dns-upgrade
		rm -rf "$dir"
		mkdir -p "$dir"
		opkg update >/dev/null 2>&1 || true
		if (cd "$dir" && opkg install --download-only dnsmasq-full >/dev/null 2>&1); then
			if [ -f /etc/config/dhcp ]; then
				cp /etc/config/dhcp /tmp/dhcp.bak-nikkiplus
			fi
			# dnsmasq 可能未安装（安装脚本路径），删除失败不拦下安装。
			opkg remove dnsmasq >/dev/null 2>&1 || true
			if ! opkg install "$dir"/*.ipk >/dev/null 2>&1 || ! nftset; then
				error=install
			fi
		else
			error=download
		fi
		rm -rf "$dir"
	fi

	# 只在发生过替换时重启；重复执行（已支持 nftset）不影响 dnsmasq。
	[ -n "$error" ] || /etc/init.d/dnsmasq restart >/dev/null 2>&1 || error=restart
fi

[ -z "$error" ] || error="\"$error\""

printf '{"id":"%s","time":%s,"error":%s}\n' "$id" "$(date +%s)" "${error:-null}" > "${result}.tmp"
mv -f "${result}.tmp" "$result"
)

# Nikki+ 一行安装脚本的主体（spec 第 3 节）：环境检查、写入软件源、安装与升级。
# 本文件只定义常量与函数，不能单独运行；scripts/gen-install.sh 组装最终产物：
# 生成头部（BUILD_TS 与 set -eu）、内嵌 dns_upgrade、追加 main 调用。

FEED='https://feed.openwrt.marimario.me'

MIN_LUCI_NIKKI=1.25.0
MIN_NIKKI=2025.12.21

die() {
	echo "安装已停止：$1" >&2
	exit 1
}

# 点分版本按字段比较数字，忽略 -rN 后缀；$1 >= $2 时返回 0。
ver_ge() {
	a=${1%%-*}
	b=${2%%-*}
	while :; do
		xa=${a%%.*}
		xb=${b%%.*}
		if [ "$xa" -ne "$xb" ]; then
			[ "$xa" -gt "$xb" ]
			return
		fi
		case $a in
			*.*) a=${a#*.} ;;
			*) a=0 ;;
		esac
		case $b in
			*.*) b=${b#*.} ;;
			*) b=0 ;;
		esac
		if [ "$a" = 0 ] && [ "$b" = 0 ]; then
			return 0
		fi
	done
}

# 与 dns-upgrade、detect.uc 相同的判断：Compile time options 行中的完整单词 nftset。
nftset_supported() {
	dnsmasq --version 2>/dev/null | sed -n 's/^Compile time options: //p' | tr ' ' '\n' | grep -qx nftset
}

# 从包数据库读已安装版本（与 tests/image.sh 相同的读法）。
installed_version() {
	if [ "$pkg" = apk ]; then
		sed -n "/^P:$1\$/,/^\$/s/^V://p" /lib/apk/db/installed
	else
		sed -n "/^Package: $1\$/,/^\$/s/^Version: //p" /usr/lib/opkg/status
	fi
}

# uclient-fetch 下载到目标文件，成功才替换，失败时清理残留。
fetch() {
	if uclient-fetch -q -O "$2.tmp" "$1"; then
		mv -f "$2.tmp" "$2"
	else
		rm -f "$2.tmp"
		return 1
	fi
}

main() {
	# 第 2 步：环境检查。
	[ -x /sbin/fw4 ] || die '需要 fw4 防火墙，不支持当前系统。'
	if command -v apk >/dev/null 2>&1; then
		pkg=apk
	elif command -v opkg >/dev/null 2>&1; then
		pkg=opkg
	else
		die '找不到 opkg 或 apk，不支持当前系统。'
	fi
	release=$(sed -n "s/^DISTRIB_RELEASE='\([^']*\)'/\1/p" /etc/openwrt_release)
	case $release in
		24.10*|25.12*) ;;
		*) die "不支持当前系统版本 ${release:-（未知）}，需要 24.10 或 25.12。" ;;
	esac
	if [ "$(date +%s)" -lt "$BUILD_TS" ]; then
		die "系统时间不正确（当前为 $(date)），HTTPS 下载与签名校验会失败。请在 LuCI → 系统 → 系统 中与浏览器同步时间后重试"
	fi
	nikki=$(installed_version nikki)
	if [ -z "$nikki" ] || ! ver_ge "$nikki" "$MIN_NIKKI"; then
		die "请在代理正常时先安装或升级 nikki（需要不低于 $MIN_NIKKI，当前为 ${nikki:-未安装}）。"
	fi
	luci=$(installed_version luci-app-nikki)
	if [ -z "$luci" ] || ! ver_ge "$luci" "$MIN_LUCI_NIKKI"; then
		die "请在代理正常时先安装或升级 nikki（luci-app-nikki 需要不低于 $MIN_LUCI_NIKKI，当前为 ${luci:-未安装}）。"
	fi

	# 第 3 步：以固定内容写入 feed 文件与公钥，名称不含 nikki（nikki feed.sh 会删除含 nikki 的行）。
	echo '正在写入 Nikki+ 软件源…'
	if [ "$pkg" = apk ]; then
		printf '%s\n' "$FEED/25.12/all/packages.adb" > /etc/apk/repositories.d/marimario.list ||
			die '写入软件源配置失败。'
		fetch "$FEED/keys/marimario.pem" /etc/apk/keys/marimario.pem ||
			die '下载公钥失败，请检查网络后重试。'
	else
		printf 'src/gz marimario %s/24.10/all\n' "$FEED" > /etc/opkg/marimario.conf ||
			die '写入软件源配置失败。'
		fetch "$FEED/keys/marimario.pub" /tmp/marimario.pub ||
			die '下载公钥失败，请检查网络后重试。'
		opkg-key add /tmp/marimario.pub || die '导入公钥失败。'
		rm -f /tmp/marimario.pub
	fi

	# 第 4 步：更新索引（不看整体退出码，用户已配的其它源不可达时也会失败），
	# 检查所需的包是否可用，再按索引大小检查剩余空间。
	echo '正在更新软件源…'
	if [ "$pkg" = apk ]; then
		apk update >/dev/null 2>&1 || true
	else
		opkg update >/dev/null 2>&1 || true
	fi
	pkgs='luci-app-nikkiplus luci-i18n-nikkiplus-zh-cn'
	if ! nftset_supported; then
		pkgs="$pkgs dnsmasq-full"
	fi
	inst_bytes=0
	dl_bytes=0
	for p in $pkgs; do
		if [ "$pkg" = apk ]; then
			info=$(apk query --available --fields installed-size,file-size "$p")
			isize=$(printf '%s\n' "$info" | sed -n 's/^Installed-Size: //p')
			fsize=$(printf '%s\n' "$info" | sed -n 's/^File-Size: //p')
			if [ -z "$isize" ] || [ -z "$fsize" ]; then
				die "软件源中没有 $p，请检查网络后重试。"
			fi
			inst_bytes=$((inst_bytes + isize))
			dl_bytes=$((dl_bytes + fsize))
		else
			# opkg info 对未安装与已安装的包都输出索引记录；没有 Size 说明源中不可用。
			size=$(opkg info "$p" 2>/dev/null | sed -n 's/^Size: //p')
			if [ -z "$size" ]; then
				die "软件源中没有 $p，请检查网络后重试。"
			fi
			# opkg 索引只有下载大小，按 3 倍估算安装后大小（spec 第 3 节第 4 步）。
			inst_bytes=$((inst_bytes + size * 3))
			dl_bytes=$((dl_bytes + size))
		fi
	done
	root=/
	if [ -d /overlay ]; then
		root=/overlay
	fi
	avail=$(df -k "$root" | awk 'NR==2 {print $4}')
	need=$((inst_bytes * 2 / 1024 + 1024))
	if [ "$avail" -lt "$need" ]; then
		die "设备闪存太小：安装约需 ${need} KiB（含运行副本与余量），剩余 ${avail} KiB。"
	fi
	avail=$(df -k /tmp | awk 'NR==2 {print $4}')
	need=$((dl_bytes / 1024 + 1024))
	if [ "$avail" -lt "$need" ]; then
		die "内存空间不足：下载约需 ${need} KiB，/tmp 剩余 ${avail} KiB，请释放内存后重试。"
	fi

	# 第 5 步：dnsmasq 不支持 nftset 时替换为 dnsmasq-full（dns_upgrade 由生成步骤内嵌）。
	if ! nftset_supported; then
		echo '正在替换 dnsmasq-full…'
		result=/tmp/nikkiplus-install-dns.json
		rm -f "$result"
		dns_upgrade install "$result" || true
		[ -f "$result" ] || die '替换 dnsmasq-full 失败，未得到结果，请重试。'
		error=$(sed -n 's/^{"id":"[^"]*","time":[0-9]*,"error":\(null\|"[a-z]*"\)}$/\1/p' "$result")
		[ -n "$error" ] || die '替换 dnsmasq-full 失败，结果无法识别，请重试。'
		case $error in
			null) ;;
			'"download"') die '下载 dnsmasq-full 失败，请检查网络后重试。' ;;
			'"install"') die '替换 dnsmasq-full 失败；/etc/config/dhcp 的备份在 /tmp/dhcp.bak-nikkiplus。' ;;
			'"restart"') echo '警告：dnsmasq-full 已替换，但重启 dnsmasq 失败；请执行 /etc/init.d/dnsmasq restart 或重启设备。' >&2 ;;
			*) die "替换 dnsmasq-full 返回未知结果（$error），请重试。" ;;
		esac
	fi

	# 第 6 步：显式安装或升级 Nikki+ 的两个包，不安装、不升级 nikki 相关包与 mihomo。
	echo '正在安装 Nikki+…'
	if [ "$pkg" = apk ]; then
		v1=$(apk search -x luci-app-nikkiplus)
		v2=$(apk search -x luci-i18n-nikkiplus-zh-cn)
		if [ -z "$v1" ] || [ -z "$v2" ]; then
			die '软件源中没有 Nikki+ 的包，请重试。'
		fi
		# 两次 apk add：先带版本约束装到源中的最新版本，再清除 world 中的版本约束。
		# 不用 apk add -u（连带升级依赖，nikki 源有新版时会升级 nikki）与 apk upgrade
		# （任一源不可达或索引过期时以 99 退出），spec 第 3 节第 6 步。
		apk add "luci-app-nikkiplus>=${v1#luci-app-nikkiplus-}" \
			"luci-i18n-nikkiplus-zh-cn>=${v2#luci-i18n-nikkiplus-zh-cn-}" ||
			die '安装 Nikki+ 失败。'
		apk add luci-app-nikkiplus luci-i18n-nikkiplus-zh-cn || die '安装 Nikki+ 失败。'
	elif [ -n "$(installed_version luci-app-nikkiplus)" ]; then
		opkg upgrade luci-app-nikkiplus luci-i18n-nikkiplus-zh-cn || die '升级 Nikki+ 失败。'
	else
		opkg install luci-app-nikkiplus luci-i18n-nikkiplus-zh-cn || die '安装 Nikki+ 失败。'
	fi

	# 第 7 步：提示入口。
	echo
	echo '安装完成。请在浏览器打开 LuCI → 服务 → Nikki+ 完成首次设置。'
}

main "$@" </dev/null
