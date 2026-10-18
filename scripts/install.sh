#!/usr/bin/env bash
#
# Dosely — build and install on your iPhone over Wi-Fi (or USB), no Xcode window needed.
#
#   ./scripts/install.sh                     build (Release) → install → launch
#   ./scripts/install.sh --device "Eric's iPhone"   pick a device by name, UDID or identifier
#   ./scripts/install.sh --list              show paired devices and how they're connected
#   ./scripts/install.sh --debug             Debug build instead of Release
#   ./scripts/install.sh --no-launch         install without opening the app
#   ./scripts/install.sh --clean             wipe the build folder first
#   ./scripts/install.sh --team ABCDE12345   set / change the signing team
#
# One-time prerequisites (done during the first install from Xcode):
#   • Xcode is signed in to your Apple ID (Xcode ▸ Settings ▸ Accounts)
#   • the iPhone has been paired with this Mac and has Developer Mode on
# After that the phone only needs to be awake, unlocked and on the same Wi-Fi network.
#
# Your data is kept: installing over the existing app preserves its database and alarms.
# Each install gets a new build number, which makes the app rebuild every alarm on next launch.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Dosely.xcodeproj"
SCHEME="Dosely"
BUILD_DIR="$ROOT/build"
DERIVED="$BUILD_DIR/DerivedData"
LOG="$BUILD_DIR/build.log"
LOCAL_XCCONFIG="$ROOT/Config/Local.xcconfig"
DEVICE_MEMORY="$BUILD_DIR/last-device"

CONFIGURATION="Release"
LAUNCH=1
CLEAN=0
LIST_ONLY=0
DEVICE_QUERY="${DOSELY_DEVICE:-}"
TEAM_ARG="${DOSELY_TEAM:-}"

# ── Output helpers ──────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
step() { printf "%s▸ %s%s\n" "$BOLD" "$*" "$RESET"; }
ok()   { printf "%s✓ %s%s\n" "$GREEN" "$*" "$RESET"; }
warn() { printf "%s! %s%s\n" "$YELLOW" "$*" "$RESET" >&2; }
die()  { printf "%s✗ %s%s\n" "$RED" "$*" "$RESET" >&2; exit 1; }

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ── Arguments ───────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device)   DEVICE_QUERY="${2:-}"; shift 2 ;;
    -l|--list)     LIST_ONLY=1; shift ;;
    --debug)       CONFIGURATION="Debug"; shift ;;
    --release)     CONFIGURATION="Release"; shift ;;
    --no-launch)   LAUNCH=0; shift ;;
    --clean)       CLEAN=1; shift ;;
    --team)        TEAM_ARG="${2:-}"; shift 2 ;;
    -h|--help)     usage ;;
    *)             die "Unknown option: $1 (try --help)" ;;
  esac
done

# ── Tooling checks ──────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || die "This script runs on a Mac."
command -v xcodebuild >/dev/null || die "xcodebuild not found. Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"
xcrun --find devicectl >/dev/null 2>&1 || die "devicectl not found — Xcode 15 or later is required (Xcode 26 for this project)."
command -v python3 >/dev/null || die "python3 not found (it ships with Xcode's command line tools: xcode-select --install)."
mkdir -p "$BUILD_DIR"

# ── Devices ─────────────────────────────────────────────────────────────────────
# Prints one tab-separated line per paired physical iPhone/iPad:
#   identifier  name  model  iOS  connection  udid
list_devices() {
  local json="$BUILD_DIR/devices.json"
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || die "Couldn't list devices (xcrun devicectl list devices)."
  python3 - "$json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for d in data.get("result", {}).get("devices", []):
    hw, dp, cp = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality", "physical") != "physical":
        continue
    if cp.get("pairingState") != "paired":
        continue
    transport, tunnel = cp.get("transportType") or "", cp.get("tunnelState") or ""
    if transport == "wired":
        conn = "USB"
    elif transport == "localNetwork":
        conn = "Wi-Fi"
    elif tunnel == "unavailable":
        conn = "not reachable"
    else:
        conn = "available"
    fields = [d.get("identifier"), dp.get("name") or "iPhone", hw.get("marketingName") or hw.get("productType"),
              dp.get("osVersionNumber"), conn, hw.get("udid")]
    # No empty fields: bash `read` collapses consecutive tabs.
    print("\t".join((str(f) if f else "-").replace("\t", " ") for f in fields))
PY
}

print_devices() {
  local rows="$1"
  if [[ -z "$rows" ]]; then
    echo "  (no paired devices — connect the iPhone by USB once and trust this Mac)"
    return
  fi
  local i=1
  while IFS=$'\t' read -r id name model os conn udid; do
    printf "  %d) %s%s%s  %s· %s · iOS %s · %s%s\n" "$i" "$BOLD" "$name" "$RESET" "$DIM" "$model" "$os" "$conn" "$RESET"
    i=$((i + 1))
  done <<< "$rows"
}

choose_device() {
  local rows matches count remembered=""
  rows="$(list_devices)"
  [[ -n "$rows" ]] || die "No paired iPhone found. Connect it by USB once, unlock it, and tap Trust — then Wi-Fi installs work."

  if [[ -n "$DEVICE_QUERY" ]]; then
    matches="$(awk -F'\t' -v q="$DEVICE_QUERY" 'BEGIN{lq=tolower(q)} tolower($2)==lq || $1==q || $6==q' <<< "$rows")"
    [[ -n "$matches" ]] || matches="$(awk -F'\t' -v q="$DEVICE_QUERY" 'BEGIN{lq=tolower(q)} index(tolower($2), lq)>0' <<< "$rows")"
    [[ -n "$matches" ]] || { echo "Paired devices:"; print_devices "$rows"; die "No device matches \"$DEVICE_QUERY\"."; }
  else
    [[ -f "$DEVICE_MEMORY" ]] && remembered="$(cat "$DEVICE_MEMORY")"
    matches=""
    [[ -n "$remembered" ]] && matches="$(awk -F'\t' -v q="$remembered" '$1==q' <<< "$rows")"
    [[ -n "$matches" ]] || matches="$rows"
  fi

  count="$(grep -c . <<< "$matches")"
  if [[ "$count" -gt 1 ]]; then
    # Prefer devices that are reachable right now.
    local reachable
    reachable="$(awk -F'\t' '$5=="USB" || $5=="Wi-Fi"' <<< "$matches")"
    if [[ -n "$reachable" && "$(grep -c . <<< "$reachable")" -eq 1 ]]; then
      matches="$reachable"
    elif [[ -t 0 ]]; then
      echo "Which device?"
      print_devices "$matches"
      local pick
      read -r -p "Number: " pick
      [[ "$pick" =~ ^[0-9]+$ ]] && [[ "$pick" -ge 1 && "$pick" -le "$count" ]] || die "Invalid choice."
      matches="$(sed -n "${pick}p" <<< "$matches")"
    else
      print_devices "$matches"
      die "Several devices are paired — pass --device \"Name\"."
    fi
  fi

  IFS=$'\t' read -r DEVICE_ID DEVICE_NAME DEVICE_MODEL DEVICE_OS DEVICE_CONN DEVICE_UDID <<< "$(head -n1 <<< "$matches")"
  echo "$DEVICE_ID" > "$DEVICE_MEMORY"
}

if [[ "$LIST_ONLY" -eq 1 ]]; then
  echo "Paired devices:"
  print_devices "$(list_devices)"
  exit 0
fi

# ── Signing ─────────────────────────────────────────────────────────────────────
detect_teams() {
  local tmp; tmp="$(mktemp -d)"
  security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | awk -v dir="$tmp" '/BEGIN CERTIFICATE/{n++} n>0 {print > (dir "/cert" n ".pem")}'
  for f in "$tmp"/cert*.pem; do
    [[ -f "$f" ]] || continue
    openssl x509 -noout -subject -in "$f" 2>/dev/null | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p'
  done | sort -u
  rm -rf "$tmp"
}

write_team() {
  local team="$1" bundle
  bundle="$(sed -nE 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$LOCAL_XCCONFIG" 2>/dev/null | tail -n1)"
  {
    echo "// Written by scripts/install.sh — your personal signing settings (not committed)."
    echo "DEVELOPMENT_TEAM = $team"
    [[ -n "$bundle" ]] && echo "PRODUCT_BUNDLE_IDENTIFIER = $bundle"
    [[ -n "${DOSELY_BUNDLE_ID:-}" && -z "$bundle" ]] && echo "PRODUCT_BUNDLE_IDENTIFIER = $DOSELY_BUNDLE_ID"
    true
  } > "$LOCAL_XCCONFIG"
  ok "Signing team $team saved to Config/Local.xcconfig"
}

ensure_signing() {
  if [[ -n "$TEAM_ARG" ]]; then
    [[ "$TEAM_ARG" =~ ^[A-Z0-9]{10}$ ]] || die "Team IDs are 10 characters, e.g. ABCDE12345."
    write_team "$TEAM_ARG"; return
  fi
  if grep -qE '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' "$LOCAL_XCCONFIG" 2>/dev/null; then return; fi
  if grep -qE 'DEVELOPMENT_TEAM = [A-Z0-9]{10};' "$PROJECT/project.pbxproj"; then return; fi   # set in Xcode's Signing tab

  step "Finding your signing team"
  local teams count
  teams="$(detect_teams)"
  count="$(grep -c . <<< "$teams" || true)"
  if [[ "$count" -eq 1 ]]; then
    write_team "$teams"
  elif [[ "$count" -gt 1 && -t 0 ]]; then
    echo "Several teams found:"; nl -w2 -s') ' <<< "$teams"
    local pick; read -r -p "Number: " pick
    write_team "$(sed -n "${pick}p" <<< "$teams")"
  else
    die "Couldn't detect a signing team. Run once with --team YOURTEAMID (find it in Xcode ▸ Settings ▸ Accounts, or developer.apple.com ▸ Membership)."
  fi
}

# ── Go ──────────────────────────────────────────────────────────────────────────
START=$(date +%s)
ensure_signing

step "Looking for your iPhone"
choose_device
ok "$DEVICE_NAME ($DEVICE_MODEL, iOS $DEVICE_OS) — $DEVICE_CONN"

if [[ "$CLEAN" -eq 1 ]]; then
  step "Cleaning"
  rm -rf "$DERIVED"
fi

BUILD_NUMBER="$(date +%Y%m%d%H%M)"
step "Building $CONFIGURATION (build $BUILD_NUMBER)"
BUILD_CMD=(xcodebuild
  -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION"
  -destination "generic/platform=iOS" -derivedDataPath "$DERIVED"
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  build)

set +e
if command -v xcbeautify >/dev/null; then
  "${BUILD_CMD[@]}" 2>&1 | tee "$LOG" | xcbeautify --quiet
  STATUS=${PIPESTATUS[0]}
else
  "${BUILD_CMD[@]}" > "$LOG" 2>&1
  STATUS=$?
fi
set -e

if [[ "$STATUS" -ne 0 ]]; then
  echo
  grep -E "error:|\*\* BUILD FAILED" "$LOG" | sed 's/^/  /' | head -n 25 || true
  if grep -qiE "No Account for Team|No accounts|sign in" "$LOG"; then
    warn "Xcode isn't signed in to the team. Open Xcode ▸ Settings ▸ Accounts once and sign in."
  elif grep -qiE "No profiles for|provisioning profile" "$LOG"; then
    warn "Provisioning failed. If the bundle ID is taken, set PRODUCT_BUNDLE_IDENTIFIER in Config/Local.xcconfig (e.g. com.yourname.dosely)."
  fi
  die "Build failed — full log: $LOG"
fi

APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/Dosely.app"
[[ -d "$APP" ]] || die "Built app not found at $APP"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
ok "Built $BUNDLE_ID"

step "Installing on $DEVICE_NAME"
if ! xcrun devicectl device install app --device "$DEVICE_ID" "$APP" > "$BUILD_DIR/install.log" 2>&1; then
  sed 's/^/  /' "$BUILD_DIR/install.log" | tail -n 15
  warn "Make sure the iPhone is unlocked, awake and on the same Wi-Fi as this Mac, with Developer Mode on."
  warn "If it was just restarted, unlock it once; if it still can't be found, plug it in by USB one time."
  die "Install failed — log: $BUILD_DIR/install.log"
fi
ok "Installed"

if [[ "$LAUNCH" -eq 1 ]]; then
  step "Launching"
  if xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" > "$BUILD_DIR/launch.log" 2>&1; then
    ok "Dosely is open on $DEVICE_NAME"
  else
    warn "Installed, but couldn't launch it (is the phone locked?). Open Dosely on the phone instead."
  fi
fi

printf "%sDone in %ss.%s\n" "$DIM" "$(( $(date +%s) - START ))" "$RESET"
