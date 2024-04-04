#!/bin/bash -e

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
timezone="Europe/Tallinn"
keymap="us"
syslinux_path="/boot/syslinux"

# Print available drives
lsblk -d -o NAME,SIZE -n | grep -v "^loop" | grep -v "^sr" | grep -v "^ram"

# Ask user for drive to install Arch Linux
read -p "Enter the drive to install Arch Linux (e.g., /dev/sda): " drive

# Ask user for boot partition size
read -p "Enter the partition size in MiB for the boot partition (e.g., 512): " boot_size

# Ask user for root partition size
read -p "Enter the partition size in GiB for the root partition (e.g., 20): " root_size

# Ask user for swap partition size
read -p "Enter the size in GiB for the swap partition (e.g., 4): " swap_size

# Ask user for username
read -p "Enter username for the new user: " username

# Ask user for password (twice for confirmation)
while true; do
    read -s -p "Enter password for the new user: " password
    echo
    read -s -p "Confirm password: " password_confirm
    echo
    [[ "$password" = "$password_confirm" ]] && break
    echo "Passwords did not match. Please try again."
done

# Definitions
BOOT_DEVICE="${drive}1"
SWAP_DEVICE="${drive}2"
ROOT_DEVICE="${drive}3"

# Reset partition table and create new DOS table
dd if=/dev/zero of="${drive}" bs=2M count=1 status=progress

# Partition the drive
fdisk "${drive}" <<EOF
o
n
p
1

+${boot_size}M
n
p
2

+${swap_size}G
n
p
3

+${root_size}G
a
1
w
EOF

# Format partitions
mkfs.vfat -F32 "${BOOT_DEVICE}"
mkswap "${SWAP_DEVICE}"
mkfs.btrfs "${ROOT_DEVICE}"

# Mount partitions
mount "${ROOT_DEVICE}" /mnt
mkdir -p /mnt/boot
mount "${BOOT_DEVICE}" /mnt/boot

# Create subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var

# Mount subvolumes
umount /mnt
mount -o subvol=@ "${ROOT_DEVICE}" /mnt
mkdir -p /mnt/{boot,home,var}
mount -o subvol=@home "${ROOT_DEVICE}" /mnt/home
mount -o subvol=@var "${ROOT_DEVICE}" /mnt/var

# Install base system
pacstrap /mnt base base-devel

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
arch-chroot /mnt /bin/bash <<EOF

# Set the timezone
ln -sf "/usr/share/zoneinfo/${timezone}" /etc/localtime
hwclock --systohc

# Set locale
sed -i "s/^#en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Set keymap
echo "KEYMAP=${keymap}" > /etc/vconsole.conf

# Set hostname
read -p "Enter hostname: " hostname
echo "\$hostname" > /etc/hostname

# Add hosts
cat <<EOT >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   \$hostname.localdomain \$hostname
EOT

# Set root password
echo "root:${password}" | chpasswd

# Install syslinux bootloader
pacman -S --noconfirm syslinux gptfdisk

# Set up bootloader
cat > /mnt/boot/syslinux/syslinux.cfg <<EOL
DEFAULT arch
PROMPT 0
TIMEOUT 50
LABEL arch
    LINUX ../vmlinuz-linux
    APPEND root=${ROOT_DEVICE} rw
    INITRD ../initramfs-linux.img
EOL

# Install AMD Radeon drivers
pacman -S --noconfirm xf86-video-amdgpu mesa

# Install networking tools
pacman -S --noconfirm networkmanager
systemctl enable NetworkManager

# Install i3 window manager and related tools
pacman -S --noconfirm i3-gaps i3status i3lock dmenu rxvt-unicode

# Add user
useradd -m -G wheel -s /bin/bash "$username"
echo "${username}:${password}" | chpasswd

# Allow wheel group to execute sudo without password
sed -i 's/^# %wheel ALL=(ALL) NOPASSWD: ALL$/%wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers

# Generate initramfs
mkinitcpio -p linux

EOF

# Unmount and reboot
umount -R /mnt
reboot
