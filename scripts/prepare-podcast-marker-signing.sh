#!/bin/bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SPEC="project.yml"
BACKUP="project.yml.podcast-marker-backup"
PBXPROJ="YourPods.xcodeproj/project.pbxproj"

# Preserve the Apple Development team already selected in Xcode before
# regenerating the project. This avoids forcing the user to re-select the
# Personal Team after every prototype update.
TEAM_ID=""
if [[ -f "$PBXPROJ" ]]; then
  TEAM_ID="$(python3 - <<'PY'
import re
from pathlib import Path
p = Path("YourPods.xcodeproj/project.pbxproj")
text = p.read_text(errors="ignore") if p.exists() else ""
m = re.search(r"DEVELOPMENT_TEAM = ([A-Z0-9]+);", text)
print(m.group(1) if m else "")
PY
)"
fi
export PODCAST_MARKER_TEAM_ID="$TEAM_ID"

# Always regenerate from the untouched upstream spec so the script is idempotent.
if [[ ! -f "$BACKUP" ]]; then
  cp "$SPEC" "$BACKUP"
else
  cp "$BACKUP" "$SPEC"
fi

python3 <<'PY'
import os
from pathlib import Path

path = Path("project.yml")
text = path.read_text()

# Use identifiers owned by the fork/prototype rather than the upstream publisher.
text = text.replace("com.asecretcompany.yourpods", "com.mastersmall.podcastmarker")

# Preserve the locally selected Apple team when available; otherwise leave team
# selection to Xcode instead of pinning the upstream placeholder.
team_id = os.environ.get("PODCAST_MARKER_TEAM_ID", "").strip()
if team_id:
    text = text.replace('    DEVELOPMENT_TEAM: YOUR_TEAM_ID\n', f'    DEVELOPMENT_TEAM: "{team_id}"\n')
else:
    text = text.replace('    DEVELOPMENT_TEAM: YOUR_TEAM_ID\n', '')

# ---------------------------------------------------------------------------
# iPhone prototype: remove capabilities that are irrelevant to Podcast Marker
# and commonly fail on a Personal Team (CarPlay/Siri/App Groups/widgets).
# Keep the Watch app embedded in the iPhone app: that companion relationship is
# required for WatchConnectivity to recognise isWatchAppInstalled.
# ---------------------------------------------------------------------------
phone_entitlements = '''    entitlements:\n      path: YourPods/YourPods.entitlements\n      properties:\n        com.apple.developer.carplay-audio: true\n        com.apple.developer.siri: true\n        com.apple.security.application-groups:\n          - group.com.mastersmall.podcastmarker\n'''
text = text.replace(phone_entitlements, '')

phone_widget_dependency = '''      - target: YourPodsWidgets\n        embed: true\n        codeSign: true\n        copy:\n          destination: plugins\n'''
text = text.replace(phone_widget_dependency, '')

# Xcode 26 treats a single-target watchOS app as a Foundation extension inside
# the iPhone bundle. Explicitly place it in PlugIns instead of relying on the
# historical XcodeGen Watch/ destination.
watch_embed_dependency = '''      - target: YourPodsWatch\n        embed: true\n        codeSign: true\n'''
watch_embed_replacement = '''      - target: YourPodsWatch\n        embed: true\n        codeSign: true\n        copy:\n          destination: plugins\n'''
text = text.replace(watch_embed_dependency, watch_embed_replacement, 1)

main_scheme = '''  YourPods:\n    build:\n      targets:\n        YourPods: all\n        YourPodsTests: [test]\n        YourPodsWidgets: all\n        YourPodsWatch: all\n        YourPodsComplication: all\n'''
main_scheme_replacement = '''  YourPods:\n    build:\n      targets:\n        YourPods: all\n        YourPodsTests: [test]\n        YourPodsWatch: all\n'''
text = text.replace(main_scheme, main_scheme_replacement)

# ---------------------------------------------------------------------------
# Watch prototype: complication/App Group are unnecessary for marker testing.
# ---------------------------------------------------------------------------
watch_entitlements = '''    entitlements:\n      path: YourPodsWatch/YourPodsWatch.entitlements\n      properties:\n        com.apple.security.application-groups:\n          - group.com.mastersmall.podcastmarker.watch\n'''
text = text.replace(watch_entitlements, '')

watch_dependency = '''    dependencies:\n      - target: YourPodsComplication\n        embed: true\n        codeSign: true\n        copy:\n          destination: plugins\n'''
text = text.replace(watch_dependency, '')

watch_scheme = '''  YourPodsWatch:\n    build:\n      targets:\n        YourPodsWatch: all\n        YourPodsComplication: all\n'''
watch_scheme_replacement = '''  YourPodsWatch:\n    build:\n      targets:\n        YourPodsWatch: all\n'''
text = text.replace(watch_scheme, watch_scheme_replacement)

# A companion Watch app should not be treated as an independently-installed app
# while debugging this iPhone/Watch pair. This makes the companion relationship
# explicit to watchOS/Xcode.
text = text.replace(
    '        WKApplication: true\n',
    '        WKApplication: true\n        WKRunsIndependentlyOfCompanionApp: false\n',
    1,
)

# Distinct prototype display names.
text = text.replace('        CFBundleDisplayName: YourPods\n        CFBundleName: YourPods\n',
                    '        CFBundleDisplayName: Podcast Marker\n        CFBundleName: PodcastMarker\n', 1)
text = text.replace('        CFBundleDisplayName: YourPods\n        CFBundleName: YourPodsWatch\n',
                    '        CFBundleDisplayName: Podcast Marker\n        CFBundleName: PodcastMarkerWatch\n')

path.write_text(text)
PY

xcodegen generate

# XcodeGen 2.45.x/2.46.x can still emit the historical Watch/ copy destination
# with Xcode 26. Single-target watchOS apps must be embedded as Foundation
# extensions in the parent app's PlugIns directory. Patch only the copy phase
# containing YourPodsWatch.app, then verify the result before continuing.
python3 <<'PY'
import re
from pathlib import Path

path = Path("YourPods.xcodeproj/project.pbxproj")
text = path.read_text()

phase_pattern = re.compile(
    r'(?ms)^\s*[A-F0-9]{24} /\* .*? \*/ = \{\n\s*isa = PBXCopyFilesBuildPhase;.*?^\s*\};'
)
found = False
patched = False

def fix_phase(match):
    global found, patched
    block = match.group(0)
    if "YourPodsWatch.app" not in block:
        return block
    found = True
    new = block.replace('dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";', 'dstPath = "";')
    new = new.replace('dstSubfolderSpec = 16;', 'dstSubfolderSpec = 13;')
    if new != block:
        patched = True
    return new

text = phase_pattern.sub(fix_phase, text)
path.write_text(text)

if not found:
    raise SystemExit("ERROR: generated iPhone project has no copy phase for YourPodsWatch.app")

# Verify the Watch app is now copied into PlugIns (dstSubfolderSpec 13), not Watch/.
verified = False
for match in phase_pattern.finditer(text):
    block = match.group(0)
    if "YourPodsWatch.app" in block and "dstSubfolderSpec = 13;" in block:
        verified = True
        break
if not verified:
    raise SystemExit("ERROR: YourPodsWatch.app is not embedded in the iPhone PlugIns directory")

print("Watch embedding verified: iPhone PlugIns directory")
PY

# XcodeGen writes the Watch plist from project.yml, but keep explicit guards so
# future upstream/project-spec changes cannot silently break the companion pair.
/usr/libexec/PlistBuddy -c "Set :WKCompanionAppBundleIdentifier com.mastersmall.podcastmarker" YourPodsWatch/Info.plist
if ! /usr/libexec/PlistBuddy -c "Set :WKRunsIndependentlyOfCompanionApp false" YourPodsWatch/Info.plist 2>/dev/null; then
  /usr/libexec/PlistBuddy -c "Add :WKRunsIndependentlyOfCompanionApp bool false" YourPodsWatch/Info.plist
fi

echo
echo "Podcast Marker signing prep complete."
if [[ -n "$TEAM_ID" ]]; then
  echo "Preserved Apple Development Team: $TEAM_ID"
else
  echo "No previous Apple team found; choose your Personal Team once in Xcode."
fi
echo "Watch companion embedding verified for Xcode 26."
echo "Run YourPods on iPhone first; then install/run YourPodsWatch on the paired Watch if needed."
