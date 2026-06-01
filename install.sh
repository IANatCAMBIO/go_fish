#!/usr/bin/env zsh
# install.sh — install go_fish as a user binary in ~/Applications.
#
# Usage:
#   ./install.sh              install or refresh using ./bin/go_fish
#   ./install.sh --build      compile from ./src first, then install
#                             (requires Xcode Command Line Tools)
#   ./install.sh uninstall    full teardown: stop process, remove the
#                             Login Items entry + any legacy LaunchAgent,
#                             remove binary
#
# Install does NOT register go_fish for startup — it runs as a normal
# foreground binary you launch yourself (`open ~/Applications/go_fish`
# or double-click). Auto-start at login is opt-in via the "Start at
# boot" menu item, which adds the binary to the per-user Login Items
# list (System Settings > General > Login Items) on demand.
#
# Build flow: `make` runs inside ./src (clang, pure Objective-C) and writes
# the binary to ./bin/go_fish. Install copies that file to
# ~/Applications/go_fish. No sudo required.

set -euo pipefail

LABEL="com.local.gofish"

SCRIPT_DIR="${0:A:h}"
SRC_DIR="${SCRIPT_DIR}/src"
LOCAL_BIN_DIR="${SCRIPT_DIR}/bin"
LOCAL_BIN="${LOCAL_BIN_DIR}/go_fish"

# User-writable, conventional spot for per-user apps/binaries.
INSTALL_DIR="${HOME}/Applications"
INSTALL_PATH="${INSTALL_DIR}/go_fish"

LAUNCHAGENT_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${LAUNCHAGENT_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs"
STDOUT_LOG="${LOG_DIR}/go_fish.out.log"
STDERR_LOG="${LOG_DIR}/go_fish.err.log"
SUPPORT_DIR="${HOME}/Library/Application Support/go_fish"

# --- argument parsing -------------------------------------------------
do_build=false
action="install"
for arg in "$@"; do
    case "${arg}" in
        --build)            do_build=true ;;
        install|uninstall)  action="${arg}" ;;
        -h|--help)
            sed -n '2,/^$/p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            echo "Usage: ${0:t} [--build] [install|uninstall]" >&2
            exit 2
            ;;
    esac
done

stop_running() {
    # Best-effort: unload any registered LaunchAgent (so it can't crash-restart
    # while we're swapping binaries), then kill any standalone process.
    if [[ -f "${PLIST_PATH}" ]]; then
        launchctl unload "${PLIST_PATH}" 2>/dev/null || true
    fi
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    pkill -f "${INSTALL_PATH}" 2>/dev/null || true
    pkill -x "go_fish" 2>/dev/null || true
}

case "${action}" in
install)
    if ${do_build}; then
        echo "Building ${LOCAL_BIN} from ${SRC_DIR}..."
        mkdir -p "${LOCAL_BIN_DIR}"
        ( cd "${SRC_DIR}" && make )
    fi
    if [[ ! -x "${LOCAL_BIN}" ]]; then
        echo "ERROR: ${LOCAL_BIN} not found or not executable." >&2
        echo "Run with --build to compile from source, or place a prebuilt" >&2
        echo "binary at that path before re-running." >&2
        exit 1
    fi

    # Ad-hoc sign in place so the signature travels with the file when we
    # copy it to ~/Applications. Note: ad-hoc re-signing on every build
    # changes the code identity, which makes macOS revoke previously-granted
    # Accessibility / Screen Recording. You'll need to re-approve in System
    # Settings after each build. The "Start at boot" backoff (3-attempt cap
    # inside the binary) keeps a missing grant from re-prompting every login.
    echo "Ad-hoc signing ${LOCAL_BIN}..."
    codesign --force --sign - "${LOCAL_BIN}"

    stop_running

    mkdir -p "${INSTALL_DIR}" "${LOG_DIR}" "${SUPPORT_DIR}"
    echo "Installing to ${INSTALL_PATH}..."
    cp "${LOCAL_BIN}" "${INSTALL_PATH}"
    chmod 755 "${INSTALL_PATH}"

    # Reset any stale attempt counter from a prior crash loop.
    : > "${SUPPORT_DIR}/attempts.txt"

    cat <<EOF

go_fish installed.
  binary:  ${INSTALL_PATH}
  logs:    ${STDERR_LOG}
           ${STDOUT_LOG}

To start it now:
  open ${INSTALL_PATH}
  (or double-click ${INSTALL_PATH} in Finder)

The first launch will prompt for Accessibility + Screen Recording
permissions. Grant both, then re-launch.

Toggle "Start at boot" from the menu-bar icon to have go_fish come
back automatically at login.

System Settings > Keyboard > Keyboard Shortcuts:
  - Disable Mission Control's Cmd+Tab
  - Disable "Move focus to next window in active app" (Cmd+\`)
  so go_fish gets the keystrokes first.

Uninstall: ${0:t} uninstall
EOF
    ;;

uninstall)
    echo "Stopping any running go_fish..."
    stop_running

    # Legacy: older versions registered a LaunchAgent. Remove it if present.
    if [[ -e "${PLIST_PATH}" ]]; then
        echo "Removing ${PLIST_PATH}"
        rm -f "${PLIST_PATH}"
    fi

    # Remove any Login Items entry the "Start at boot" toggle added. Best-effort
    # via System Events (may trigger a one-time Automation prompt for the
    # terminal; harmless to deny — you can also remove it by hand in
    # System Settings > General > Login Items).
    echo "Removing go_fish from Login Items (if present)..."
    osascript -e 'tell application "System Events" to delete (every login item whose name is "go_fish")' 2>/dev/null || true

    if [[ -e "${INSTALL_PATH}" ]]; then
        echo "Removing ${INSTALL_PATH}"
        rm -f "${INSTALL_PATH}"
    fi

    # Best-effort: also clean up the legacy /usr/local/bin install path
    # from earlier versions, so a fresh install can't be shadowed by a
    # stale binary on PATH.
    if [[ -e /usr/local/bin/go_fish ]]; then
        echo "Removing legacy /usr/local/bin/go_fish (sudo required)"
        sudo rm -f /usr/local/bin/go_fish || true
    fi

    if [[ -d "${SUPPORT_DIR}" ]]; then
        echo "Removing ${SUPPORT_DIR}"
        rm -rf "${SUPPORT_DIR}"
    fi

    # Logs: prompt, default no.
    if [[ -e "${STDOUT_LOG}" || -e "${STDERR_LOG}" ]]; then
        printf "Also remove logs at %s{out,err}.log? [y/N] " "${LOG_DIR}/go_fish."
        read -r ans
        case "${ans}" in
            y|Y|yes|YES) rm -f "${STDOUT_LOG}" "${STDERR_LOG}" ;;
            *) echo "Keeping logs." ;;
        esac
    fi

    echo "go_fish uninstalled."
    echo "(Accessibility / Screen Recording grants in System Settings remain"
    echo " until you remove them manually.)"
    ;;

*)
    echo "Usage: ${0:t} [--build] [install|uninstall]" >&2
    exit 2
    ;;
esac
