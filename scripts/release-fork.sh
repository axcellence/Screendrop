#!/bin/zsh
# Build, notarize and publish a release of this fork on GitHub, where the app's built-in updater
# finds it.
#
#   scripts/release-fork.sh [--notes "text" | --notes-file path] [--dry-run]
#
# Releases the commit that is checked out, which must be clean and pushed to GitHub. It archives a
# Release build, signs it with the Developer ID certificate, has Apple notarize it, staples the
# ticket, zips it, signs the zip with the fork's Sparkle key, and publishes a GitHub release on
# axcellence/Screendrop carrying Screendrop.zip and appcast.xml. Apps follow
#
#   https://github.com/axcellence/Screendrop/releases/latest/download/appcast.xml
#
# so a release makes no commits and can be cut from any branch.
#
# Versions. Upstream's MARKETING_VERSION and CURRENT_PROJECT_VERSION stay untouched in the project;
# they are overridden on the xcodebuild command line. A release is numbered within the upstream
# build it is based on: the first release on upstream build 40 is build 40.1, version
# 0.38.0-fork.1, tag fork-40.1; the next is 40.2, and so on. Sparkle compares build numbers part
# by part, so 40.2 > 40.1 > 40 (the plain upstream build) and 41.1 > 40.9 once upstream moves on.
#
# Re-running is safe. A commit that already has a release reuses its number; a published release
# with both files is left alone; a draft left by a failed run is finished; a notarized app from an
# earlier attempt is reused instead of being built again. The release stays a draft, invisible to
# the updater, until both files are uploaded.
#
# --dry-run builds, zips, signs and writes the appcast without the Developer ID, notarization or
# GitHub writes, to check the pipeline. Its app is development-signed and must not be shipped.
#
# One-time setup on the releasing Mac (see FORK.md):
#   - a "Developer ID Application" certificate for team VG74JMPJF4 in the login keychain;
#   - a notarytool keychain profile, by default "screendrop-fork-notary";
#   - the fork's Sparkle key in the keychain under the account "com.axcellence.Screendrop";
#   - gh signed in with push access to axcellence/Screendrop.
set -euo pipefail
setopt extended_glob

repo="axcellence/Screendrop"
team="VG74JMPJF4"
bundle_id="com.axcellence.Screendrop"
sparkle_account="${SCREENDROP_SPARKLE_ACCOUNT:-com.axcellence.Screendrop}"
notary_profile="${SCREENDROP_NOTARY_PROFILE:-screendrop-fork-notary}"
work="${SCREENDROP_RELEASE_DIR:-$HOME/Library/Caches/screendrop-fork-release}"
feed_url="https://github.com/$repo/releases/latest/download/appcast.xml"
zip_name="Screendrop.zip"
appcast_name="appcast.xml"

die() { print -u2 -- "\nrelease-fork: $*"; exit 1 }
step() { print -- "\n==> $*" }
ok() { print -- "    $*" }

notes=""
dry_run=false
while (( $# )); do
  case "$1" in
    --notes) (( $# >= 2 )) || die "--notes needs text"; notes="$2"; shift 2 ;;
    --notes-file) (( $# >= 2 )) || die "--notes-file needs a path"; notes="$(<"$2")"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

cd "$(dirname "$0")/.."
root="$PWD"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ "$(xcode-select -p 2>/dev/null)" == *Xcode* ]]; then
    export DEVELOPER_DIR="$(xcode-select -p)"
  elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    die "Xcode not found. Install Xcode or set DEVELOPER_DIR."
  fi
fi

# --- Preflight -------------------------------------------------------------------------------

step "Checking prerequisites"

for tool in xcodebuild xcrun ditto gh git curl plutil shasum security codesign spctl; do
  command -v "$tool" >/dev/null || die "$tool not found."
done

[[ -z "$(git status --porcelain)" ]] ||
  die "The checkout has uncommitted or untracked changes. Release from a clean checkout."

# Everything in the source folder goes into the app, and git-ignored files there (such as
# Secrets.plist and its API key) would be published with it.
ignored=$(git ls-files --others --ignored --exclude-standard -- Screendrop)
[[ -z "$ignored" ]] ||
  die "Git-ignored files in Screendrop/ would be built into a public release:\n$ignored\nMove them aside first."

gh auth status >/dev/null 2>&1 || die "gh is not signed in. Run: gh auth login"

sha=$(git rev-parse HEAD)
short_sha=$(git rev-parse --short HEAD)

if ! $dry_run; then
  gh api "repos/$repo/commits/$sha" --silent 2>/dev/null ||
    die "Commit $short_sha is not on GitHub. Push it to $repo first."

  identities=$(security find-identity -v -p codesigning)
  [[ "$identities" == *"Developer ID Application: "*"($team)"* ]] ||
    die "No \"Developer ID Application\" certificate for team $team in the keychain.
Create one as the account holder (FORK.md, \"One-time setup\") and run this again."

  xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 ||
    die "The notarytool keychain profile \"$notary_profile\" is missing or invalid. Create it with:
  xcrun notarytool store-credentials $notary_profile --key <AuthKey.p8> --key-id <id> --issuer <issuer>"
fi

mkdir -p "$work"
derived="$work/DerivedData"
xcodebuild -resolvePackageDependencies -project Screendrop.xcodeproj -scheme Screendrop \
  -derivedDataPath "$derived" >"$work/resolve.log" 2>&1 ||
  die "Resolving Swift packages failed. See $work/resolve.log"
sparkle_bin="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$sparkle_bin/sign_update" && -x "$sparkle_bin/generate_keys" ]] ||
  die "Sparkle's tools were not found in $sparkle_bin."

public_key=$("$sparkle_bin/generate_keys" --account "$sparkle_account" -p 2>/dev/null) ||
  die "No Sparkle key in the keychain under the account \"$sparkle_account\". Create it once with:
  $sparkle_bin/generate_keys --account $sparkle_account
and put the public key it prints in Screendrop/Info.plist as SUPublicEDKey."
plist_key=$(plutil -extract SUPublicEDKey raw -o - Screendrop/Info.plist)
[[ "$public_key" == "$plist_key" ]] ||
  die "SUPublicEDKey in Info.plist ($plist_key) is not the public half of the \"$sparkle_account\" key ($public_key)."
plist_feed=$(plutil -extract SUFeedURL raw -o - Screendrop/Info.plist)
[[ "$plist_feed" == "$feed_url" ]] ||
  die "SUFeedURL in Info.plist is $plist_feed, expected $feed_url."
ok "Tools, checkout and keys are in order"

# --- Version ---------------------------------------------------------------------------------

step "Working out the version"

settings=$(xcodebuild -showBuildSettings -project Screendrop.xcodeproj -scheme Screendrop \
  -configuration Release 2>/dev/null)
setting() { print -r -- "$settings" | awk -F' = ' -v key="$1" '$1 ~ "^ *"key"$" { print $2; exit }' }
base_version=$(setting MARKETING_VERSION)
base_build=$(setting CURRENT_PROJECT_VERSION)
[[ "$base_build" == <-> ]] || die "CURRENT_PROJECT_VERSION is \"$base_build\", expected a whole number."
[[ -n "$base_version" ]] || die "Could not read the project's version settings."

releases=$(gh api --paginate "repos/$repo/releases?per_page=100" \
  --jq '.[] | [.tag_name, .target_commitish] | @tsv') || die "Could not list releases on $repo."
tags=$(gh api --paginate "repos/$repo/git/matching-refs/tags/fork-" \
  --jq '.[] | [(.ref | ltrimstr("refs/tags/")), .object.sha] | @tsv') || die "Could not list tags on $repo."

number_pattern="^fork-${base_build}\\.([0-9]+)$"
highest=0
tag=""
for line in ${(f)releases} ${(f)tags}; do
  name=${line%%$'\t'*}
  target=${line#*$'\t'}
  [[ "$name" =~ $number_pattern ]] || continue
  (( match[1] > highest )) && highest=${match[1]}
  [[ "$target" == "$sha" && -z "$tag" ]] && tag="$name"
done
if [[ -n "$tag" ]]; then
  number=${tag##*.}
  ok "Commit $short_sha already has release $tag; continuing it"
else
  number=$(( highest + 1 ))
  tag="fork-$base_build.$number"
fi
build="$base_build.$number"
version="$base_version-fork.$number"
ok "Upstream $base_version ($base_build) -> $version ($build), tag $tag"

if ! $dry_run; then
  existing=$(gh release view "$tag" -R "$repo" --json isDraft,assets \
    --jq '[(.isDraft | tostring), (.assets | map(.name) | join(" "))] | join(" ")' 2>/dev/null || true)
  if [[ "$existing" == false\ * && " $existing " == *" $zip_name "* && " $existing " == *" $appcast_name "* ]]; then
    print -- "\n$tag is already published: https://github.com/$repo/releases/tag/$tag"
    exit 0
  fi
fi

out="$work/$tag"
$dry_run && out="$work/$tag-dry-run"
app="$out/Screendrop.app"
mkdir -p "$out"

# --- Build, sign, notarize -------------------------------------------------------------------

info() { plutil -extract "$1" raw -o - "$app/Contents/Info.plist" 2>/dev/null || true }

reusable=false
if ! $dry_run && [[ -d "$app" && "$(cat "$out/commit" 2>/dev/null)" == "$sha" && "$(info CFBundleVersion)" == "$build" ]] &&
  xcrun stapler validate -q "$app" >/dev/null 2>&1 && codesign --verify --deep --strict "$app" 2>/dev/null; then
  reusable=true
  step "Reusing the notarized app from an earlier attempt"
fi

if ! $reusable; then
  rm -rf "$app" "$out/commit" "$out/export" "$out/Screendrop.xcarchive"

  step "Archiving (a few minutes)"
  xcodebuild archive \
    -project Screendrop.xcodeproj \
    -scheme Screendrop \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$out/Screendrop.xcarchive" \
    -derivedDataPath "$derived" \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build" \
    >"$out/archive.log" 2>&1 || { tail -40 "$out/archive.log"; die "Archiving failed. Full log: $out/archive.log" }
  ok "Archived"

  if $dry_run; then
    ditto "$out/Screendrop.xcarchive/Products/Applications/Screendrop.app" "$app"
    ok "Dry run: keeping the archive's development signature"
  else
    step "Exporting with Developer ID"
    cat >"$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$team</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
</dict>
</plist>
EOF
    xcodebuild -exportArchive \
      -archivePath "$out/Screendrop.xcarchive" \
      -exportOptionsPlist "$out/ExportOptions.plist" \
      -exportPath "$out/export" \
      >"$out/export.log" 2>&1 || { tail -40 "$out/export.log"; die "Export failed. Full log: $out/export.log" }
    ditto "$out/export/Screendrop.app" "$app"
    signer=$(codesign -dvv "$app" 2>&1)
    [[ "$signer" == *$'\n'"Authority=Developer ID Application: "*"($team)"$'\n'* ]] ||
      die "The exported app is not signed with a Developer ID."
    ok "Signed with Developer ID"

    step "Notarizing (Apple usually takes a few minutes)"
    ditto -c -k --keepParent "$app" "$out/notarize.zip"
    xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$notary_profile" --wait \
      --output-format json >"$out/notarize.json" 2>"$out/notarize.log" ||
      { cat "$out/notarize.log" "$out/notarize.json" 2>/dev/null; die "notarytool failed." }
    notary_status=$(plutil -extract status raw -o - "$out/notarize.json" 2>/dev/null || true)
    if [[ "$notary_status" != "Accepted" ]]; then
      submission=$(plutil -extract id raw -o - "$out/notarize.json" 2>/dev/null || true)
      die "Notarization came back \"$notary_status\". See why with:
  xcrun notarytool log $submission --keychain-profile $notary_profile"
    fi
    rm -f "$out/notarize.zip"
    ok "Accepted"

    step "Stapling"
    xcrun stapler staple "$app" >"$out/staple.log" 2>&1 || { cat "$out/staple.log"; die "Stapling failed." }
    xcrun stapler validate -q "$app" >/dev/null || die "The stapled ticket does not validate."
    spctl --assess --type execute "$app" 2>/dev/null || die "Gatekeeper rejects the notarized app."
    ok "Stapled; Gatekeeper accepts it"
  fi
  print -r -- "$sha" >"$out/commit"
fi

[[ "$(info CFBundleIdentifier)" == "$bundle_id" ]] || die "The app's bundle ID is $(info CFBundleIdentifier), expected $bundle_id."
[[ "$(info CFBundleVersion)" == "$build" ]] || die "The app's build is $(info CFBundleVersion), expected $build."
[[ "$(info CFBundleShortVersionString)" == "$version" ]] || die "The app's version is $(info CFBundleShortVersionString), expected $version."
[[ "$(info SUFeedURL)" == "$feed_url" && "$(info SUPublicEDKey)" == "$public_key" ]] ||
  die "The app's Sparkle feed or key does not match this script's."
min_system=$(info LSMinimumSystemVersion)
[[ -n "$min_system" ]] || die "The app has no LSMinimumSystemVersion."

# --- Package ---------------------------------------------------------------------------------

step "Packaging"
zip="$out/$zip_name"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
signature=$("$sparkle_bin/sign_update" --account "$sparkle_account" -p "$zip") || die "sign_update failed."
"$sparkle_bin/sign_update" --account "$sparkle_account" --verify "$zip" "$signature" >/dev/null 2>&1 ||
  die "The zip's Sparkle signature does not verify."
length=$(stat -f %z "$zip")
ok "$zip_name: $length bytes, Sparkle-signed"

escape() {
  local text="$1"
  text=${text//&/&amp;}
  text=${text//</&lt;}
  text=${text//>/&gt;}
  print -r -- "$text"
}
summary="Based on Screendrop $base_version (build $base_build), built from $short_sha."
note_lines=()
for line in ${(f)notes}; do
  line=${line##[[:space:]]#}
  line=${line##[-*][[:space:]]##}
  [[ -n "$line" ]] && note_lines+=("$line")
done
html="<p>$(escape "$summary")</p>"
markdown="$summary"
if (( ${#note_lines} )); then
  html+="<ul>"
  markdown+=$'\n'
  for line in "${note_lines[@]}"; do
    html+="<li>$(escape "$line")</li>"
    markdown+=$'\n'"- $line"
  done
  html+="</ul>"
fi

release_page="https://github.com/$repo/releases/tag/$tag"
download_url="https://github.com/$repo/releases/download/$tag/$zip_name"
appcast="$out/$appcast_name"
cat >"$appcast" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Screendrop (axcellence fork)</title>
    <link>$feed_url</link>
    <language>en</language>
    <item>
      <title>Screendrop $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_system</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$release_page</sparkle:fullReleaseNotesLink>
      <description><![CDATA[$html]]></description>
      <enclosure url="$download_url" type="application/octet-stream" length="$length" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$appcast" 2>/dev/null || die "The appcast is not well-formed XML."
ok "$appcast_name written"

if $dry_run; then
  print -- "\nDry run finished. Nothing was published.\n  $zip\n  $appcast"
  exit 0
fi

# --- Publish ---------------------------------------------------------------------------------

retry() {
  local attempt
  for attempt in 1 2 3 4; do
    "$@" && return 0
    (( attempt < 4 )) && { print -u2 -- "    retrying in $(( attempt * 5 ))s…"; sleep $(( attempt * 5 )); }
  done
  return 1
}

step "Publishing $tag"
if ! gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
  retry gh release create "$tag" -R "$repo" --draft --target "$sha" \
    --title "Screendrop $version" --notes "$markdown" >/dev/null || die "Creating the draft release failed."
  ok "Draft created"
fi
retry gh release upload "$tag" "$zip" "$appcast" -R "$repo" --clobber || die "Uploading the release files failed."
ok "Files uploaded"
retry gh release edit "$tag" -R "$repo" --draft=false --latest >/dev/null || die "Publishing the release failed."
ok "Published: $release_page"

# --- Check what the updater will see ----------------------------------------------------------

step "Checking the published feed and download"
fetched="$out/fetched"
rm -rf "$fetched" && mkdir -p "$fetched"
seen=false
for attempt in {1..12}; do
  if curl -fsSL "$feed_url" -o "$fetched/$appcast_name" 2>/dev/null &&
    grep -q "<sparkle:version>$build</sparkle:version>" "$fetched/$appcast_name"; then
    seen=true
    break
  fi
  sleep 5
done
$seen || die "The feed at $feed_url does not list build $build yet. Check the release page."
ok "The feed lists build $build"
curl -fsSL "$download_url" -o "$fetched/$zip_name" || die "Downloading $download_url failed."
[[ "$(shasum -a 256 <"$fetched/$zip_name")" == "$(shasum -a 256 <"$zip")" ]] ||
  die "The downloaded $zip_name differs from the one built here."
ok "The download matches"
rm -rf "$fetched"

# Keep the newest release's files for reference; drop older ones.
for old in "$work"/fork-*(N/); do
  [[ "$old" == "$out" ]] || rm -rf "$old"
done

print -- "\nReleased Screendrop $version (build $build): $release_page"
