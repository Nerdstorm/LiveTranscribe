#!/bin/zsh
# Renders Live Transcribe's icons from the SVGs in design/ and site/: the app icon set in
# App/Assets.xcassets, and the website's icons and header image in site/.
#
# The PNGs are committed, so a build doesn't need this. Run it after editing an SVG, and commit
# what it writes. It compiles svg-to-png.swift, which draws with WebKit, so the PNGs match
# what a browser shows.
set -euo pipefail

root="${0:A:h:h}"
design="$root/design"
iconset="$root/App/Assets.xcassets/AppIcon.appiconset"
site="$root/site"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

renderer="$work_dir/svg-to-png"
xcrun swiftc -O -o "$renderer" "${0:A:h}/svg-to-png.swift"

# render <svg> <png> <pixels>
render() {
  "$renderer" "$1" "$2" "$3"
  print "  ${2#$root/} (${3}×${3})"
}

print "App icon set:"
mkdir -p "$iconset"
# 16 pixels has its own, simpler drawing; every other size is drawn from AppIcon.svg.
render "$design/AppIcon-16.svg" "$iconset/icon_16x16.png" 16
render "$design/AppIcon.svg" "$iconset/icon_16x16@2x.png" 32
for points in 32 128 256 512; do
  render "$design/AppIcon.svg" "$iconset/icon_${points}x${points}.png" "$points"
  render "$design/AppIcon.svg" "$iconset/icon_${points}x${points}@2x.png" "$(( points * 2 ))"
done

print "Website:"
render "$design/AppIcon.svg" "$site/images/app-icon.png" 256
render "$site/favicon.svg" "$site/favicon-32.png" 32
render "$design/TouchIcon.svg" "$site/apple-touch-icon.png" 180
