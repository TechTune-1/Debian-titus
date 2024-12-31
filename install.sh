#!/bin/bash
set -euo pipefail

# Check if Script is Run as Root
if [[ $EUID -ne 0 ]]; then
  echo "You must be a root user to run this script, please run sudo ./install.sh" >&2
  exit 1
fi

# Create a directory for logs
readonly LOG_DIR="/var/log/titus_log"
mkdir -p "$LOG_DIR"

# Define log file paths
readonly LOGFILE="install.log"
readonly TIMING_FILE="install.timing"

if [ -z "${INSIDE_SCRIPT:-}" ]; then
  # Re-run the script inside `script`
  export INSIDE_SCRIPT=1
  exec script -q -c "bash $0" --flush --timing="$TIMING_FILE" "$LOGFILE"
fi

# Move the log files to the log directory
mv "$LOGFILE" "$LOG_DIR/"
mv "$TIMING_FILE" "$LOG_DIR/"

# Determine username
username=$(getent passwd ${SUDO_USER:-$USER} | cut -d: -f1)

if [[ -z "$username" ]]; then
  echo "Unable to determine username." >&2
  exit 1
fi

builddir=$(pwd)

# Function to run commands as non-root user
non_root() {
    local command="$1"
    runuser -u "${SUDO_USER}" -- bash -c "$command"
}

# ANSI escape sequences for text formatting
bold=$(tput bold)
normal=$(tput sgr0)

# Define the new sources content
sources_content="# Trixie (main)
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware

# Trixie Security Updates
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware

# trixie-updates, to get updates before a point release is made;
# see https://www.debian.org/doc/manuals/debian-reference/ch02.en.html#_updates_and_backports
deb http://deb.debian.org/debian/ trixie-updates main non-free-firmware
deb-src http://deb.debian.org/debian/ trixie-updates main non-free-firmware

# Sid (unstable)
deb http://deb.debian.org/debian/ sid main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ sid main contrib non-free non-free-firmware

# Bookworm (stable)
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware

# Bookworm Security Updates
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware

# Bookworm Updates
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
"

# Backup existing sources.list file
sources_backup="/etc/apt/sources.list.bak"
sudo cp /etc/apt/sources.list "$sources_backup"

# Extract #deb cdrom lines from the original sources.list
cdrom_lines=$(grep '^#deb cdrom:' /etc/apt/sources.list || true)

# Write the #deb cdrom lines and new sources content to sources.list
{
    if [[ -n "$cdrom_lines" ]]; then
        echo "$cdrom_lines"
        echo ""
    fi
    echo "$sources_content"
} | sudo tee /etc/apt/sources.list > /dev/null

# Define the apt pinning preferences content
pinning_content="Package: *
Pin: release a=testing
Pin-Priority: 700

Package: *
Pin: release a=unstable
Pin-Priority: 500

Package: *
Pin: release a=stable
Pin-Priority: 400
"

# Create apt pinning file
preferences="/etc/apt/preferences.d/80-titus-pin"
echo "$pinning_content" | sudo tee "$preferences" > /dev/null

# Tell user
echo "sources.list and apt pinning preferences updated successfully."
echo "Apt pinning preferences have been saved to $preferences"
echo "A backup of the original sources.list file is saved as $sources_backup"

# Configure
dpkg --configure -a
apt install -f -y

# Update packages list and upgrade system
apt update && apt upgrade -y

# Install nala
apt install nala -y

# Create necessary directories and copy configuration files
mkdir -p /home/$username/.config /home/$username/.fonts /home/$username/Pictures
cp .Xresources .Xnord /home/$username
cp -R dotconfig/* /home/$username/.config/
cp bg.jpg /home/$username/Pictures/background.jpg
mv user-dirs.dirs /home/$username/.config
chown -R $username:$username /home/$username

# Make sure Git is installed
echo "${bold}Checking if Git is installed...${normal}"
if ! command -v git &> /dev/null; then
    echo "${bold}Git is not installed.${normal} Installing Git..."
    sudo apt install git -y
fi

# Detect GPU
gpu=$(lspci -nn | grep -E "VGA|3D controller" | cut -d ':' -f3)

# Install GPU drivers based on detection
case "$gpu" in
  *NVIDIA*)
    echo "NVIDIA GPU detected. Installing NVIDIA drivers..."
    nala install -y linux-headers-$(uname -r) nvidia-driver firmware-misc-nonfree
    ;;
  *AMD*)
    echo "AMD GPU detected. Installing AMD drivers..."
    nala install -y firmware-amd-graphics libgl1-mesa-dri libglx-mesa0 mesa-vulkan-drivers xserver-xorg-video-all
    ;;
  *Intel*)
    echo "Intel GPU detected. Installing Intel drivers..."
    nala install -y xserver-xorg-video-intel
    ;;
  *)
    echo "Unable to detect GPU or unsupported GPU found."
    echo "GPU info: $gpu"
    echo "You may need to install drivers manually."
    ;;
esac

# Essential Programs
essential_programs=(feh bspwm sxhkd kitty arandr rofi polybar picom thunar gvfs lxpolkit x11-xserver-utils unzip yad wget pulseaudio pavucontrol gnome-keyring accountsservice lightdm neovim)
# Other less important Programs
other_programs=(lxappearance papirus-icon-theme fastfetch flameshot psmisc kio-extras fonts-noto-color-emoji curl ntfs-3g zoxide libimlib2-dev)

# Install Programs individually
for program in "${essential_programs[@]}" "${other_programs[@]}"; do
  nala install -y $program || { echo "Failed to install $program" >&2; exit 1; }
done

# Download Nordic Theme
cd /usr/share/themes/
wget https://github.com/EliverLara/Sweet/releases/download/v4.0/Sweet-Dark-v40.zip
unzip Sweet-Dark-v40.zip
rm Sweet-Dark-v40.zip

# Installing fonts
cd $builddir
nala install fonts-font-awesome -y
wget https://github.com/ryanoasis/nerd-fonts/releases/download/v2.1.0/FiraCode.zip
unzip FiraCode.zip -d /home/$username/.fonts
wget https://github.com/ryanoasis/nerd-fonts/releases/download/v2.1.0/Meslo.zip
unzip Meslo.zip -d /home/$username/.fonts
mv dotfonts/fontawesome/otfs/*.otf /home/$username/.fonts/
chown $username:$username /home/$username/.fonts/*

# Reload Font Cache and remove zip files
fc-cache -vf
rm FiraCode.zip Meslo.zip

# Install Nordzy cursor
git clone https://github.com/alvatip/Nordzy-cursors
cd Nordzy-cursors
./install.sh
cd $builddir
rm -rf Nordzy-cursors

# Let user choose whether Beautiful Bash should be installed
echo "${bold}Do you want to install Beautiful Bash? (y/n)${normal}"
read answer
if [ "$answer" != "${answer#[Yy]}" ]; then
    echo "${bold}Installing Beautiful Bash...${normal}"
    # Remove the directory if it exists
    if [ -d "/opt/neovim/squashfs-root" ]; then
        sudo rm -rf /opt/neovim/squashfs-root
    fi
    # Run setup
    non_root "git clone https://github.com/ChrisTitusTech/mybash"
    cd mybash
    non_root "bash setup.sh"
    cd $builddir

    echo "${bold}Beautiful Bash installation complete.${normal}"
else
    echo "${bold}Beautiful Bash installation aborted.${normal}"
fi

# Check if the locale uses a 12-hour clock
time_format=$(locale -k LC_TIME | grep 'd_t_fmt' | awk -F'=' '{print $2}')

if [[ $time_format == *"%I"* ]]; then
    echo "Using 12-hour clock format detected. Do you want to change Polybar to 24-hour format? (N/y)"
    read answer
    if [[ $answer == [Yy]* ]]; then
        sed -i 's/time = "%I:%M %p"/time = "%H:%M"/' /home/$username/.config/polybar/config.ini
        echo "Polybar configuration updated to use 24-hour format."
    else
        echo "No changes made to Polybar configuration."
    fi
else
    echo "Using 24-hour clock format detected. Do you want to change Polybar to 24-hour format? (Y/n)"
    read answer
    if [[ $answer == [Yy]* ]]; then
        sed -i 's/time = "%I:%M %p"/time = "%H:%M"/' /home/$username/.config/polybar/config.ini
        echo "Polybar configuration updated to use 24-hour format."
    else
        echo "No changes made to Polybar configuration."
    fi
fi

# Install brave-browser
nala install apt-transport-https curl -y
curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg arch=amd64] https://brave-browser-apt-release.s3.brave.com/ stable main" | tee /etc/apt/sources.list.d/brave-browser-release.list
nala update
nala install brave-browser -y

# Enable graphical login and change target from CLI to GUI
systemctl enable lightdm
systemctl set-default graphical.target

# Polybar configuration
bash scripts/changeinterface

# Use nala
bash scripts/usenala

# Wait for the commands to finish completely before zipping
sleep 3

# Zip the log and timing files without including the directory itself
tar -czf "$LOG_DIR/install_log.tar.gz" -C "$LOG_DIR" install.log install.timing
rm -r "$LOG_DIR/install.log" "$LOG_DIR/install.timing"

echo "Log and timing files are zipped into the $LOG_DIR directory. They can be replayed by executing ./replay_log.sh in the debian-titus directory."
echo "You can safely reboot."
