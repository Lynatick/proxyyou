#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${1:?Specify Hiddify Core v4.1.0 with its pinned submodules}"
source_dir="$(cd "$source_dir" && pwd)"
cc="${CC:-x86_64-w64-mingw32-gcc}"
command -v "$cc" >/dev/null || { echo "Install an x64 MinGW compiler or set CC." >&2; exit 1; }
[[ "$(go version)" == *"go1.25.6 "* ]] || { echo "Go 1.25.6 is required." >&2; exit 1; }
monitoring="$source_dir/hiddify-sing-box/common/monitoring/outbound_monitoring.go"
if ! grep -q 'defaultWorkerCount    = 20' "$monitoring"; then
  patch -d "$source_dir" -p1 < "$root/native-patches/youtube-monitoring.patch"
fi
if grep -q "InterruptExistConnections: true," "$source_dir/v2/config/builder.go"; then
  patch -d "$source_dir" -p1 < "$root/native-patches/connection-continuity.patch"
fi
bash "$root/scripts/apply-native-sources.sh" "$source_dir"
out="$root/hiddify-core/windows-x64"
mkdir -p "$out"
tags=with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,with_conntrack,with_purego
export GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC="$cc"
go -C "$source_dir" build -trimpath -ldflags='-w -s -checklinkname=0 -buildid=' \
  -tags="$tags" -buildmode=c-shared -o "$out/hiddify-core.dll" ./platform/desktop
CGO_LDFLAGS="$out/hiddify-core.dll" go -C "$source_dir" build -trimpath \
  -ldflags='-w -s -checklinkname=0 -buildid=' -tags="$tags" -o "$out/HiddifyCli.exe" ./cmd/bydll
# Use precisely the Cronet DLL pinned by this core, rather than extracting
# whichever version a standalone tool currently resolves.
cronet="$(CGO_ENABLED=0 go -C "$source_dir" list -m -f '{{.Dir}}' github.com/sagernet/cronet-go/lib/windows_amd64)"
cp "$cronet/libcronet.dll" "$out/libcronet.dll"
echo "Windows x64 native core saved to $out"

python3 "$root/scripts/native-core-stamp.py" write "$out/hiddify-core.dll"
