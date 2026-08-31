#!/bin/bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SPEC="project.yml"
BACKUP="project.yml.podcast-marker-backup"

if [[ ! -f "$BACKUP" ]]; then
  cp "$SPEC" "$BACKUP"
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

# The podcast-marker prototype does not need the watch complication or an App Group.
# Removing them makes Personal Team / local-device signing substantially simpler.
watch_entitlements = '''    entitlements:\n      path: YourPodsWatch/YourPodsWatch.entitlements\n      properties:\n        com.apple.security.application-groups:\n          - group.com.mastersmall.podcastmarker.watch\n'''
text = text.replace(watch_entitlements, '')

watch_dependency = '''    dependencies:\n      - target: YourPodsComplication\n        embed: true\n        codeSign: true\n        copy:\n          destination: plugins\n'''
text = text.replace(watch_dependency, '')

watch_scheme = '''  YourPodsWatch:\n    build:\n      targets:\n        YourPodsWatch: all\n        YourPodsComplication: all\n'''
watch_scheme_replacement = '''  YourPodsWatch:\n    build:\n      targets:\n        YourPodsWatch: all\n'''
text = text.replace(watch_scheme, watch_scheme_replacement)

# Give the local watch build a distinct display name.
text = text.replace('        CFBundleDisplayName: YourPods\n        CFBundleName: YourPodsWatch\n',
                    '        CFBundleDisplayName: Podcast Marker\n        CFBundleName: PodcastMarkerWatch\n')

path.write_text(text)
PY

xcodegen generate

echo
echo "Podcast Marker signing prep complete."
echo "Open YourPods.xcodeproj, select the YourPodsWatch target, choose your Apple Team, then Run."
