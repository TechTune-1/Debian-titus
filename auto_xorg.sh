#!/bin/bash

# Text color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if Script is Run as Root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Error:${NC} You must be a root user to run this script. Please use ${YELLOW}sudo ./install.sh${NC}" >&2
  exit 1
fi

# Determine the username
username=$(getent passwd ${SUDO_USER:-$USER} | cut -d: -f1)
if [[ -z "$username" ]]; then
  echo -e "${RED}Error:${NC} Unable to determine the username." >&2
  exit 1
fi

# Run commands as non-root user
non_root() {
    local command="$1"
    runuser -u "${username}" -- bash -c "$command"
}

# Directories
readonly config_file="/etc/X11/xorg.conf.d/10-monitor.conf"
readonly screen_layout_dir="/home/$username/.screenlayout"
mkdir -p "$(dirname "$config_file")"

# Ask for ARandR configuration
echo -e "${BLUE}Do you want to set ARandR configuration?${NC} (Y/n): "
read -r set_arandr

set_arandr=${set_arandr:-y}
if [[ "${set_arandr,,}" == "y" ]]; then
    # Check RandR version
    version=$(xrandr --version 2>/dev/null | grep -oP '(?<=version )\d+\.\d+')

    if [[ $? -ne 0 || -z "$version" ]]; then
        echo "RandR version couldn't be detected, continuing..."
        version="unknown"
    else
        major_version=$(echo $version | cut -d. -f1)
        minor_version=$(echo $version | cut -d. -f2)
    fi

    function compare_versions {
        if [[ $1 -lt $2 ]]; then
            echo "less"
        elif [[ $1 -eq $2 ]]; then
            echo "equal"
        else
            echo "greater"
        fi
    }

    if [[ "$version" != "unknown" ]]; then
        result_major=$(compare_versions $major_version 1)
        result_minor=$(compare_versions $minor_version 2)

        if [[ $result_major == "less" ]] || [[ $result_major == "equal" && $result_minor == "less" ]]; then
            echo "Warning: Your RandR version is less than 1.2. Not all options might be supported."
            read -p "Do you want to exit? (y/n): " answer
            if [[ $answer == "y" || $answer == "Y" ]]; then
                echo "Exiting..."
                exit 1
            else
                echo "Continuing..."
            fi
        else
            echo "Your RandR version is $version, which supports RandR 1.2 or higher. You're good to go!"
        fi
    else
        echo "Skipping version comparison due to failure in detecting RandR version."
    fi
fi

if [[ "${set_arandr,,}" == "y" ]]; then
  echo -e "${GREEN}This script configures your display setup using ARandR.${NC}"
  echo -e "1. ARandR will open. Please save your layout to ${YELLOW}\$HOME/.screenlayout${NC} directory."
  echo -e "2. Save by clicking ${YELLOW}Layout -> Save As${NC}."
  echo -e "3. After saving, click ${YELLOW}Layout -> Quit${NC}."
  echo -e "Press Enter to continue..."
  read -r

  if [ -n "$DISPLAY" ]; then
    echo -e "${BLUE}Launching ARandR...${NC}"
    non_root "arandr &"
    sleep 1
    bspc node --focus last -t fullscreen

    while pgrep -u "${username}" -x "arandr" > /dev/null; do sleep 1; done
  else
    echo -e "${YELLOW}bspwm is not running.${NC} Setting up temporary configuration..."
    cat > /tmp/bspwmrc_arandr << EOF
#!/bin/sh
xsetroot -cursor_name left_ptr
setxkbmap -layout us
bspc config remove_unplugged_monitors true
bspc config remove_disabled_monitors true
bspc monitor -d 1 2 3 4 5 6 7 8 9 10
EOF
    # Find an unused virtual terminal
    VT=$(fgconsole)
    NEW_VT=$((VT + 1))
    if [[ "$NEW_VT" -gt 6 ]]; then
        NEW_VT=1
    fi

    chmod +x /tmp/bspwmrc_arandr
    # Start Xorg on a new VT
    Xorg :1 vt$NEW_VT -nolisten tcp 2>&1 &
    XORG_PID=$!
    sleep 2

    if ! ps -p "$XORG_PID" > /dev/null; then
        echo -e "${RED}Failed to start Xorg session. Check /var/log/Xorg.*.log for details.${NC}"
        exit 1
    fi

    export DISPLAY=:1
    export XAUTHORITY=$HOME/.Xauthority

    bspwm -c /tmp/bspwmrc_arandr &
    echo -e "${BLUE}Launching ARandR...${NC}"
    non_root "arandr &"
    sleep 1
    bspc node --focus last -t fullscreen

    while pgrep -u "${username}" -x "arandr" > /dev/null; do sleep 1; done
    systemctl stop lightdm --no-block || true
    pkill -f Xorg
    pkill -f bspwm
    unset DISPLAY
    unset XAUTHORITY
  fi

  recent_file=$(find "$screen_layout_dir" -type f -name "*.sh" ! -name "$(basename "$0")" -print0 | xargs -0 ls -t | head -n 1)
  if [ -n "$recent_file" ]; then
      echo -e "${GREEN}Using configuration from most recent file:${YELLOW} $recent_file"
      xrandr_command=$(sed '1d' "$recent_file")
  else
      echo -e "${RED}No readable .sh files found in $screen_layout_dir.${NC}"
      exit 1
  fi

# Regex for parsing xrandr commands
regex='--output ([^ ]+)( --primary)?( --mode ([^ ]+))?( --pos ([^ ]+))?( --rotate ([^ ]+))?( --off)?'

declare -A remove_monitors
declare -A add_monitors
primary_monitor=""

if [[ $xrandr_command =~ --off ]]; then
    echo -e "${BLUE}Do you want to remove all inactive (--off) monitors?${NC} (Y/n): "
    read -r remove_off_choice
    remove_off=false
    if [[ "${remove_off_choice,,}" == "y" ]]; then
        remove_off=true
    fi
fi

while [[ $xrandr_command =~ $regex ]]; do
    output=${BASH_REMATCH[1]}
    primary=${BASH_REMATCH[2]}
    mode=${BASH_REMATCH[4]}
    pos=${BASH_REMATCH[6]}
    rotate=${BASH_REMATCH[8]}
    off=${BASH_REMATCH[9]}

    if [[ $off == " --off" ]]; then
        if [[ $remove_off == true ]]; then
            echo -e "${YELLOW}Marking monitor for removal:${NC} $output"
            remove_monitors["$output"]=true
        else
            echo -e "${YELLOW}Skipping monitor marked as --off:${NC} $output"
        fi
    else
        echo -e "${BLUE}Configuring monitor:${NC} $output"
        add_monitors["$output"]="$mode $pos $rotate"
        if [[ $primary == " --primary" ]]; then
            primary_monitor="$output"
        fi
    fi
    xrandr_command=${xrandr_command#*--output $output}
done

# Read the config file into an array
if [ -f "$config_file" ]; then
    mapfile -t file_lines < "$config_file"
else
    file_lines=()
fi

# Process the config file
modified_lines=()
in_section=false
current_output=""
current_section=()

for line in "${file_lines[@]}"; do
    if [[ $line == Section* && $line == *"Monitor"* ]]; then
        in_section=true
        current_output=""
        current_section=("$line")
        has_primary_flag=false
    elif [[ $in_section == true && $line == *Identifier* ]]; then
        current_output=$(echo "$line" | awk -F\" '{print $2}')
        current_section+=("$line")
    elif [[ $in_section == true && $line == *"Option \"Primary\""* ]]; then
        has_primary_flag=true
        current_section+=("$line")
    elif [[ $in_section == true && $line == EndSection* ]]; then
        current_section+=("$line")

        if [[ ${remove_monitors["$current_output"]} == true ]]; then
            echo "Removing section for monitor: $current_output"
        else
            if [[ ${add_monitors["$current_output"]} ]]; then
                echo -e "${GREEN}Modifying section for monitor:${NC} $current_output"
                new_section=()
                mode=${add_monitors["$current_output"]%% *}
                pos=$(echo ${add_monitors["$current_output"]} | awk '{print $2}')
                rotate=$(echo ${add_monitors["$current_output"]} | awk '{print $3}')
                found_mode=false
                found_pos=false
                found_rotate=false

                for section_line in "${current_section[@]}"; do
                    if [[ $section_line == *"Option \"PreferredMode\""* ]]; then
                        if [[ -n "$mode" ]]; then
                            new_section+=("    Option \"PreferredMode\" \"$mode\"")
                            found_mode=true
                        else
                            new_section+=("$section_line")
                        fi
                    elif [[ $section_line == *"Option \"Position\""* ]]; then
                        if [[ -n "$pos" ]]; then
                            new_section+=("    Option \"Position\" \"${pos//x/ }\"")
                            found_pos=true
                        else
                            new_section+=("$section_line")
                        fi
                    elif [[ $section_line == *"Option \"Rotate\""* ]]; then
                        if [[ -n "$rotate" ]]; then
                            new_section+=("    Option \"Rotate\" \"$rotate\"")
                            found_rotate=true
                        else
                            new_section+=("$section_line")
                        fi
                    elif [[ $section_line == *"Option \"Primary\""* ]]; then
                        if [[ "$current_output" == "$primary_monitor" ]]; then
                            new_section+=("    Option \"Primary\" \"true\"")
                        fi
                        has_primary_flag=true
                    elif [[ $section_line == "EndSection" ]]; then
                        if [[ "$current_output" == "$primary_monitor" && $has_primary_flag == false ]]; then
                            new_section+=("    Option \"Primary\" \"true\"")
                        fi
                        new_section+=("$section_line")
                    else
                        new_section+=("$section_line")
                    fi
                done

                if [[ -n "$mode" && $found_mode == false ]]; then
                    new_section+=("    Option \"PreferredMode\" \"$mode\"")
                fi
                if [[ -n "$pos" && $found_pos == false ]]; then
                    new_section+=("    Option \"Position\" \"${pos//x/ }\"")
                fi
                if [[ -n "$rotate" && $found_rotate == false ]]; then
                    new_section+=("    Option \"Rotate\" \"$rotate\"")
                fi

                modified_lines+=("${new_section[@]}")
            else
                modified_lines+=("${current_section[@]}")
            fi
        fi

        in_section=false
        current_section=()
    elif [[ $in_section == true ]]; then
        current_section+=("$line")
    else
        modified_lines+=("$line")
    fi
done

# Add new sections for monitors that weren't already in the file
for monitor in "${!add_monitors[@]}"; do
    if [[ ! ${remove_monitors["$monitor"]} && ! " ${file_lines[*]} " =~ "$monitor" ]]; then
        echo -e "${GREEN}Adding new section for monitor:${NC} $monitor"
        new_section="Section \"Monitor\"
    Identifier \"$monitor\""
        mode=${add_monitors["$monitor"]%% *}
        pos=$(echo ${add_monitors["$monitor"]} | awk '{print $2}')
        rotate=$(echo ${add_monitors["$monitor"]} | awk '{print $3}')
        [[ -n "$mode" ]] && new_section+="
    Option \"PreferredMode\" \"$mode\""
        [[ -n "$pos" ]] && new_section+="
    Option \"Position\" \"${pos//x/ }\""
        [[ -n "$rotate" ]] && new_section+="
    Option \"Rotate\" \"$rotate\""
        if [[ "$monitor" == "$primary_monitor" ]]; then
            new_section+="
    Option \"Primary\" \"true\""
        fi

        new_section+="
EndSection"

        if [[ ${#modified_lines[@]} -ne 0 && -n "${modified_lines[-1]}" ]]; then
            modified_lines+=("")
        fi
        modified_lines+=("$new_section")
    fi
done

# Write to the config file
trimmed_lines=()
for line in "${modified_lines[@]}"; do
    if [[ -n "$line" || (${#trimmed_lines[@]} -ne 0 && -n "${trimmed_lines[-1]}") ]]; then
        trimmed_lines+=("$line")
    fi
done

printf "%s\n" "${trimmed_lines[@]}" > "$config_file"

echo -e "${BLUE}Configuration has been updated successfully to ${YELLOW}$config_file.${NC}"

if [ -n "$recent_file" ]; then
    echo -e "${BLUE}Do you want to remove the screen layout file ${YELLOW}$recent_file? ${NC}(Y/n): "
    read -r remove_choice
    remove_choice=${remove_choice:-y}

    case "$remove_choice" in
        [Yy]* )
            echo -e "${RED}Removing the screen layout file: ${NC}$recent_file"
            rm -f "$recent_file"
            ;;
        [Nn]* )
            echo "The screen layout file was not removed."
            ;;
        * )
            echo "Invalid choice. The screen layout file was not removed."
            ;;
    esac
fi

fi

# Function to start a temporary Xorg session
run_in_xorg() {
    local command="$1"

    echo "Starting a temporary Xorg session..."

    # Find an unused virtual terminal
    VT=$(fgconsole)
    NEW_VT=$((VT + 1))
    if [[ "$NEW_VT" -gt 6 ]]; then
        NEW_VT=1
    fi

    # Start Xorg on a new VT
    Xorg :1 vt"$NEW_VT" -nolisten tcp 2>&1 &
    XORG_PID=$!
    sleep 2

    if ! ps -p "$XORG_PID" > /dev/null; then
        echo -e "${RED}Failed to start Xorg session. Check /var/log/Xorg.*.log for details.${NC}"
        exit 1
    fi

    # Run the command in the Xorg session
    DISPLAY=:1 XAUTHORITY="$HOME/.Xauthority" bash -c "$command"

    echo "Stopping the temporary Xorg session..."
    kill "$XORG_PID" 2>/dev/null || true
}

# Function to execute xrandr commands
execute_xrandr() {
    local command="$1"
    local output_file="$2"

    if [ -n "$DISPLAY" ]; then
        $command > "$output_file"
    else
        run_in_xorg "$command > $output_file"
        unset DISPLAY
        unset XAUTHORITY
    fi
}

# Function to create and update Xorg configuration
create_xorg_config() {
    local Monitor="$1"
    # Define the log file locations
    local logfile=$(ls /var/log/Xorg.*.log 2>/dev/null)
    local alternate_logfile=$(ls /home/$username/.local/share/xorg/Xorg.*.log 2>/dev/null)

    if [ -e "$logfile" ]; then
        echo "Log file found at $logfile"
    else
        if [ -e "$alternate_logfile" ]; then
            logfile="$alternate_logfile"
            echo "Log file found at $logfile"
        else
            echo "Log file not found in either location."
        fi
    fi

    start_line=$(grep -n "Printing probed modes for output $Monitor" "$logfile" | cut -d':' -f1)
    if [ -n "$start_line" ]; then
        start_line=$((start_line + 1))
        modelines=$(tail -n +$start_line "$logfile" | \
        awk '
        /Modeline/ { found=1; print }
        !/Modeline/ && found { exit }')
        if [ -n "$modelines" ]; then
            best_refresh_rate=0
            best_line=""
            while IFS= read -r line; do
                refresh_rate=$(echo "$line" | awk '{match($0, /[0-9]+\.[0-9]+ kHz/); print substr($0, RSTART, RLENGTH-4)}')
                refresh_rate_clean=$(echo "$refresh_rate" | tr -cd '[:digit:].')
                # Update if this refresh rate is better
                if [ "$(echo "$refresh_rate_clean" | tr -d '.')" -gt "$(echo "$best_refresh_rate" | tr -d '.')" ]; then
                    best_refresh_rate=$refresh_rate_clean
                    best_line="$line"
                fi
            done <<< "$modelines"
            # Extract the Modeline
            modeline=$(echo "$best_line" | grep -o 'Modeline ".*')
            modeline=$(echo "$modeline" | sed -E 's/(Modeline ".*?)(x[0-9]+\.[0-9]+)(.*)/\1\3/')
            output="${modeline%%(*}"
            echo -e "${GREEN}Best Modeline found:${NC}"
            echo "$output"
            resolution=$(echo "$modeline" | grep -oP '(?<=Modeline ")[^"]+')
            MODELINE="$output"
            RES="$resolution"
            # Function to append -titus
            append_titus() {
                local res="$1"
                if [[ "$res" != *-titus ]]; then
                    res="${res}-titus"
                fi
                echo "$res"
            }
            RES=$(append_titus "$RES")
            MODELINE=$(echo "$MODELINE" | sed -r "s/\"([0-9]+x[0-9]+)\"/\"$RES\"/")
            CONFIG_SECTION=$(cat <<EOF
Section "Monitor"
    Identifier "$Monitor"
    $MODELINE
    Option "PreferredMode" "$RES"
EndSection
EOF
            )

            update_xorg_config "$CONFIG_SECTION" "$config_file"

            echo -e "${GREEN}Configuration for $Monitor updated in ${YELLOW}$config_file.${NC}"
        else
            echo -e "${RED}No Modelines found for $Monitor in $logfile${NC}"
        fi
    else
        echo -e "${RED}No Modelines found for $Monitor in $logfile${NC}"
    fi
}

# Function to update Xorg configuration file
update_xorg_config() {
    local input_section="$1"
    local file="$2"

    identifier=$(echo "$input_section" | grep "Identifier" | sed 's/.*"\(.*\)".*/\1/')

    touch "$file"
    mapfile -t file_lines < "$file"

    modified_lines=()

    in_correct_section=false
    section_found=false
    modeline_added=false

    new_modeline=$(echo "$input_section" | grep "Modeline" | sed 's/^[[:space:]]*//')

    for line in "${file_lines[@]}"; do
        if [[ $line == Section* && $line == *"Monitor"* ]]; then
            modified_lines+=("$line")
            in_correct_section=false
        elif [[ $line == *Identifier* && $line == *"$identifier"* ]]; then
            modified_lines+=("$line")
            in_correct_section=true
            section_found=true
        elif [[ $in_correct_section == true && $line == EndSection* ]]; then
            in_correct_section=false
            if ! $modeline_added && [ -n "$new_modeline" ]; then
                modified_lines+=("    $new_modeline")
            fi
            while IFS= read -r option; do
                option_name=$(echo "$option" | awk '{print $2}')
                if ! printf "%s\n" "${modified_lines[@]}" | grep -q "    Option.*$option_name"; then
                    modified_lines+=("$option")
                fi
            done < <(echo "$input_section" | grep "Option")
            modified_lines+=("$line")
        elif [[ $in_correct_section == true && $line == *Modeline* ]]; then
            if [ -n "$new_modeline" ]; then
                modified_lines+=("    $new_modeline")
                modeline_added=true
            else
                modified_lines+=("$line")
            fi
        elif [[ $in_correct_section == true && $line == *Option* ]]; then
            option_name=$(echo "$line" | awk '{print $2}')
            if echo "$input_section" | grep -q "Option.*$option_name"; then
                modified_lines+=("$(echo "$input_section" | grep "Option.*$option_name")")
            else
                modified_lines+=("$line")
            fi
        else
            modified_lines+=("$line")
        fi
    done

    if [ "$section_found" = false ]; then
        if [ ${#modified_lines[@]} -ne 0 ] && [ "${modified_lines[-1]}" != "" ]; then
            modified_lines+=("")
        fi
        while IFS= read -r line; do
            if [[ $line == *Modeline* ]]; then
                modified_lines+=("    $new_modeline")
            else
                modified_lines+=("$line")
            fi
        done < <(echo "$input_section")
    fi

    printf "%s\n" "${modified_lines[@]}" > "$file"
}

echo -e "${BLUE}Do you want to set Modeline configuration?${NC} (Y/n): "
read -r set_modeline
set_modeline=${set_modeline:-y}

if [[ "${set_modeline,,}" == "y" ]]; then
    if ! command -v xrandr &>/dev/null; then
        echo -e "${RED}Error: xrandr is not installed.${NC}"
        exit 1
    fi

    xrandr_output=$(mktemp)
    execute_xrandr "xrandr --query" "$xrandr_output"

    connected_displays=$(grep " connected" "$xrandr_output" | awk '{print $1}')

    if [ -z "$connected_displays" ]; then
        echo -e "${RED}No connected displays found.${NC}"
        rm "$xrandr_output"
        exit 1
    else
        echo -e "${GREEN}Connected displays:${NC}"
        for display in $connected_displays; do
            echo "- $display"

            current_res=$(sed -n "/^$display/,/^\S/p" "$xrandr_output" | grep -oP '\d+x\d+(?=.*\*)')
            current_rate=$(sed -n "/^$display/,/^\S/p" "$xrandr_output" | grep -oP '\d+\.\d+(?=.*\*)' | tail -n1)

            max_res=$(sed -n "/^$display/,/^\S/p" "$xrandr_output" | grep -Eo '[0-9]{3,4}x[0-9]{3,4}' | sort -nr | head -n 1)
            max_rate=$(sed -n "/^$display/,/^\S/p" "$xrandr_output" | grep -oP '\d+\.\d+' | sort -nr | head -n 1)

            if [[ "$current_res" != "$max_res" || "$current_rate" != "$max_rate" ]]; then
                echo -e "${YELLOW}Resolution is $current_res but it's capable of $max_res${NC}"
                echo -e "${YELLOW}Frame rate is $current_rate but it's capable of $max_rate${NC}"

                echo -e "${BLUE}Do you want to create/update an Xorg configuration for the maximum settings for $display?${NC} (Y/n): "
                read -r create_config
                create_config=${create_config:-y}

                if [[ "${create_config,,}" == "y" ]]; then
                    echo -e "${GREEN}Creating/Updating Xorg configuration for $display...${NC}"
                    create_xorg_config "$display" "$config_file"
                else
                    echo -e "${RED}Xorg configuration for $display not created/updated.${NC}"
                fi
            else
                echo -e "${GREEN}Current settings for $display are already at maximum:${NC}"
                echo -e "${GREEN}Resolution: $current_res${NC}"
                echo -e "${GREEN}Refresh rate: $current_rate${NC}"
                echo -e "${BLUE}Do you still want to create/update an Xorg configuration for $display? (y/N): ${NC}"
                read -r create_config
                create_config=${create_config:-n}
                if [[ "${create_config,,}" == "y" ]]; then
                    echo -e "${GREEN}Creating/Updating Xorg configuration for $display...${NC}"
                    create_xorg_config "$display" "$config_file"
                else
                    echo -e "${RED}Xorg configuration for $display not created/updated.${NC}"
                fi
            fi
        done
    fi
    rm "$xrandr_output"
fi
