#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${1:?Specify Hiddify Core v4.1.0 with its pinned submodules}"
source_dir="$(cd "$source_dir" && pwd)"
[[ "$(go -C "$source_dir" version)" == *"go1.25.6 "* ]] || { echo "Go 1.25.6 is required." >&2; exit 1; }
if ! grep -q 'defaultWorkerCount    = 20' "$source_dir/hiddify-sing-box/common/monitoring/outbound_monitoring.go"; then
  patch -d "$source_dir" -p1 < "$root/native-patches/youtube-monitoring.patch"
fi
if [[ ! -f "$source_dir/v2/config/proxyyou_apps.go" ]]; then
  patch -d "$source_dir" -p1 < "$root/native-patches/macos-app-routing.patch"
fi
if grep -q "InterruptExistConnections: true," "$source_dir/v2/config/builder.go"; then
  patch -d "$source_dir" -p1 < "$root/native-patches/connection-continuity.patch"
fi
bash "$root/scripts/apply-native-sources.sh" "$source_dir"
mkdir -p "$root/hiddify-core/bin"
architecture="${2:-arm64}"
case "$architecture" in
  arm64) clang_arch=arm64 ;;
  amd64) clang_arch=x86_64 ;;
  *) echo "Architecture must be arm64 or amd64" >&2; exit 1 ;;
esac
export GOOS=darwin GOARCH="$architecture" CGO_ENABLED=1
export CGO_CFLAGS="-arch $clang_arch -mmacosx-version-min=14.0 -O2"
export CGO_CXXFLAGS="$CGO_CFLAGS"
export CGO_LDFLAGS="-arch $clang_arch -mmacosx-version-min=14.0 -O2 -lpthread"
tags=with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,with_conntrack,with_dhcp
if [[ "$(go env GOHOSTARCH)" == "$architecture" ]]; then
  go -C "$source_dir" test -ldflags=-checklinkname=0 -tags="$tags" ./v2/config -run TestProxyYou -count=1
else
  go -C "$source_dir" test -c -ldflags=-checklinkname=0 -tags="$tags" ./v2/config -o "$root/hiddify-core/bin/proxyyou-routing-$architecture.test"
fi
go -C "$source_dir" build -trimpath -ldflags='-w -s -checklinkname=0 -buildid=' -tags="$tags" \
  -buildmode=c-shared -o "$root/hiddify-core/bin/hiddify-core.dylib" ./platform/desktop

python3 "$root/scripts/native-core-stamp.py" write "$root/hiddify-core/bin/hiddify-core.dylib"
