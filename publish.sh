#!/bin/sh
# 发布脚本（ADR 0004、nikkiplus spec 第 3 节、ticket 32/40）：
#   - 把包加入 public/<release>/all/，以该目录全部包重建并重签索引（feed 跨项目共享）。
#   - 拒绝修改或删除已发布的 .ipk/.apk，唯一例外 --withdraw（删除后重建并重签索引）。
#   - 签名在维护者本机的 SDK 容器内进行（usign 与 host apk），verify 通过才提交。
#   - 提交、打 release/<时间> tag 并 push；push 即经 Cloudflare Pages 部署上线。
# 密钥放在 keys/（gitignore），不进仓库；公钥发布到 public/keys/ 由 cp 完成。
# SDK 容器以 root 写 bind mount：macOS Docker Desktop 把属主映射成本机用户；
# Linux 维护机上产物会属 root，需要时可 chown。
set -eu
cd "$(dirname "$0")"

KEYS_DIR=${KEYS_DIR:-keys}
SDK_24=${SDK_24:-openwrt/sdk:x86-64-v24.10.8}
SDK_25=${SDK_25:-openwrt/sdk:x86-64-v25.12.6}

usage() {
	cat >&2 <<EOF
usage:
  publish.sh --gen-keys                  生成 $KEYS_DIR/ 密钥对（仅一次，保密）
  publish.sh <release> <pkg>...          加入包，重建重签索引，提交并 push
  publish.sh --withdraw <release> <file>  删除已发布的包，重建重签索引
  publish.sh --verify                    用 $KEYS_DIR/ 公钥校验现有索引
  publish.sh --fingerprints              打印公钥指纹（写入 README）
release 为 24.10（.ipk）或 25.12（.apk）。
EOF
	exit 2
}

die() { echo "publish: $*" >&2; exit 1; }

case $KEYS_DIR in
/*|*..*) die "KEYS_DIR must be a relative path inside the repo" ;;
esac

need_keys() {
	[ -f "$KEYS_DIR/marimario.sec" ] && [ -f "$KEYS_DIR/marimario.pub" ] \
		&& [ -f "$KEYS_DIR/marimario.sec.pem" ] && [ -f "$KEYS_DIR/marimario.pem" ] \
		|| die "missing keys in $KEYS_DIR, run: publish.sh --gen-keys"
}

# 恢复 public/ 下的包文件到 HEAD 状态（删除未跟踪的包、恢复被改动的包），
# 拒绝发布时调用，避免留下卡住后续发布的残留改动；其它文件（install.sh、
# faq.html、公钥）可能是维护者未提交的改动，不碰。
restore_public() {
	git ls-files --others --exclude-standard public | grep -E '\.(ipk|apk)$' | xargs rm -f 2>/dev/null || true
	git diff HEAD --name-only -- public | grep -E '\.(ipk|apk)$' | while IFS= read -r f; do
		git reset -q HEAD -- "$f" 2>/dev/null || true
		git checkout -q HEAD -- "$f" 2>/dev/null || true
	done
	return 0
}

# 对比上一个 release/* tag：已发布的 .ipk/.apk 只允许新增（A）；withdraw 允许删除指定文件。
# 其余状态（M/D/R/C）一律拒绝。
check_immutable() {
	allow=$1
	last=$(git describe --tags --abbrev=0 --match 'release/*' 2>/dev/null) || {
		echo "publish: no previous release tag, immutability check skipped"
		return 0
	}
	violations=$(git diff --name-status "$last" -- public | awk -F'\t' -v allow="$allow" '
		$1 ~ /^A/ { next }
		$1 == "D" && $2 == allow { next }
		$2 ~ /\.(ipk|apk)$/ { printf "  %s %s\n", $1, $2 }
	')
	[ -z "$violations" ] || { restore_public; die "published packages must not change:
$violations
(use --withdraw to remove a package)"; }
}

rebuild_index() {
	release=$1
	case $release in
	24.10)
		dir=public/24.10/all
		ls "$dir"/*.ipk >/dev/null 2>&1 || die "no .ipk in $dir"
		docker run --rm --platform linux/amd64 \
			-v "$PWD:/repo" -v "$PWD/$KEYS_DIR:/keys:ro" -w /repo "$SDK_24" sh -euc '
			dir=$1
			cd "$dir"
			: > Packages.new
			for f in *.ipk; do
				# SDK 的 ipkg-build 产出的 .ipk 是 gzip tar（成员带 ./ 前缀），
				# control.tar.gz 里除 control 外还有 conffiles/postinst 等，必须只取 control。
				tar -xzOf "$f" ./control.tar.gz | tar -xzO ./control \
					| awk "BEGIN{RS=\"\";ORS=\"\n\n\"} {print}" >> Packages.new
				printf "Filename: %s\nSize: %s\nSHA256sum: %s\nMD5Sum: %s\n" \
					"$f" "$(wc -c < "$f" | tr -d " ")" \
					"$(sha256sum "$f" | cut -d" " -f1)" \
					"$(md5sum "$f" | cut -d" " -f1)" >> Packages.new
				echo >> Packages.new
			done
			mv Packages.new Packages
			gzip -c Packages > Packages.gz
			/builder/staging_dir/host/bin/usign -S -s /keys/marimario.sec -m Packages -x Packages.sig
			/builder/staging_dir/host/bin/usign -V -p /keys/marimario.pub -m Packages -x Packages.sig
		' sh "$dir"
		echo "publish: 24.10 index rebuilt, signed, verified"
		;;
	25.12)
		dir=public/25.12/all
		ls "$dir"/*.apk >/dev/null 2>&1 || die "no .apk in $dir"
		docker run --rm --platform linux/amd64 \
			-v "$PWD:/repo" -v "$PWD/$KEYS_DIR:/keys:ro" -w /repo "$SDK_25" sh -euc '
			dir=$1
			A=/builder/staging_dir/host/bin/apk
			set -- "$dir"/*.apk
			$A mkndx --allow-untrusted --output "$dir/packages.adb" --sign-key /keys/marimario.sec.pem "$@"
			$A --keys-dir /keys verify "$dir/packages.adb"
		' sh "$dir"
		echo "publish: 25.12 index rebuilt, signed, verified"
		;;
	*) die "unsupported release: $release" ;;
	esac
}

gen_keys() {
	[ ! -e "$KEYS_DIR/marimario.sec" ] && [ ! -e "$KEYS_DIR/marimario.sec.pem" ] \
		|| die "keys already exist in $KEYS_DIR"
	mkdir -p "$KEYS_DIR"
	docker run --rm --platform linux/amd64 \
		-v "$PWD:/repo" -w "/repo/$KEYS_DIR" "$SDK_24" \
		/builder/staging_dir/host/bin/usign -G -s marimario.sec -p marimario.pub -c marimario-feed
	docker run --rm --platform linux/amd64 \
		-v "$PWD:/repo" -w "/repo/$KEYS_DIR" "$SDK_25" sh -euc '
		openssl genrsa -out marimario.sec.pem 2048 2>/dev/null
		openssl rsa -in marimario.sec.pem -pubout -out marimario.pem 2>/dev/null
	'
	echo "publish: keys generated in $KEYS_DIR/"
	print_fingerprints
}

print_fingerprints() {
	need_keys
	docker run --rm --platform linux/amd64 \
		-v "$PWD:/repo" -v "$PWD/$KEYS_DIR:/keys:ro" "$SDK_24" \
		/builder/staging_dir/host/bin/usign -F -p /keys/marimario.pub \
		| sed 's/^/usign key id: /'
	docker run --rm --platform linux/amd64 \
		-v "$PWD:/repo" -v "$PWD/$KEYS_DIR:/keys:ro" "$SDK_25" sh -c '
		openssl pkey -pubin -in /keys/marimario.pem -outform DER | sha256sum | cut -d" " -f1
	' | sed 's/^/apk pubkey sha256 (DER): /'
}

verify_all() {
	need_keys
	# 公钥必须与 keys/ 一致，否则本机 verify 通过、设备校验失败。
	for k in marimario.pub marimario.pem; do
		if [ -f "public/keys/$k" ]; then
			cmp -s "public/keys/$k" "$KEYS_DIR/$k" || die "public/keys/$k differs from $KEYS_DIR/$k"
		fi
	done
	for release in 24.10 25.12; do
		dir=public/$release/all
		[ -d "$dir" ] || continue
		case $release in
		24.10)
			[ -f "$dir/Packages" ] || die "$dir/Packages missing"
			docker run --rm --platform linux/amd64 \
				-v "$PWD:/repo" -v "$PWD/$KEYS_DIR:/keys:ro" -w /repo "$SDK_24" \
				/builder/staging_dir/host/bin/usign -V -p /keys/marimario.pub \
				-m "$dir/Packages" -x "$dir/Packages.sig" \
				&& echo "publish: $release Packages.sig OK"
			;;
		25.12)
			[ -f "$dir/packages.adb" ] || die "$dir/packages.adb missing"
			docker run --rm --platform linux/amd64 \
				-v "$PWD:/repo" -v "$PWD/$KEYS_DIR:/keys:ro" -w /repo "$SDK_25" sh -euc '
				/builder/staging_dir/host/bin/apk --keys-dir /keys verify '"$dir"'/packages.adb
			' && echo "publish: $release packages.adb OK"
			;;
		esac
	done
}

commit_and_push() {
	msg=$1
	git add public
	if git diff --cached --quiet; then
		echo "publish: nothing to commit (no changes)"
		return 0
	fi
	git commit -q -m "$msg"
	tag=release/$(date -u +%Y%m%d-%H%M%S)
	git tag -a "$tag" -m "$tag"
	git push origin main --follow-tags
	echo "publish: committed and pushed $tag"
}

case ${1:-} in
--gen-keys) gen_keys ;;
--verify) verify_all ;;
--fingerprints) print_fingerprints ;;
--withdraw)
	[ $# -eq 3 ] || usage
	release=$2 file=$3
	dir=public/$release/all
	case $release in 24.10|25.12) ;; *) die "unsupported release: $release" ;; esac
	[ -f "$dir/$file" ] || die "no such published package: $dir/$file"
	n=0
	for f in "$dir"/*.ipk "$dir"/*.apk; do [ -e "$f" ] && n=$((n + 1)); done
	[ "$n" -gt 1 ] || { restore_public; die "refusing to withdraw the last package of $release"; }
	[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "not on main"
	git rm -q "$dir/$file"
	check_immutable "$dir/$file"
	rebuild_index "$release"
	commit_and_push "withdraw: $release $file"
	;;
"") usage ;;
*)
	release=$1; shift
	[ $# -ge 1 ] || usage
	case $release in
	24.10) ext=ipk ;;
	25.12) ext=apk ;;
	*) die "unsupported release: $release" ;;
	esac
	need_keys
	[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "not on main"
	for pkg in "$@"; do
		[ -f "$pkg" ] || die "no such file: $pkg"
		case $pkg in
		*.$ext) ;;
		*) die "expected .$ext for $release: $pkg" ;;
		esac
		name=${pkg##*/}
		if [ -e "public/$release/all/$name" ]; then
			cmp -s "$pkg" "public/$release/all/$name" \
				|| die "already published with different content: $name"
		fi
	done
	mkdir -p "public/$release/all"
	names=
	for pkg in "$@"; do
		cp "$pkg" "public/$release/all/"
		names="$names ${pkg##*/}"
	done
	check_immutable ""
	rebuild_index "$release"
	commit_and_push "publish: $release$names"
	;;
esac
