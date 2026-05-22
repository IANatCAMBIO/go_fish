#!/usr/bin/env zsh
# install.sh — install go-fish as a per-user LaunchAgent.
#
# Usage:
#   ./install.sh              install or refresh using ./bin/go-fish
#   ./install.sh --build      compile from ./src first, then install
#                             (requires Go + Xcode Command Line Tools)
#   ./install.sh uninstall    stop and remove
#
# Build flow: `go build` runs inside ./src and writes the binary to
# ./bin/go-fish. Install copies that file to /usr/local/bin/go-fish (the
# macOS-conventional location for user-installed binaries — /usr/bin is
# SIP-protected and not writable). The LaunchAgent plist goes in
# ~/Library/LaunchAgents and points at the system copy.
#
# Idempotent: re-running re-installs cleanly. The previous LaunchAgent is
# unloaded before the new binary is dropped in.

set -euo pipefail

LABEL="com.local.gofish"

SCRIPT_DIR="${0:A:h}"
SRC_DIR="${SCRIPT_DIR}/src"
LOCAL_BIN_DIR="${SCRIPT_DIR}/bin"
LOCAL_BIN="${LOCAL_BIN_DIR}/go-fish"

# /usr/bin is SIP-protected on macOS; /usr/local/bin is the standard
# location for user-installed binaries and is writable with sudo.
INSTALL_DIR="/usr/local/bin"
INSTALL_PATH="${INSTALL_DIR}/go-fish"

LAUNCHAGENT_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${LAUNCHAGENT_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs"
STDOUT_LOG="${LOG_DIR}/go-fish.out.log"
STDERR_LOG="${LOG_DIR}/go-fish.err.log"

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

unload_if_present() {
    if [[ -f "${PLIST_PATH}" ]]; then
        # Suppress errors: it's fine if it wasn't loaded.
        launchctl unload "${PLIST_PATH}" 2>/dev/null || true
    fi
}

case "${action}" in
install)
    if ${do_build}; then
        echo "Building ${LOCAL_BIN} from ${SRC_DIR}..."
        mkdir -p "${LOCAL_BIN_DIR}"
        ( cd "${SRC_DIR}" && go build -o "${LOCAL_BIN}" )
    fi
    if [[ ! -x "${LOCAL_BIN}" ]]; then
        echo "ERROR: ${LOCAL_BIN} not found or not executable." >&2
        echo "Run with --build to compile from source, or place a prebuilt" >&2
        echo "binary at that path before re-running." >&2
        exit 1
    fi

    # Ad-hoc sign in place. Doing this on the local copy means the
    # signature travels with the file to /usr/local/bin so we don't need a
    # second sudo'd codesign run there.
    echo "Ad-hoc signing ${LOCAL_BIN}..."
    codesign --force --sign - "${LOCAL_BIN}"

    mkdir -p "${LAUNCHAGENT_DIR}" "${LOG_DIR}"
    unload_if_present

    echo "Installing to ${INSTALL_PATH} (you'll be prompted for sudo)..."
    sudo mkdir -p "${INSTALL_DIR}"
    sudo cp "${LOCAL_BIN}" "${INSTALL_PATH}"
    sudo chmod 755 "${INSTALL_PATH}"

    echo "Writing LaunchAgent plist to ${PLIST_PATH}"
    cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${STDOUT_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${STDERR_LOG}</string>
</dict>
</plist>
EOF

    echo "Loading LaunchAgent..."
    launchctl load -w "${PLIST_PATH}"

    cat <<EOF

go-fish installed and running.
  binary:  ${INSTALL_PATH}
  plist:   ${PLIST_PATH}
  logs:    ${STDERR_LOG}
           ${STDOUT_LOG}

Next steps:
  1. System Settings > Privacy & Security > Accessibility
     and Screen Recording — make sure ${INSTALL_PATH} is enabled.
  2. On macOS 13+, System Settings > General > Login Items & Extensions
     — confirm go-fish is allowed in the background.
  3. System Settings > Keyboard > Keyboard Shortcuts —
     disable the system Cmd+Tab (Mission Control) and Cmd+\` ("Move focus
     to next window in active app") so go-fish gets the keystrokes first.

Useful commands:
  launchctl list | grep ${LABEL}
  tail -f ${STDERR_LOG}
  ${0:t} uninstall
EOF
    ;;

uninstall)
    # Stop any running instance. Try both the legacy (unload) and modern
    # (bootout) paths; either may already be a no-op, which is fine.
    if [[ -e "${PLIST_PATH}" ]]; then
        echo "Unloading LaunchAgent..."
        launchctl unload "${PLIST_PATH}" 2>/dev/null || true
    fi
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true

    # Remove the plist unconditionally — rm -f is a no-op if it's missing,
    # and this catches edge cases where a previous run left it orphaned.
    if [[ -e "${PLIST_PATH}" ]]; then
        echo "Removing ${PLIST_PATH}"
    fi
    rm -f "${PLIST_PATH}"

    # Remove the system binary.
    if [[ -e "${INSTALL_PATH}" ]]; then
        echo "Removing ${INSTALL_PATH} (you'll be prompted for sudo)"
        sudo rm -f "${INSTALL_PATH}"
    fi

    echo "go-fish uninstalled."
    echo "(Accessibility / Screen Recording grants in System Settings remain"
    echo " until you remove them manually.)"
    ;;

*)
    echo "Usage: ${0:t} [--build] [install|uninstall]" >&2
    exit 2
    ;;
esac
