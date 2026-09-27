#!/usr/bin/env bash
# Install published Agent Dashboard artifacts. Compatible with macOS Bash 3.2.
set -euo pipefail

# Parse the complete piped script before doing any work.
main() {

REPOSITORY=5pecia1/agent-dashboard
API="https://api.github.com/repos/$REPOSITORY/releases"
BUNDLE_ID=io.github.5pecia1.mydashboard
TARGET=app
VERSION=
INCLUDE_PRERELEASE=0
DESTINATION=
REPLACE=0
DRY_RUN=0
SERVER_URL=
WORK=
APP_STAGE=
BACKUP=
EXISTING=
COMMITTED=0
LOCK=

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'USAGE'
Install Agent Dashboard from GitHub Releases (no source build).

  curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh | bash
  ... | bash -s -- app --version v0.1.1
  ... | bash -s -- server --prerelease --dir ./agent-dashboard-server
  ... | bash -s -- hooks --server-url https://YOUR_SERVER

Targets: app (default, macOS), server (Cloudflare project), hooks (server-owned setup).
  --version VERSION   Exact release; v/server-v prefix is optional. No fallback.
  --prerelease        Include prereleases when finding the latest release.
  --dir DIRECTORY     App parent directory (default ~/Applications), or server project
                      directory (default ./agent-dashboard-server).
  --replace           Replace an existing app, keeping a backup and existing settings.
  --dry-run           Resolve and verify the release without installing it.
  --server-url URL    HTTPS server origin for hooks. Its server determines the version.
  -h, --help          Show this help.

Latest means the first matching published release in GitHub's release list.
Server installation requires Node.js 22+ and npm; it does not deploy a Worker.
The app installer does not remove quarantine or bypass macOS security checks.
USAGE
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    app|server|hooks) TARGET=$1; shift ;;
    --version|--dir|--server-url)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 requires a value"
      case "$1" in --version) VERSION=$2 ;; --dir) DESTINATION=$2 ;; --server-url) SERVER_URL=$2 ;; esac
      shift 2 ;;
    --prerelease) INCLUDE_PRERELEASE=1; shift ;;
    --replace) REPLACE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1 (see --help)" ;;
  esac
done

cleanup() {
  if [ "$COMMITTED" -eq 0 ] && [ -n "$BACKUP" ] && [ -e "$BACKUP" ]; then
    if [ ! -e "$EXISTING" ]; then
      mv "$BACKUP" "$EXISTING" || log "Restore the preserved backup manually: $BACKUP"
    else
      log "Previous app preserved: $BACKUP"
    fi
  fi
  [ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null || true
  [ -z "$APP_STAGE" ] || rm -rf "$APP_STAGE"
  [ -z "$WORK" ] || rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
need() { command -v "$1" >/dev/null 2>&1 || fail "Required command missing: $1"; }
need curl
WORK=$(mktemp -d "${TMPDIR:-/tmp}/agent-dashboard-install.XXXXXX")
download() {
  # Public endpoints need no credentials. Never send a user's token to GitHub.
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 300 --retry 2 --output "$2" "$1" ||
    fail "Download failed: $1 (check the release, network, or GitHub API rate limit)"
  [ -s "$2" ] || fail "Empty download: $1"
}

if [ "$TARGET" = hooks ]; then
  [ -z "$VERSION$DESTINATION" ] && [ "$REPLACE" -eq 0 ] && [ "$INCLUDE_PRERELEASE" -eq 0 ] ||
    fail "hooks uses its server's version; --version, --prerelease, --dir and --replace do not apply"
  # Accept an origin only. Credentials, URL query strings and fragments must never reach logs.
  [[ "$SERVER_URL" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?/?$ ]] ||
    fail "--server-url must be an HTTPS origin, without credentials, path, query or fragment"
  download "${SERVER_URL%/}/setup.sh" "$WORK/setup.sh"
  bash -n "$WORK/setup.sh" || fail "Server returned an invalid setup script"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Verified setup script from ${SERVER_URL%/}/setup.sh; no hooks installed."
  else
    # setup.sh reads secrets from /dev/tty or MY_DASHBOARD_TOKEN, never pipe stdin.
    bash "$WORK/setup.sh" </dev/null
  fi
  exit 0
fi
[ -z "$SERVER_URL" ] || fail "--server-url applies only to hooks"
[ "$TARGET" = app ] || [ "$REPLACE" -eq 0 ] || fail "--replace applies only to app; server projects are never overwritten"

SYSTEM=$(uname -s)
if [ "$TARGET" = app ]; then
  [ "$SYSTEM" = Darwin ] || fail "The desktop app currently supports macOS only; use https://agent-dashboard.5pecia1.dev for the web app"
  for command in plutil ditto unzip zipinfo shasum; do need "$command"; done
  ARCH=$(uname -m)
  case "$ARCH" in arm64|x86_64) ;; *) fail "Unsupported macOS architecture: $ARCH" ;; esac
else
  for command in node npm tar; do need "$command"; done
  node -e 'if (+process.versions.node.split(".")[0] < 22) process.exit(1)' || fail "Server projects require Node.js 22 or newer"
fi

# macOS ships plutil; the app needs no Python, Node, Xcode, Flutter, or Rust.
# plutil's raw representation of an array is its length, mirrored by Node below.
json_get() {
  if [ "$SYSTEM" = Darwin ]; then
    plutil -extract "$2" raw "$1" 2>/dev/null
  else
    node -e 'try { let v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      for (const k of process.argv[2].split(".")) v = v[k];
      if (v === undefined || v === null) process.exit(1);
      console.log(Array.isArray(v) ? v.length : typeof v === "object" ? "" : v);
    } catch (_) { process.exit(1); }' "$1" "$2"
  fi
}
# A top-level release array is temporarily wrapped to use the same dotted paths.
valid_tag() {
  if [ "$TARGET" = app ]; then
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
  else
    [[ "$1" =~ ^server-v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
  fi
}
if [ -n "$VERSION" ]; then
  if [ "$TARGET" = app ]; then TAG="v${VERSION#v}"; else TAG="server-v${VERSION#server-v}"; fi
  valid_tag "$TAG" || fail "Invalid $TARGET version: $VERSION"
  download "$API/tags/$TAG" "$WORK/github-release.json"
  [ "$(json_get "$WORK/github-release.json" tag_name)" = "$TAG" ] || fail "Release tag differs from the requested version"
  [ "$(json_get "$WORK/github-release.json" draft)" = false ] || fail "Draft releases cannot be installed"
else
  TAG=
  page=1
  while [ "$page" -le 10 ] && [ -z "$TAG" ]; do
    download "$API?per_page=100&page=$page" "$WORK/list.json"
    { printf '{"releases":'; cat "$WORK/list.json"; printf '}\n'; } > "$WORK/page.json"
    count=$(json_get "$WORK/page.json" releases) || fail "Invalid GitHub releases response"
    [[ "$count" =~ ^[0-9]+$ ]] || fail "Invalid GitHub releases response"
    index=0
    while [ "$index" -lt "$count" ]; do
      candidate=$(json_get "$WORK/page.json" "releases.$index.tag_name") || fail "Release tag missing"
      if valid_tag "$candidate" && [ "$(json_get "$WORK/page.json" "releases.$index.draft")" = false ]; then
        prerelease=$(json_get "$WORK/page.json" "releases.$index.prerelease")
        version_part=${candidate#server-v}; version_part=${version_part#v}
        if [ "$INCLUDE_PRERELEASE" -eq 1 ] || { [ "$prerelease" = false ] && [[ "$version_part" != *-* ]]; }; then
          TAG=$candidate
          break
        fi
      fi
      index=$((index + 1))
    done
    [ "$count" -eq 100 ] || break
    page=$((page + 1))
  done
  [ -n "$TAG" ] || fail "No matching $TARGET release found; use --prerelease if only preview releases exist"
  # Freeze the selected tag once; never use mutable /latest/download URLs.
  download "$API/tags/$TAG" "$WORK/github-release.json"
  [ "$(json_get "$WORK/github-release.json" tag_name)" = "$TAG" ] || fail "Selected release changed"
fi
BASE="https://github.com/$REPOSITORY/releases/download/$TAG"
log "Selected $TARGET release: $TAG"
has_asset() {
  local index=0 count
  count=$(json_get "$WORK/github-release.json" assets) || return 1
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  while [ "$index" -lt "$count" ]; do
    [ "$(json_get "$WORK/github-release.json" "assets.$index.name")" != "$1" ] || return 0
    index=$((index + 1))
  done
  return 1
}
asset() {
  has_asset "$1" || fail "Release $TAG does not provide $1; choose a release that contains this installer artifact"
  download "$BASE/$1" "$WORK/$1"
}
digest() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else node -e 'console.log(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$1"; fi
}
checksum() {
  local expected
  expected=$(awk -v name="$1" '$2 == name {print $1}' "$2")
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "Missing or ambiguous SHA256 for $1"
  [ "$(digest "$WORK/$1")" = "$expected" ] || fail "SHA256 mismatch for $1"
  printf '%s\n' "$expected"
}
canonical_dir() {
  local input=$1 component resolved=/
  local parts
  [[ "$input" = /* ]] || input="$PWD/$input"
  IFS=/ read -r -a parts <<< "$input"
  for component in "${parts[@]}"; do
    case "$component" in ''|.) continue ;; ..) resolved=$(dirname "$resolved"); continue ;; esac
    resolved="${resolved%/}/$component"
    if [ -d "$resolved" ]; then resolved=$(cd "$resolved" && pwd -P); fi
  done
  printf '%s\n' "$resolved"
}
acquire_lock() {
  mkdir -p "$(dirname "$1")"
  if ! mkdir "$1" 2>/dev/null; then fail "Another installation may be running (lock: $1). Retry after it finishes; remove a stale lock only after checking no installer is running"; fi
  LOCK=$1
}
safe_name() {
  # Release builders use portable ASCII names; exclude control/glob characters.
  [[ "$1" =~ ^[A-Za-z0-9\ /._+@()-]+$ ]] &&
    [[ "$1" != /* && "$1" != *//* && "/$1/" != */../* && "/$1/" != */./* ]]
}

if [ "$TARGET" = server ]; then
  VERSION=${TAG#server-v}
  FILE="agent-dashboard-server-$VERSION-starter.tar.gz"
  asset "$FILE.sha256"
  asset "$FILE"
  checksum "$FILE" "$WORK/$FILE.sha256" >/dev/null
  tar -tzf "$WORK/$FILE" > "$WORK/members" || fail "Invalid server archive"
  tar -tvzf "$WORK/$FILE" > "$WORK/modes" || fail "Invalid server archive"
  [ -s "$WORK/members" ] || fail "Empty server archive"
  while IFS= read -r name; do
    safe_name "$name" && [[ "$name" = agent-dashboard-server/* ]] || fail "Unsafe server archive path"
  done < "$WORK/members"
  # Starter packages contain no symlinks, hardlinks, devices or special entries.
  LC_ALL=C awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" {exit 1}' "$WORK/modes" || fail "Unsafe server archive entry"
  mkdir "$WORK/extracted"
  tar -xzf "$WORK/$FILE" -C "$WORK/extracted" || fail "Cannot extract server archive"
  PROJECT="$WORK/extracted/agent-dashboard-server"
  MANIFEST="$PROJECT/starter-manifest.json"
  [ "$(json_get "$MANIFEST" schema)" = 1 ] && [ "$(json_get "$MANIFEST" product)" = 'Agent Dashboard' ] &&
    [ "$(json_get "$MANIFEST" tag)" = "$TAG" ] && [ "$(json_get "$MANIFEST" server_version)" = "$VERSION" ] || fail "Server starter metadata does not match $TAG"
  PACKAGE=$(json_get "$MANIFEST" package_file)
  safe_name "$PACKAGE" && [[ "$PACKAGE" = vendor/*.tgz ]] || fail "Unsafe server package path"
  PACKAGE_HASH=$(json_get "$MANIFEST" package_sha256) || fail "Server package SHA256 is missing"
  [[ "$PACKAGE_HASH" =~ ^[0-9a-f]{64}$ ]] || fail "Invalid server package SHA256"
  [ -f "$PROJECT/$PACKAGE" ] && [ ! -L "$PROJECT/$PACKAGE" ] && [ -s "$PROJECT/$PACKAGE" ] || fail "Bundled server package is missing"
  ACTUAL_HASH=$(digest "$PROJECT/$PACKAGE") || fail "Cannot read bundled server package"
  [ "$ACTUAL_HASH" = "$PACKAGE_HASH" ] || fail "Bundled server package SHA256 mismatch"
  SOURCE_COMMIT=$(json_get "$MANIFEST" source_commit) || fail "Server source commit is missing"
  [[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "Invalid server source commit"
  [ -f "$PROJECT/package.json" ] && [ -f "$PROJECT/package-lock.json" ] && [ -f "$PROJECT/wrangler.jsonc" ] || fail "Incomplete server starter"
  DESTINATION=$(canonical_dir "${DESTINATION:-./agent-dashboard-server}")
  if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then fail "Destination exists; choose a new --dir (existing server projects are never overwritten)"; fi
  if [ "$DRY_RUN" -eq 1 ]; then log "Verified $FILE; would create $DESTINATION. No files installed."; exit 0; fi
  acquire_lock "$DESTINATION.install-lock"
  [ ! -e "$DESTINATION" ] && [ ! -L "$DESTINATION" ] || fail "Destination appeared during installation; existing project preserved"
  # Stage beside the destination so the final rename stays on the same filesystem.
  APP_STAGE=$(mktemp -d "$(dirname "$DESTINATION")/.agent-dashboard-server.XXXXXX")
  cp -R "$PROJECT" "$APP_STAGE/project"
  mv "$APP_STAGE/project" "$DESTINATION"
  log "Server project installed: $DESTINATION"
  log "Next: cd into that directory, run npm ci, then follow its README.md to create D1 and deploy."
  exit 0
fi

asset release.json
RELEASE_METADATA="$WORK/release.json"
# Discover the architecture-specific artifact from the trusted release receipt.
[ "$(json_get "$RELEASE_METADATA" schema)" = 1 ] &&
  [ "$(json_get "$RELEASE_METADATA" product)" = 'Agent Dashboard' ] &&
  [ "$(json_get "$RELEASE_METADATA" tag)" = "$TAG" ] &&
  [ "$(json_get "$RELEASE_METADATA" version)" = "${TAG#v}" ] || fail "App release metadata does not match $TAG"
FILE=
EXPECTED_HASH=
count=$(json_get "$RELEASE_METADATA" artifacts)
index=0
while [ "$index" -lt "$count" ]; do
  if [ "$(json_get "$RELEASE_METADATA" "artifacts.$index.platform")" = macos ]; then
    release_arch=$(json_get "$RELEASE_METADATA" "artifacts.$index.arch")
    if [ "$release_arch" = "$ARCH" ] || [ "$release_arch" = universal ]; then
      FILE=$(json_get "$RELEASE_METADATA" "artifacts.$index.file")
      EXPECTED_HASH=$(json_get "$RELEASE_METADATA" "artifacts.$index.sha256")
      SIGNING=$(json_get "$RELEASE_METADATA" "artifacts.$index.signing")
      break
    fi
  fi
  index=$((index + 1))
done
[ -n "$FILE" ] || fail "Release $TAG has no macOS $ARCH build"
[ "$FILE" = "agent-dashboard-$TAG-macos-$release_arch.zip" ] || fail "Unexpected app artifact filename"
[[ "$EXPECTED_HASH" =~ ^[0-9a-f]{64}$ ]] || fail "Invalid app artifact SHA256"
asset SHA256SUMS
asset "$FILE"
ACTUAL_HASH=$(checksum "$FILE" "$WORK/SHA256SUMS") || fail "App checksum verification failed"
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || fail "Release metadata and SHA256SUMS differ"
unzip -tq "$WORK/$FILE" >/dev/null || fail "Invalid app ZIP archive"
zipinfo -1 "$WORK/$FILE" > "$WORK/members" || fail "Cannot read app ZIP"
while IFS= read -r name; do
  safe_name "$name" || fail "Unsafe app archive path"
  case "$name" in 'Agent Dashboard.app/'*|'__MACOSX/'*) ;; *) fail "Unexpected file outside the app bundle" ;; esac
done < "$WORK/members"
# Framework links point down into Versions/Current (or Current -> A). Reject
# parent traversal even for links, before ditto writes any entry to disk.
zipinfo -l "$WORK/$FILE" > "$WORK/zipinfo"
LC_ALL=C awk '/^[dl-][rwx-]{9} / {type=substr($0,1,1); for(i=1;i<=9;i++) sub(/^[^ ]+ +/, ""); print type "\t" $0}' "$WORK/zipinfo" > "$WORK/types"
[ "$(wc -l < "$WORK/types" | tr -d ' ')" = "$(wc -l < "$WORK/members" | tr -d ' ')" ] || fail "Unsupported app ZIP entry or permissions"
[ -s "$WORK/types" ] || fail "Empty app archive"
LC_ALL=C awk '/^[dl-][rwx-]{9} / {size += $4; count++} END {if(size > 1073741824 || count > 50000) exit 1}' "$WORK/zipinfo" || fail "App archive exceeds installation limits"
[ -z "$(sort "$WORK/members" | uniq -d)" ] || fail "Duplicate app archive entries"
while IFS=$'\t' read -r kind name; do
  if [ "$kind" = l ]; then
    link=$(unzip -p "$WORK/$FILE" "$name") || fail "Cannot read app symlink"
    safe_name "$link" || fail "Unsafe app symlink"
  fi
done < "$WORK/types"
mkdir "$WORK/extracted"
ditto -x -k "$WORK/$FILE" "$WORK/extracted" || fail "Cannot extract app ZIP"
APP="$WORK/extracted/Agent Dashboard.app"
INFO="$APP/Contents/Info.plist"
[ "$(plutil -extract CFBundleIdentifier raw "$INFO")" = "$BUNDLE_ID" ] &&
  [ "$(plutil -extract CFBundleShortVersionString raw "$INFO")" = "${TAG#v}" ] || fail "Downloaded app identity or version differs"
case "$SIGNING" in
  signed|ad-hoc) codesign --verify --deep --strict "$APP" || fail "App code signature verification failed" ;;
  unsigned) log "This release is unsigned; macOS will require explicit approval." ;;
  *) fail "Unrecognized app signing metadata" ;;
esac
EXECUTABLE=$(plutil -extract CFBundleExecutable raw "$INFO")
safe_name "$EXECUTABLE" && [[ "$EXECUTABLE" != */* ]] && [ -x "$APP/Contents/MacOS/$EXECUTABLE" ] || fail "Downloaded app executable is missing"
DESTINATION=$(canonical_dir "${DESTINATION:-$HOME/Applications}")
if [ "$DRY_RUN" -eq 0 ]; then acquire_lock "$DESTINATION/.agent-dashboard.install-lock"; fi
EXISTING=
for candidate in "$DESTINATION/Agent Dashboard.app" "$DESTINATION/my_dashboard.app" \
  "$HOME/Applications/Agent Dashboard.app" "$HOME/Applications/my_dashboard.app" \
  '/Applications/Agent Dashboard.app' '/Applications/my_dashboard.app'; do
  [ -d "$candidate" ] || continue
  candidate=$(canonical_dir "$candidate")
  [ "$(plutil -extract CFBundleIdentifier raw "$candidate/Contents/Info.plist" 2>/dev/null || true)" = "$BUNDLE_ID" ] || continue
  [ -z "$EXISTING" ] || [ "$candidate" = "$EXISTING" ] || fail "Multiple Agent Dashboard installations exist; choose one location and remove duplicates before installing"
  EXISTING=$candidate
done
if [ "$DRY_RUN" -eq 1 ]; then
  log "Verified $FILE; installation directory: $DESTINATION. No files installed."
  [ -z "$EXISTING" ] || log "Existing app: $EXISTING (installation requires --replace)."
  exit 0
fi
if [ -n "$EXISTING" ]; then
  [ "$REPLACE" -eq 1 ] || fail "Existing app: $EXISTING. Quit it and rerun with --replace to keep a backup and replace it"
  existing_executable=$(plutil -extract CFBundleExecutable raw "$EXISTING/Contents/Info.plist")
  # Match a literal executable path; pgrep treats bundle names as a regex.
  # shellcheck disable=SC2009
  if ps -axo comm= | grep -Fx "$EXISTING/Contents/MacOS/$existing_executable" >/dev/null; then
    fail "Agent Dashboard is running. Quit it before replacing the app"
  fi
  [ "$(dirname "$EXISTING")" = "$DESTINATION" ] || fail "Existing app: $EXISTING. Use --dir '$(dirname "$EXISTING")' --replace to avoid a duplicate installation"
fi
FINAL="$DESTINATION/Agent Dashboard.app"
if { [ -e "$FINAL" ] || [ -L "$FINAL" ]; } && [ "$FINAL" != "$EXISTING" ]; then fail "Destination is occupied by an unrelated file: $FINAL"; fi
mkdir -p "$DESTINATION"
APP_STAGE=$(mktemp -d "$DESTINATION/.agent-dashboard-app.XXXXXX")
ditto "$APP" "$APP_STAGE/Agent Dashboard.app" || fail "Cannot stage app; existing installation was preserved"
BACKUP=
if [ -n "$EXISTING" ]; then
  BACKUP="$EXISTING.backup-$(date -u +%Y%m%dT%H%M%SZ)"
  [ ! -e "$BACKUP" ] || fail "Backup already exists: $BACKUP"
  mv "$EXISTING" "$BACKUP" || fail "Cannot back up app; check directory permissions"
fi
if ! mv "$APP_STAGE/Agent Dashboard.app" "$FINAL"; then
  if [ -n "$BACKUP" ]; then mv "$BACKUP" "$EXISTING" || fail "Restore the preserved backup manually: $BACKUP"; fi
  fail "App replacement failed; previous installation restored"
fi
COMMITTED=1
log "Installed $TAG: $FINAL"
[ -z "$BACKUP" ] || log "Previous app preserved: $BACKUP"
log "Existing server settings are unchanged. Open the app in Finder; macOS may ask you to approve this unsigned/not-notarized release."

}
main "$@"
