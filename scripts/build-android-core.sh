#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$(cd "${1:?Specify Hiddify Core v4.1.0 with pinned submodules}" && pwd)"
[[ "$(go version)" == *"go1.25.6 "* ]] || { echo 'Go 1.25.6 is required' >&2; exit 1; }
: "${JAVA_HOME:?Set JAVA_HOME to Java 25}"
export PATH="$JAVA_HOME/bin:$PATH"
[[ "$(java -version 2>&1)" == *'version "25.'* ]] || { echo 'Java 25 is required' >&2; exit 1; }
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to NDK 28.2.13676358}"
if ! grep -q 'defaultWorkerCount    = 20' "$source_dir/hiddify-sing-box/common/monitoring/outbound_monitoring.go"; then
  patch -d "$source_dir" -p1 < "$root/native-patches/youtube-monitoring.patch"
fi
if grep -q 'InterruptExistConnections: true,' "$source_dir/v2/config/builder.go"; then
  patch -d "$source_dir" -p1 < "$root/native-patches/connection-continuity.patch"
fi
bash "$root/scripts/apply-native-sources.sh" "$source_dir"
mkdir -p "$root/android/app/libs"
export CGO_LDFLAGS='-O2 -g -s -w -Wl,-z,max-page-size=16384'
cd "$source_dir"
gomobile bind -androidapi=24 -javapkg=com.hiddify.core -libname=hiddify-core \
  -tags=with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,with_conntrack \
  -trimpath -ldflags='-w -s -checklinkname=0 -buildid=' \
  -target=android/arm,android/arm64,android/amd64 \
  -o "$root/android/app/libs/hiddify-core.aar" \
  github.com/sagernet/sing-box/experimental/libbox ./platform/mobile
python3 "$root/scripts/native-core-stamp.py" write "$root/android/app/libs/hiddify-core.aar"
