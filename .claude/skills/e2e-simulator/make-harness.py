#!/usr/bin/env python3
"""SwingDuet の E2E ハーネス（アプリ + XCUITest バンドルの別プロジェクト）を build/e2e-harness/ に生成する。

アプリ本体の xcodeproj には手を入れない。project.pbxproj をコピーして UI テストターゲットを差し込む。

生成物（build/ は gitignore 済み）:
  build/e2e-harness/SwingDuetHarness.xcodeproj   アプリ + SwingDuetUITests（共有スキーム SwingDuetUITests 付き）
  build/e2e-harness/SwingDuet/                   アプリソースのコピー（run.sh が実行のたびに同期する）
  build/e2e-harness/SwingDuetUITests/            FlowTests.swift のコピー
  build/e2e-harness/run.sh                       xcodebuild test を回して結果を out/ に出す
"""
import pathlib
import re
import shutil
import stat

SKILL = pathlib.Path(__file__).resolve().parent
REPO = SKILL.parents[2]
OUT = REPO / "build" / "e2e-harness"
PROJ = OUT / "SwingDuetHarness.xcodeproj"

# 追加するオブジェクトの ID（24 桁の 16 進。元プロジェクトの A1... と衝突しない）
UI_TARGET = "B100000000000000000000C1"
UI_GROUP = "B100000000000000000000C2"
UI_PRODUCT = "B100000000000000000000C5"
UI_SOURCES = "B100000000000000000000C6"
UI_FRAMEWORKS = "B100000000000000000000C7"
UI_RESOURCES = "B100000000000000000000C8"
UI_CONFIG_LIST = "B100000000000000000000C9"
UI_DEPENDENCY = "B100000000000000000000CA"
UI_PROXY = "B100000000000000000000CB"
UI_DEBUG = "B100000000000000000000D1"
UI_RELEASE = "B100000000000000000000D2"


def build_pbxproj(src: str) -> str:
    app_target = re.search(r"(\w{24}) /\* SwingDuet \*/ = \{\n\t\t\tisa = PBXNativeTarget;", src).group(1)
    app_group = re.search(r"(\w{24}) /\* SwingDuet \*/ = \{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;", src).group(1)
    app_product = re.search(r"(\w{24}) /\* SwingDuet\.app \*/ = \{isa = PBXFileReference;", src).group(1)
    project_obj = re.search(r"rootObject = (\w{24})", src).group(1)

    def ins(marker: str, text: str, before: bool = True) -> None:
        nonlocal src
        assert marker in src, f"pbxproj に想定したマーカーが無い: {marker!r}"
        src = src.replace(marker, (text + marker) if before else (marker + text), 1)

    def phase(kind: str, oid: str) -> str:
        return (f"\t\t{oid} /* {kind.replace('PBX', '').replace('BuildPhase', '')} */ = {{\n"
                f"\t\t\tisa = {kind};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n"
                f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")

    def config(name: str, oid: str) -> str:
        return (f"\t\t{oid} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n"
                "\t\t\t\tCODE_SIGN_STYLE = Automatic;\n\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n"
                "\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;\n"
                "\t\t\t\tMARKETING_VERSION = 1.0;\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.ha2ne2.SwingDuetUITests;\n"
                "\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";\n\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;\n"
                "\t\t\t\tSWIFT_VERSION = 5.0;\n\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";\n"
                f"\t\t\t\tTEST_TARGET_NAME = SwingDuet;\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n")

    ins("/* Begin PBXFileReference section */",
        "/* Begin PBXContainerItemProxy section */\n"
        f"\t\t{UI_PROXY} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n"
        f"\t\t\tcontainerPortal = {project_obj} /* Project object */;\n\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {app_target};\n\t\t\tremoteInfo = SwingDuet;\n\t\t}};\n"
        "/* End PBXContainerItemProxy section */\n\n")
    ins("/* End PBXFileReference section */",
        f"\t\t{UI_PRODUCT} /* SwingDuetUITests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; "
        "includeInIndex = 0; path = SwingDuetUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };\n")
    ins("/* End PBXFileSystemSynchronizedRootGroup section */",
        f"\t\t{UI_GROUP} /* SwingDuetUITests */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
        "\t\t\tpath = SwingDuetUITests;\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n")
    ins("/* End PBXFrameworksBuildPhase section */", phase("PBXFrameworksBuildPhase", UI_FRAMEWORKS))
    ins(f"\t\t\t\t{app_group} /* SwingDuet */,\n", f"\t\t\t\t{UI_GROUP} /* SwingDuetUITests */,\n", before=False)
    ins(f"\t\t\t\t{app_product} /* SwingDuet.app */,\n", f"\t\t\t\t{UI_PRODUCT} /* SwingDuetUITests.xctest */,\n", before=False)
    ins("/* End PBXNativeTarget section */",
        f"\t\t{UI_TARGET} /* SwingDuetUITests */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {UI_CONFIG_LIST} /* Build configuration list for PBXNativeTarget \"SwingDuetUITests\" */;\n"
        f"\t\t\tbuildPhases = (\n\t\t\t\t{UI_SOURCES} /* Sources */,\n\t\t\t\t{UI_FRAMEWORKS} /* Frameworks */,\n"
        f"\t\t\t\t{UI_RESOURCES} /* Resources */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n"
        f"\t\t\tdependencies = (\n\t\t\t\t{UI_DEPENDENCY} /* PBXTargetDependency */,\n\t\t\t);\n"
        f"\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t{UI_GROUP} /* SwingDuetUITests */,\n\t\t\t);\n"
        "\t\t\tname = SwingDuetUITests;\n\t\t\tpackageProductDependencies = (\n\t\t\t);\n"
        f"\t\t\tproductName = SwingDuetUITests;\n\t\t\tproductReference = {UI_PRODUCT} /* SwingDuetUITests.xctest */;\n"
        "\t\t\tproductType = \"com.apple.product-type.bundle.ui-testing\";\n\t\t};\n")
    # TargetAttributes: アプリの属性ブロックの直後に UI テストの属性を追加
    attr = re.search(rf"\t\t\t\t\t{app_target} = \{{[^}}]*\}};\n", src).group(0)
    ins(attr, f"\t\t\t\t\t{UI_TARGET} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;\n"
              f"\t\t\t\t\t\tTestTargetID = {app_target};\n\t\t\t\t\t}};\n", before=False)
    ins(f"\t\t\ttargets = (\n\t\t\t\t{app_target} /* SwingDuet */,\n",
        f"\t\t\t\t{UI_TARGET} /* SwingDuetUITests */,\n", before=False)
    ins("/* End PBXResourcesBuildPhase section */", phase("PBXResourcesBuildPhase", UI_RESOURCES))
    ins("/* End PBXSourcesBuildPhase section */", phase("PBXSourcesBuildPhase", UI_SOURCES))
    ins("/* Begin XCBuildConfiguration section */",
        "/* Begin PBXTargetDependency section */\n"
        f"\t\t{UI_DEPENDENCY} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n"
        f"\t\t\ttarget = {app_target} /* SwingDuet */;\n\t\t\ttargetProxy = {UI_PROXY} /* PBXContainerItemProxy */;\n\t\t}};\n"
        "/* End PBXTargetDependency section */\n\n")
    ins("/* End XCBuildConfiguration section */", config("Debug", UI_DEBUG) + config("Release", UI_RELEASE))
    ins("/* End XCConfigurationList section */",
        f"\t\t{UI_CONFIG_LIST} /* Build configuration list for PBXNativeTarget \"SwingDuetUITests\" */ = {{\n"
        "\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{UI_DEBUG} /* Debug */,\n\t\t\t\t{UI_RELEASE} /* Release */,\n\t\t\t);\n"
        "\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};\n")
    return src, app_target


def buildable(identifier: str, name: str, product: str) -> str:
    return (f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{identifier}" '
            f'BuildableName = "{product}" BlueprintName = "{name}" ReferencedContainer = "container:SwingDuetHarness.xcodeproj"/>')


def scheme(app_target: str) -> str:
    app = buildable(app_target, "SwingDuet", "SwingDuet.app")
    ui = buildable(UI_TARGET, "SwingDuetUITests", "SwingDuetUITests.xctest")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {app}
         </BuildActionEntry>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "NO">
            {ui}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            {ui}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {app}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {app}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"/>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"/>
</Scheme>
"""


RUN_SH = """#!/bin/zsh
# SwingDuet の E2E を回す。使い方: [E2E_ONLY=<テスト>] [E2E_KEEP_DATA=1] run.sh [<シミュレータ UDID>]（省略時は起動中のシミュレータ）
# 結果: out/uitest_trace.log（操作ログ）, out/NN_*.png（スクリーンショット）, xcodebuild.log
set -u
H="$(cd "$(dirname "$0")" && pwd)"
REPO="__REPO__"
SIM="${1:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)}"
if [ -z "$SIM" ]; then
  echo "起動中のシミュレータがありません。UDID を引数で渡すか、xcrun simctl boot してください" >&2
  exit 1
fi

# アプリソースとテストを最新に同期（ハーネス自体は make-harness.py で再生成する）
rsync -a --delete "$REPO/SwingDuet/" "$H/SwingDuet/"
cp "$REPO/.claude/skills/e2e-simulator/FlowTests.swift" "$H/SwingDuetUITests/FlowTests.swift"

rm -rf "$H/out"; mkdir -p "$H/out"
# 毎回まっさらな状態から始める（E2E_KEEP_DATA=1 なら保存データを残す。保存済みのスイングを使うテスト用）
[ -n "${E2E_KEEP_DATA:-}" ] || xcrun simctl uninstall "$SIM" com.ha2ne2.SwingDuet 2>/dev/null
# 写真ライブラリの権限を先に許可しておく（「動画」タブが自前のグリッドを出すのに要る。ダイアログが出た場合はテスト側でも押す）
xcrun simctl privacy "$SIM" grant photos com.ha2ne2.SwingDuet 2>/dev/null
# E2E_ONLY="SwingDuetUITests/FlowTests/testZoomPanPersistence" のように 1 テストだけ回せる
only=(); [ -n "${E2E_ONLY:-}" ] && only=(-only-testing:"$E2E_ONLY")
# TEST_RUNNER_ 接頭辞の環境変数はテストランナーのプロセスへ渡される（ビルド設定として渡しても届かない）
TEST_RUNNER_E2E_OUT_DIR="$H/out" \\
TEST_RUNNER_E2E_MINE_INDEX="${E2E_MINE_INDEX:-1}" TEST_RUNNER_E2E_MODEL_INDEX="${E2E_MODEL_INDEX:-0}" \\
TEST_RUNNER_E2E_MINE_MATCH="${E2E_MINE_MATCH:-}" TEST_RUNNER_E2E_MODEL_MATCH="${E2E_MODEL_MATCH:-}" \\
xcodebuild test -project "$H/SwingDuetHarness.xcodeproj" -scheme SwingDuetUITests \\
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$H/build" -allowProvisioningUpdates "${only[@]}" \\
  > "$H/xcodebuild.log" 2>&1
echo "exit=$?"
echo "=== build errors ==="; grep -E "error:" "$H/xcodebuild.log" | sort -u | head -20
echo "=== test summary ==="; grep -E "Test Case|Executed|\\*\\* TEST" "$H/xcodebuild.log" | head -20
echo "=== trace ==="; cat "$H/out/uitest_trace.log" 2>/dev/null
echo "=== screenshots ($H/out) ==="; ls "$H/out" 2>/dev/null | grep png
"""


def main() -> None:
    pbx_src = (REPO / "SwingDuet.xcodeproj" / "project.pbxproj").read_text()
    pbx, app_target = build_pbxproj(pbx_src)

    (PROJ / "xcshareddata" / "xcschemes").mkdir(parents=True, exist_ok=True)
    (PROJ / "project.pbxproj").write_text(pbx)
    (PROJ / "xcshareddata" / "xcschemes" / "SwingDuetUITests.xcscheme").write_text(scheme(app_target))

    (OUT / "SwingDuetUITests").mkdir(parents=True, exist_ok=True)
    shutil.copy(SKILL / "FlowTests.swift", OUT / "SwingDuetUITests" / "FlowTests.swift")
    if (OUT / "SwingDuet").exists():
        shutil.rmtree(OUT / "SwingDuet")
    shutil.copytree(REPO / "SwingDuet", OUT / "SwingDuet")

    run = OUT / "run.sh"
    run.write_text(RUN_SH.replace("__REPO__", str(REPO)))
    run.chmod(run.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"generated: {OUT}\n  run: {run}")


if __name__ == "__main__":
    main()
