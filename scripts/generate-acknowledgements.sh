#!/bin/zsh
# Writes the licence notices the About panel shows, one entry for each Swift package the app is
# built with: Packages/LiveTranscribeKit/Sources/About/Acknowledgements.json.
#
# Run it after adding, removing or updating a package, and commit what it writes. AboutTests fails
# while the file doesn't match Package.resolved. It resolves the packages first, which needs the
# network the first time.
set -euo pipefail

root="${0:A:h:h}"
package="$root/Packages/LiveTranscribeKit"
output="$package/Sources/About/Acknowledgements.json"

(cd "$package" && swift package resolve >/dev/null)
xcrun swift "${0:A:h}/generate-acknowledgements.swift" \
  "$package/Package.resolved" "$package/.build/checkouts" "$output"
print "Wrote ${output#$root/}"
