#!/bin/sh
#
# One-time setup: configures git to use the .githooks directory for hooks.
# Run this after cloning the repo.
#

set -e

REPO_ROOT="$(git rev-parse --show-toplevel)"
git config core.hooksPath "$REPO_ROOT/.githooks"
chmod +x "$REPO_ROOT/.githooks/pre-commit"

echo "✅ Git hooks configured. Pre-commit hook is now active."
