#!/bin/bash
mkdir package/new
function merge_package() {
	# 参数1是分支名,参数2是库地址,参数3是所有文件下载到指定路径。
	# 同一个仓库下载多个文件夹直接在后面跟文件名或路径，空格分开。
if [[ $# -lt 3 ]]; then
		echo "Syntax error: [$#] [$*]" >&2
		return 1
	fi
	trap 'rm -rf "$tmpdir"' EXIT
	branch="$1" curl="$2" target_dir="$3" && shift 3
	rootdir="$PWD"
	localdir="$target_dir"
	[ -d "$localdir" ] || mkdir -p "$localdir"
	tmpdir="$(mktemp -d)" || exit 1
        echo "开始下载：$(echo $curl | awk -F '/' '{print $(NF)}')"
	git clone -b "$branch" --depth 1 --filter=blob:none --sparse "$curl" "$tmpdir"
	cd "$tmpdir"
	git sparse-checkout init --cone
	git sparse-checkout set "$@"
	# 使用循环逐个移动文件夹
	for folder in "$@"; do
		mv -f "$folder" "$rootdir/$localdir"
	done
	cd "$rootdir"
}

#修改feeds.conf.default
sed -i 's/src-git/#src-git/g' feeds.conf.default
#添加为github的库
sed -i '$asrc-git packages https://github.com/openwrt/packages.git;openwrt-24.10' feeds.conf.default
sed -i '$asrc-git luci https://github.com/openwrt/luci.git;openwrt-24.10' feeds.conf.default
sed -i '$asrc-git routing https://github.com/openwrt/routing.git;openwrt-24.10' feeds.conf.default
sed -i '$asrc-git telephony https://github.com/openwrt/telephony.git;openwrt-24.10' feeds.conf.default

# 更新 Feeds
#./scripts/feeds update -a
#./scripts/feeds install -a

#
merge_package main https://github.com/ilxp/gargoyle-qos-openwrt.git  package/new qos-gargoyle
merge_package main https://github.com/ilxp/gargoyle-qos-openwrt.git  package/new luci-app-qos-gargoyle
