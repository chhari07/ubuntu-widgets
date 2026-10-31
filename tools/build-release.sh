#!/usr/bin/env bash
# Builds dist/ for a GitHub release from the committed tree: the archive, its checksum
# and the two scripts people download directly.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
VERSION="$(cat VERSION)"
[[ "$(./install.sh --version)" == "$VERSION" ]] || { echo "install.sh and VERSION disagree" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first" >&2; exit 1; }

rm -rf dist
mkdir dist
git archive --format=tar.gz --prefix="ubuntu-widgets-$VERSION/" -o dist/ubuntu-widgets.tar.gz HEAD
(cd dist && sha256sum ubuntu-widgets.tar.gz > ubuntu-widgets.tar.gz.sha256)
cp install.sh uninstall.sh dist/
ls -l dist
