#!/usr/bin/env bash
# 本地跑「CI 的硬性检查 + 出 Release 产物」一条龙（M28 发布 1.0.1 用）。
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
# 前置：Xcode（建议本机装了 CI 同版 26.6）、xcodegen、swiftlint、swiftformat 都可用：
#   brew install xcodegen swiftlint swiftformat
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd)"
OUT="$REPO_ROOT/build/release-1.0.1"
mkdir -p "$OUT"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1"; exit 1; }

step "0/7 工具链"
for tool in xcodegen swiftlint swiftformat python3; do
  command -v "$tool" >/dev/null || fail "缺少 $tool（brew install xcodegen swiftlint swiftformat）"
done
xcodebuild -version
swift --version
swiftformat --version
swiftlint version

step "1/7 生成工程（XcodeGen）"
python3 Scripts/fetch_nodejs_mobile.py
xcodegen generate

step "2/7 Lint（与 CI 同款，阻断）"
swiftformat --lint . --config .swiftformat \
  --exclude .build,DerivedData,ThirdParty,Tools,.swiftpm,Packages/*/.build,build
swiftlint lint --config .swiftlint.yml
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
(cd build && zip -qry "release-1.0.1/YPlayer-unsigned.ipa" Payload)

MAC_APP=build/dd-macos/Build/Products/Release/YPlayer.app
(cd "$(dirname "$MAC_APP")" && zip -qry "$OUT/YPlayer-macOS-unsigned.zip" YPlayer.app)

step "7/7 校验产物 + 打开目录"
ls -lh "$OUT"
unzip -l "$OUT/YPlayer-unsigned.ipa" | head -5
open "$OUT"
echo
echo "✅ 全部完成。产物在：$(pwd)/$OUT"
