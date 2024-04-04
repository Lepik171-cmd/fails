#!/bin/bash

# Function to display error and exit
error_exit() {
    echo "$1" >&2
    exit 1
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run as root"
fi

# Set variables
hostname="arch"
username="user"
password="password"
timezone="America/New_York"
locale="en_US.UTF-8"
keymap="us"
syslinux_path="/boot/syslinux"

# Print available drives
lsblk -d -o NAME,SIZE -n | grep -v "^loop" | grep -v "^sr" | grep -v "^ram"

# Ask user for drive
read -p "Enter the drive to install Arch Linux (e.g., /dev/sda): " drive

# Ask user for boot partition size
read -p "Enter the partition size in MiB for the boot partition (e.g., 512): " boot_size

# Ask user for root partition size
read -p "Enter the partition size in GiB for the root partition (e.g., 20): " root_size

# Ask user for home partition size
read -p "Enter the partition size in GiB for the home partition (e.g., 30): " home_size

# Ask user for swap partition size
read -p "Enter the size in GiB for the swap partition (e.g., 4): " swap_size

# Partition the drive
parted -s "$drive" mklabel gpt
parted -s "$drive" mkpart primary ext4 1MiB "${boot_size}MiB"
parted -s "$drive" mkpart primary ext4 "${boot_size}MiB" "${root_size}GiB"
parted -s "$drive" mkpart primary ext4 "${root_size}GiB" "+${home_size}GiB"
parted -s "$drive" mkpart primary linux-swap "${root_size + home_size}GiB" "+${swap_size}GiB"

# Format partitions
mkfs.ext4 -F "${drive}1"
mkfs.btrfs -f "${drive}2"
mkfs.btrfs -f "${drive}3"
mkswap "${drive}4"

# Mount the root partition
mount "${drive}2" /mnt

# Create subvolumes for Btrfs
mkdir /mnt/home
mount "${drive}3" /mnt/home
btrfs subvolume create /mnt/@root
btrfs subvolume create /mnt/@home
umount /mnt/home

# Mount Btrfs subvolumes
mount -o subvol=@root "${drive}2" /mnt
mount -o subvol=@home "${drive}3" /mnt/home

# Enable swap
swapon "${drive}4"

# Mount boot partition
mkdir /mnt/boot
mount "${drive}1" /mnt/boot

# Install base system
pacstrap /mnt base linux linux-firmware

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
arch-chroot /mnt /bin/bash <<EOF

# Set the timezone
ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
hwclock --systohc

# Set locale
sed -i "s/^#$locale/$locale/" /etc/locale.gen
locale-gen
echo "LANG=$locale" > /etc/locale.conf

# Set keymap
echo "KEYMAP=$keymap" > /etc/vconsole.conf

# Set hostname
echo "$hostname" > /etc/hostname

# Add hosts
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1 localhost" >> /etc/hosts
echo "127.0.1.1 $hostname.localdomain $hostname" >> /etc/hosts

# Set root password
echo "root:$password" | chpasswd

# Install syslinux bootloader
pacman -S --noconfirm syslinux
syslinux-install_update -i -a -m
sed -i "s/root=\/dev\/sda3/root=$drive2/" /boot/syslinux/syslinux.cfg

# Install AMD Radeon drivers
pacman -S --noconfirm xf86-video-amdgpu mesa

# Install networking tools
pacman -S --noconfirm networkmanager
systemctl enable NetworkManager

# Install i3 window manager and related tools
pacman -S --noconfirm i3-gaps i3status i3lock dmenu rxvt-unicode

# Add user
useradd -m -G wheel -s /bin/bash "$username"
echo "$username:$password" | chpasswd

# Allow wheel group to execute sudo without password
sed -i 's/^# %wheel ALL=(ALL) NOPASSWD: ALL$/%wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers

EOF

# Unmount and reboot
umount -R /mnt
reboot
