#!/bin/bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SPEC="project.yml"
BACKUP="project.yml.podcast-marker-backup"

# Always regenerate from the untouched upstream spec so the script is idempotent.
if [[ ! -f "$BACKUP" ]]; then
  cp "$SPEC" "$BACKUP"
else
  cp "$BACKUP" "$SPEC"
fi

python3 <<'PY'
from pathlib import Path

path = Path("project.yml")
text = path.read_text()

# Use identifiers owned by the fork/prototype rather than the upstream publisher.
text = text.replace("com.asecretcompany.yourpods", "com.mastersmall.podcastmarker")

# Do not pin the upstream placeholder team. Xcode will use the Apple account/team
# selected locally in Signing & Capabilities.
text = text.replace('    DEVELOPMENT_TEAM: YOUR_TEAM_ID\n', '')

# ---------------------------------------------------------------------------
# iPhone prototype: remove capabilities that are irrelevant to Podcast Marker
# and commonly fail on a Personal Team (CarPlay/Siri/App Groups/widgets).
# WatchConnectivity itself does not require these entitlements.
# ---------------------------------------------------------------------------
phone_entitlements = '''    entitlements:\n      path: YourPods/YourPods.entitlements\n      properties:\n        com.apple.developer.carplay-audio: true\n        com.apple.developer.siri: true\n        com.apple.security.application-groups:\n          - group.com.mastersmall.podcastmarker\n'''
text = text.replace(phone_entitlements, '')

phone_extra_dependencies = '''      - target: YourPodsWidgets\n        embed: true\n        codeSign: true\n        copy:\n          destination: plugins\n      - target: YourPodsWatch\n        embed: true\n        codeSign: true\n'''
text = text.replace(phone_extra_dependencies, '')

main_scheme = '''  YourPods:\n    build:\n      targets:\n        YourPods: all\n        YourPodsTests: [test]\n        YourPodsWidgets: all\n        YourPodsWatch: all\n        YourPodsComplication: all\n'''
main_scheme_replacement = '''  YourPods:\n    build:\n      targets:\n        YourPods: all\n        YourPodsTests: [test]\n'''
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

# Distinct prototype display names.
text = text.replace('        CFBundleDisplayName: YourPods\n        CFBundleName: YourPods\n',
                    '        CFBundleDisplayName: Podcast Marker\n        CFBundleName: PodcastMarker\n', 1)
text = text.replace('        CFBundleDisplayName: YourPods\n        CFBundleName: YourPodsWatch\n',
                    '        CFBundleDisplayName: Podcast Marker\n        CFBundleName: PodcastMarkerWatch\n')

path.write_text(text)
PY

xcodegen generate

# XcodeGen writes the Watch plist from project.yml, but keep this explicit guard
# so a future upstream/project-spec change cannot silently reconnect the Watch
# target to the original YourPods iPhone bundle.
/usr/libexec/PlistBuddy -c "Set :WKCompanionAppBundleIdentifier com.mastersmall.podcastmarker" YourPodsWatch/Info.plist

echo
echo "Podcast Marker signing prep complete."
echo "For Watch: select YourPodsWatch, choose your Apple Team, Run on Apple Watch."
echo "For iPhone: select YourPods, choose the same Apple Team, Run on iPhone."
