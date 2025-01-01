#!/bin/bash
set -e
trap 'rm -rf "$TEMP_DIR" "$TEMP_SCRIPT"' EXIT

# Check if Script is Run as Non-Root
if [[ $EUID -eq 0 ]]; then
    echo "You must not be a root user to run this script, please run it as a regular user" >&2
    exit 1
fi

# Define constants
readonly TAR_FILE="/var/log/titus_log/install_log.tar.gz"
readonly DEFAULT_SCROLLBACK=2000
readonly KITTY_CONFIG="$HOME/.config/kitty/kitty.conf"

# Create temporary directory and script
TEMP_DIR=$(mktemp -d)
TEMP_SCRIPT=$(mktemp)

# Ensure log and timing files are available
LOGFILE="./install.log"
TIMING_FILE="./install.timing"

if [ ! -f "$LOGFILE" ] || [ ! -f "$TIMING_FILE" ]; then
    echo "Log and/or timing files not found. Attempting to extract from tar..."
    if [ ! -f "$TAR_FILE" ]; then
        echo "Error: Tar file not found at $TAR_FILE. Aborting."
        exit 1
    fi
    tar -xzf "$TAR_FILE" -C "$TEMP_DIR"
    LOGFILE="$TEMP_DIR/install.log"
    TIMING_FILE="$TEMP_DIR/install.timing"
    if [ ! -f "$LOGFILE" ] || [ ! -f "$TIMING_FILE" ]; then
        echo "Error: Log or timing file not found after extraction. Aborting."
        exit 1
    fi
    echo "Log and timing files extracted successfully."
else
    echo "Log and timing files found in the current directory."
fi

# Count lines and update scrollback_lines
LINE_COUNT=$(wc -l < "$LOGFILE")
NEW_SCROLLBACK_LINES=$((LINE_COUNT + 300))
echo "Setting Kitty scrollback_lines to $NEW_SCROLLBACK_LINES. This may increase memory usage."
sed -i.bak "s/^scrollback_lines.*/scrollback_lines $NEW_SCROLLBACK_LINES/" "$KITTY_CONFIG" || {
    echo "Error: Failed to update scrollback_lines in $KITTY_CONFIG."
    exit 1
}

# Detect terminal type
case "$TERM" in
    xterm-kitty) TERMINAL_TYPE="kitty" ;;
    *)
        if [ -t 1 ]; then
            TERMINAL_TYPE="tty"
        else
            TERMINAL_TYPE="unsupported"
        fi
    ;;
esac

# Define Kitty-specific logic
if [[ "$TERMINAL_TYPE" == "kitty" ]]; then
    cat << EOF > "$TEMP_SCRIPT"
#!/bin/bash
set -e

function set_kitty_resolution() {
    MONITOR_RESOLUTION=\$(xrandr | grep '*' | awk '{print \$1}' | sed 's/-.*//' | xargs)
    BASE_WIDTH=1920
    BASE_HEIGHT=1080
    BASE_FONT_SIZE=7
    NEW_COLUMNS="\${MONITOR_RESOLUTION%%x*}"
    NEW_LINES="\${MONITOR_RESOLUTION##*x}"
    FONT_SIZE=\$(( (NEW_COLUMNS * BASE_FONT_SIZE / BASE_WIDTH + NEW_LINES * BASE_FONT_SIZE / BASE_HEIGHT) / 2 ))
    (( FONT_SIZE < 1 )) && FONT_SIZE=1
    echo "Setting Kitty font size to \$FONT_SIZE based on monitor resolution (\$MONITOR_RESOLUTION)."
    kitty @ set-font-size "\$FONT_SIZE"
}

set_kitty_resolution
bspc node --focus last -t fullscreen

echo "Choose log replay method:"
echo "1) Replay with timing"
echo "2) Replay instantly"
read -p "Enter choice [1/2]: " replay_choice
case \$replay_choice in
    1) scriptreplay --timing="$TIMING_FILE" "$LOGFILE" ;;
    2) cat "$LOGFILE" ;;
    *) echo "Invalid choice. Exiting."
       exit 1 ;;
esac

# Reset scrollback_lines
sed -i.bak "s/^scrollback_lines.*/scrollback_lines $DEFAULT_SCROLLBACK/" "$KITTY_CONFIG"
echo "Press Enter to continue and restore scrollback_lines to $DEFAULT_SCROLLBACK lines."
read -r
EOF

    chmod +x "$TEMP_SCRIPT"
    kitty "$TEMP_SCRIPT"
elif [[ "$TERMINAL_TYPE" == "tty" ]]; then
    echo "Running in TTY. Replaying with timing..."
    scriptreplay --timing="$TIMING_FILE" "$LOGFILE"
else
    echo "Unsupported terminal type: $TERM. Please use Kitty or a TTY-compatible terminal."
    exit 1
fi
