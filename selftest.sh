#!/bin/sh
# publish.sh 的自测：在临时克隆（origin 指向本地 bare 仓库，不会触碰真实远端）里
# 走完 生成密钥 → 发布 → 篡改拒绝 → withdraw → withdraw 最后一个包拒绝 的流程。
# 依赖本地已拉取 openwrt/sdk:x86-64-v24.10.8 与 v25.12.6 两个镜像。
set -eu
cd "$(dirname "$0")"
src=$(pwd)

work=$(mktemp -d)
cleanup() { command rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM

git clone -q "$src" "$work/repo"
# 克隆里是已提交版本；覆盖为当前工作区的脚本，测试未提交的修改。
cp "$src/publish.sh" "$src/selftest.sh" "$work/repo/"
git init -q --bare "$work/bare.git"
cd "$work/repo"
git remote set-url origin "$work/bare.git"
git config user.name selftest
git config user.email selftest@example.invalid
git push -q -u origin main

echo "== gen keys"
./publish.sh --gen-keys >/dev/null
[ -f keys/marimario.sec ] && [ -f keys/marimario.sec.pem ]

echo "== craft fixtures"
# .ipk 按 SDK ipkg-build 的真实格式构造：gzip tar，成员带 ./ 前缀。
docker run --rm --platform linux/amd64 -v "$work:/t" -w /t openwrt/sdk:x86-64-v24.10.8 sh -euc '
	mkdir -p fx
	for name in a b; do
		printf "Package: fake-%s\nVersion: 1.0-r1\nDepends: libc\nArchitecture: all\nDescription: selftest %s\n" "$name" "$name" > control
		mkdir -p data/usr/bin; printf "#!/bin/sh\n" > "data/usr/bin/fake-$name"
		tar -czf control.tar.gz ./control
		tar -czf data.tar.gz -C data ./usr
		echo 2.0 > debian-binary
		tar -czf "fx/fake-${name}_1.0-r1_all.ipk" ./debian-binary ./data.tar.gz ./control.tar.gz
		command rm -f control control.tar.gz data.tar.gz debian-binary
		command rm -rf data
	done
'
docker run --rm --platform linux/amd64 -v "$work:/t" -w /t openwrt/sdk:x86-64-v25.12.6 sh -euc '
	A=/builder/staging_dir/host/bin/apk
	mkdir -p pkg/usr/bin fx
	printf "#!/bin/sh\n" > pkg/usr/bin/fake-c
	$A mkpkg -I name:fake-c -I version:1.0-r1 -I arch:noarch -I description:selftest \
		-F pkg -o fx/fake-c-1.0-r1.apk 2>/dev/null
'

echo "== publish 24.10"
./publish.sh 24.10 "$work/fx/fake-a_1.0-r1_all.ipk" "$work/fx/fake-b_1.0-r1_all.ipk" >/dev/null
grep -q '^Package: fake-a$' public/24.10/all/Packages
grep -q '^Package: fake-b$' public/24.10/all/Packages
grep -q '^SHA256sum: ' public/24.10/all/Packages
[ "$(git -C "$work/bare.git" tag | grep -c '^release/')" -ge 1 ]

echo "== tamper via publish refused"
printf 'x' >> "$work/fx/fake-a_1.0-r1_all.ipk"
if ./publish.sh 24.10 "$work/fx/fake-a_1.0-r1_all.ipk" >"$work/tamper.log" 2>&1; then
	echo "UNEXPECTED: tampered publish accepted" >&2; exit 1
fi
grep -q 'different content' "$work/tamper.log"
[ -z "$(git status --porcelain public/)" ] || { git status --porcelain public/; echo "UNEXPECTED: leftover changes" >&2; exit 1; }

echo "== direct modification of published package refused"
docker run --rm --platform linux/amd64 -v "$work:/t" -w /t openwrt/sdk:x86-64-v24.10.8 sh -euc '
	printf "Package: fake-c\nVersion: 1.0-r1\nDepends: libc\nArchitecture: all\nDescription: selftest c\n" > control
	mkdir -p data/usr/bin; printf "#!/bin/sh\n" > data/usr/bin/fake-c
	tar -czf control.tar.gz ./control
	tar -czf data.tar.gz -C data ./usr
	echo 2.0 > debian-binary
	tar -czf fx/fake-c_1.0-r1_all.ipk ./debian-binary ./data.tar.gz ./control.tar.gz
'
printf 'x' >> public/24.10/all/fake-b_1.0-r1_all.ipk
if ./publish.sh 24.10 "$work/fx/fake-c_1.0-r1_all.ipk" >"$work/direct.log" 2>&1; then
	echo "UNEXPECTED: publish accepted despite modified published package" >&2; exit 1
fi
grep -q 'must not change' "$work/direct.log"
[ -z "$(git status --porcelain public/)" ] || { git status --porcelain public/; echo "UNEXPECTED: leftover changes" >&2; exit 1; }
[ ! -e public/24.10/all/fake-c_1.0-r1_all.ipk ]

echo "== publish third package"
./publish.sh 24.10 "$work/fx/fake-c_1.0-r1_all.ipk" >/dev/null
grep -q '^Package: fake-c$' public/24.10/all/Packages

echo "== withdraw"
./publish.sh --withdraw 24.10 fake-a_1.0-r1_all.ipk >/dev/null
[ ! -e public/24.10/all/fake-a_1.0-r1_all.ipk ]
if grep -q '^Package: fake-a$' public/24.10/all/Packages; then
	echo "UNEXPECTED: withdrawn package still indexed" >&2; exit 1
fi
grep -q '^Package: fake-b$' public/24.10/all/Packages

echo "== withdraw last refused"
./publish.sh --withdraw 24.10 fake-b_1.0-r1_all.ipk >/dev/null
if ./publish.sh --withdraw 24.10 fake-c_1.0-r1_all.ipk >"$work/last.log" 2>&1; then
	echo "UNEXPECTED: withdrawing last package accepted" >&2; exit 1
fi
grep -q 'last package' "$work/last.log"
[ -f public/24.10/all/fake-c_1.0-r1_all.ipk ]

echo "== publish 25.12"
./publish.sh 25.12 "$work/fx/fake-c-1.0-r1.apk" >/dev/null
[ -f public/25.12/all/packages.adb ]

echo "== verify all"
./publish.sh --verify >/dev/null

echo "SELFTEST_OK"
