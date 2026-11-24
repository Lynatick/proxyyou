# Android TV build (Xiaomi Mi Stick 4K, armeabi-v7a)

This tree is [Hiddify v5.9.15](https://github.com/hiddify/hiddify-app/releases/tag/v5.9.15)
built for Android TV only. The package is still `app.hiddify.com` and the app is still called
Hiddify; nothing is rebranded.

## What is changed from upstream v5.9.15

- **The "How many to keep" filter defaults to "Working only".**
  `ProfileParser.keepTopDefault` is `-2`, hiddify-core's `config.KeepTopAnswering`: a profile with
  no user choice and no `keep-top` subscription header keeps only the proxies that answered their
  first ping and parks the rest. The fastest-N modes and "All" remain one tap away at the end of
  the proxy list, and a subscription's `keep-top` header still wins over the default.
- The large-profile card has a matching sentence (`bigBodyWorking` in English and Russian) instead
  of "Keep only the -2 fastest".
- The Android build packages **only `armeabi-v7a`**: no arm64, no x86_64, no universal APK. The
  Flutter engine, the Hiddify core and every plugin are filtered to the 32-bit ARM ABI the Mi
  Stick 4K userspace runs.
- Android TV launcher support (`LEANBACK_LAUNCHER`, banner, no touchscreen requirement) is already
  in the upstream manifest and is left as is.

## Build

Requirements: Flutter 3.38.5 (Dart 3.10.4), JDK 17, Android SDK 36, build-tools 36.0.0,
NDK 28.2.13676358.

```bash
export JAVA_HOME=/path/to/jdk-17
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=/path/to/flutter-3.38.5/bin:$PATH

flutter pub get
dart run build_runner build --delete-conflicting-outputs

# hiddify-core v5.9.15 (the AAR contains all ABIs; Gradle keeps only armeabi-v7a)
mkdir -p android/app/libs
curl -fL https://github.com/hiddify/hiddify-core/releases/download/v5.9.15/hiddify-lib-android.tar.gz \
  | tar xz -C android/app/libs

# local release key; without key.properties the build falls back to the debug key
cat > android/key.properties <<EOF
storePassword=...
keyPassword=...
keyAlias=hiddify
storeFile=../keystore/hiddify-tv.jks
EOF

flutter build apk --release -t lib/main_prod.dart --target-platform android-arm
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

## Install on the TV

```bash
adb connect <tv-ip>:5555
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

The release publishes two APKs of the same build, differing only in the signing key:

- `Hiddify-Android-TV-armv7-5.9.15.apk`, 65.5 MB — signed with a local `CN=Hiddify TV` key.
  For a clean install. The official Hiddify app, or a debug-signed build, has to be uninstalled
  first: its signature differs.
  sha256: `cd2de5b3510dd21b4f7432dff7a4f911cae263f937b40e5051a9980f1ff49d44`
- `Hiddify-Android-TV-armv7-5.9.15-debugkey.apk`, 65.6 MB — signed with the Android debug key,
  the same one the Mi Stick's previous Hiddify 5.9.9 was signed with. It installs over that build
  without uninstalling and keeps the profiles.
  sha256: `68adcd390bb569caf0a762e256814b4dbae0e58a9cead86dc096c1035a82732b`

Verified on a Xiaomi Mi Stick 4K (Android 14, `armeabi-v7a`): the debug-key APK installed over
5.9.9, the app started, the existing profiles were still there, and logcat had no crash.

## Upstream notes

Everything else is upstream v5.9.15. The core is hiddify-core v5.9.15, the profile format,
protocols, routing and UI are unchanged. See `README.md` for the upstream description.
