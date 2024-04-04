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
timezone="America/New_York"
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

# Ask user for home partition size
read -p "Enter the partition size in GiB for the home partition (e.g., 30): " home_size

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

#!/bin/bash -e

# Definitions
BOOT_DEVICE=${drive}1
SWAP_DEVICE=${drive}2
ROOT_DEVICE=${drive}3

# Reset partition table and create new DOS table
dd if=/dev/zero of=/dev/sdb bs=2M count=1 status=progress

# 256mb boot, 5gb swap and left for rootfs
fdisk ${drive} <<EOF
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

# Format
mkfs.vfat ${BOOT_DEVICE}
mkfs.btrfs ${ROOT_DEVICE}
mswap ${SWAP_DEVICE}
swapon ${SWAP_DEVICE}

# Create subvolumes
mount ${ROOT_DEVICE} /mnt
pushd /mnt
for k in home var root; do
    btrfs subvolume create "@${k}"
done
popd
umount /mnt

# Mount everything into correct place
mount -o subvolume=@root ${ROOT_DEVICE} /mnt
mkdir -p /mnt/{boot,var,home}
mount -o subvolume=@var ${ROOT_DEVICE} /mnt/var
mount -o subvolume=@home ${ROOT_DEVICE} /mnt/home
mount ${BOOT_DEVICE} /mnt/boot

# Install base system
pacstrap /mnt base base-devel


# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Add Windows drive to Syslinux boot menu
echo -e "LABEL windows\n\tMENU LABEL Windows\n\tCOM32 chain.c32\n\tAPPEND fs ntldr=/bootmgr" >> /mnt$syslinux_path/syslinux.cfg

# Add Arch Linux entry to Syslinux boot menu
echo -e "LABEL arch\n\tMENU LABEL Arch Linux\n\tLINUX /vmlinuz-linux\n\tAPPEND root=$drive2 rw\n\tINITRD /initramfs-linux.img" >> /mnt$syslinux_path/syslinux.cfg

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
pacman -S --noconfirm syslinux gptfdisk

# Set up bootloader
cat > /mnt/boot/syslinux/syslinux.cfg <<EOF
DEFAULT archlinux
TIMEOUT 1

LABEL archlinux
    LINUX ../vmlinuz-linux
    APPEND root=${ROOT_DEVICE} rw
    INITRD ../initramfs-linux.img
EOF

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

mkinitcpio -p linux

EOF

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab


# Unmount and reboot
umount -R /mnt
reboot
