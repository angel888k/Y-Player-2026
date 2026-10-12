#!/usr/bin/env bash
# 本地跑「CI 的硬性检查 + 出 Release 产物」一条龙（发布 1.0.2 用）。
#
# 跑的东西与 .github/workflows/build.yml 对齐：
#   ① lint 作业：SwiftFormat --lint、SwiftLint、App 图标校验
#   ② core-tests 作业：7 个包各跑 swift test
#   ③ build 作业：iOS 模拟器构建 + macOS 构建
#   ④ Release 产物：未签名 IPA（archive → Payload → zip）、macOS .zip（Release 构建 → zip）
#   ⑤ 打开产物目录（Finder）
#
# 用法（在仓库根目录）：
#   bash Scripts/release-macos.sh
#
# 前置：Xcode（建议与 CI 同版 26.6）+ python3。xcodegen / swiftlint / swiftformat **都可选**：
#   - 有 xcodegen → 按 project.yml 重新生成工程；没有 → 用现成 YPlayer.xcodeproj，
#     版本号直接改 Apps/*/Info.plist（脚本自动做，不用装 xcodegen）；
#   - 没装 linter → 本地跳过并明说（CI 仍会跑真 lint），退到仓库自带的模式闸门。
# 本脚本只出**未签名产物**、不碰 tag / Release —— 发布走 CI（推 v* tag 触发）。
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd)"
VERSION="1.0.2"
BUILD="2"
OUT="$REPO_ROOT/build/release-$VERSION"
mkdir -p "$OUT"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1"; exit 1; }

# 没有 xcodegen 时：版本号直接写进现成的 Info.plist（有 xcodegen 时由它从 project.yml 生成）。
patch_plist_version() {
  local plist="$1"
  [ -f "$plist" ] || fail "缺 $plist —— 没有 xcodegen 时它必须已存在（以前生成过一次即可）"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD" "$plist"
  echo "— ${plist}: CFBundleShortVersionString=$VERSION CFBundleVersion=$BUILD"
}

step "0/7 工具链"
for tool in xcodebuild python3; do
  command -v "$tool" >/dev/null || fail "缺少 ${tool}"
done
xcodebuild -version
swift --version
HAVE_XCODEGEN=1; command -v xcodegen >/dev/null || HAVE_XCODEGEN=0
if [ "$HAVE_XCODEGEN" = 1 ]; then
  xcodegen --version
else
  echo "⚠︎ 没有 xcodegen —— 用现成 YPlayer.xcodeproj，版本号直接改 Info.plist"
fi
HAVE_SWIFTFORMAT=1; command -v swiftformat >/dev/null || HAVE_SWIFTFORMAT=0
HAVE_SWIFTLINT=1; command -v swiftlint >/dev/null || HAVE_SWIFTLINT=0
if [ "$HAVE_SWIFTFORMAT" = 1 ]; then swiftformat --version; else echo "⚠︎ 没有 swiftformat —— 本地跳过（CI 会跑）"; fi
if [ "$HAVE_SWIFTLINT" = 1 ]; then swiftlint version; else echo "⚠︎ 没有 swiftlint —— 本地跳过（CI 会跑）"; fi

step "1/7 工程与版本号（$VERSION（$BUILD））"
python3 Scripts/fetch_nodejs_mobile.py
if [ "$HAVE_XCODEGEN" = 1 ]; then
  xcodegen generate
else
  [ -d YPlayer.xcodeproj ] || fail "没有 xcodegen、也没有现成 YPlayer.xcodeproj —— 先在别处生成一次再拷过来"
  patch_plist_version Apps/YPlayer-iOS/Info.plist
  patch_plist_version Apps/YPlayer-macOS/Info.plist
fi

step "2/7 Lint（有 swiftlint / swiftformat 就按 CI 全跑；没有则退到仓库自带闸门）"
if [ "$HAVE_SWIFTFORMAT" = 1 ]; then
  swiftformat --lint . --config .swiftformat \
    --exclude .build,DerivedData,ThirdParty,Tools,.swiftpm,Packages/*/.build,build
else
  echo "— 跳过 swiftformat（未安装）"
fi
if [ "$HAVE_SWIFTLINT" = 1 ]; then
  swiftlint lint --config .swiftlint.yml
else
  echo "— 跳过 swiftlint（未安装），改跑仓库自带的模式闸门："
  python3 Scripts/check_lint.py
  python3 Scripts/check_braces.py
  python3 Scripts/check_visibility.py
  python3 Scripts/audit_duplicate_types.py
fi
python3 Scripts/check_app_icons.py

step "3/7 单测（7 个包，与 CI 同款）"
for package in CatVodCore CatVodNet CatVodSource CatVodPlayer CatVodStore CatVodUI CatVodNode; do
  echo "— $package"
  swift test --package-path "Packages/$package" >"/tmp/yp-test-$package.log" 2>&1 \
    || { echo "✗ $package 单测失败，尾部日志："; tail -30 "/tmp/yp-test-$package.log"; exit 1; }
done

step "4/7 构建 iOS（模拟器，未签名）"
xcodebuild build \
  -project YPlayer.xcodeproj -scheme YPlayer-iOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/dd-ios-sim \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  > build/ios-sim-build.log 2>&1 \
  || { grep -E 'error:' build/ios-sim-build.log | head -20; exit 1; }

step "5/7 构建 macOS（Release，未签名）—— 宿主产物"
xcodebuild build \
  -project YPlayer.xcodeproj -scheme YPlayer-macOS \
  -configuration Release \
  -derivedDataPath build/dd-macos \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  > build/macos-build.log 2>&1 \
  || { grep -E 'error:' build/macos-build.log | head -20; exit 1; }

step "6/7 打 Release 产物（未签名 IPA + macOS zip）"
APP_IOS=build/YPlayer-iOS.xcarchive/Products/Applications/YPlayer.app
rm -rf build/YPlayer-iOS.xcarchive build/Payload
xcodebuild archive \
  -project YPlayer.xcodeproj -scheme YPlayer-iOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/YPlayer-iOS.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  > build/ios-archive.log 2>&1 \
  || { grep -E 'error:' build/ios-archive.log | head -20; exit 1; }
mkdir -p build/Payload
cp -R "$APP_IOS" build/Payload/
(cd build && zip -qry "$OUT/YPlayer-unsigned.ipa" Payload)

MAC_APP=build/dd-macos/Build/Products/Release/YPlayer.app
(cd "$(dirname "$MAC_APP")" && zip -qry "$OUT/YPlayer-macOS-unsigned.zip" YPlayer.app)

step "7/7 校验产物 + 打开目录"
ls -lh "$OUT"
unzip -l "$OUT/YPlayer-unsigned.ipa" | head -5
open "$OUT"
echo
echo "✅ 全部完成（$VERSION（$BUILD））。产物在：$OUT"
