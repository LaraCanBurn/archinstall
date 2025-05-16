#!/bin/bash

set -e

function pausa() {
  read -p "✅ Fase completada. Presiona Enter para continuar con la siguiente..."
}

function fase_preinstall() {
  echo "🔹 FASE 1 - PRE-INSTALL Y RED"
  loadkeys es
  echo "➡ Verificar UEFI:"
  ls /sys/firmware/efi/efivars || { echo "❌ UEFI NO detectado. Abortando..."; exit 1; }
  echo "➡ Validar conexión:"
  ping -c 1 archlinux.org
  pausa
}

function fase_particiones_cifrado() {
  echo "🔹 FASE 2 - PARTICIONES Y CIFRADO"
  echo "➡ Crear particiones EFI y Root..."
  cfdisk /dev/sda
  mkfs.vfat -F32 /dev/sda1
  cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --pbkdf argon2id /dev/sda2
  cryptsetup open /dev/sda2 crypt-root
  pvcreate /dev/mapper/crypt-root
  vgcreate vol /dev/mapper/crypt-root
  lvcreate -n swap -L 8G vol
  lvcreate -l +100%FREE vol -n root
  mkswap /dev/mapper/vol-swap
  mkfs.ext4 /dev/mapper/vol-root

  echo "➡ Crear particiones ZFS en sdb y sdc..."
  cfdisk /dev/sdb
  cfdisk /dev/sdc
  cryptsetup luksFormat --type luks2 /dev/sdb
  cryptsetup luksFormat --type luks2 /dev/sdc
  cryptsetup open /dev/sdb crypt-zfs1
  cryptsetup open /dev/sdc crypt-zfs2

  mkdir -p /mnt/etc/luks-keys
  openssl rand -base64 64 > /mnt/etc/luks-keys/root.key
  openssl rand -base64 64 > /mnt/etc/luks-keys/sdb.key
  openssl rand -base64 64 > /mnt/etc/luks-keys/sdc.key

  cryptsetup luksAddKey /dev/sda2 /mnt/etc/luks-keys/root.key
  cryptsetup luksAddKey /dev/sdb /mnt/etc/luks-keys/sdb.key
  cryptsetup luksAddKey /dev/sdc /mnt/etc/luks-keys/sdc.key

  pausa
}

function fase_zfs() {
  echo "🔹 FASE 3 - CONFIGURACIÓN ZFS"
  pacman -Sy --noconfirm zfs-dkms zfs-utils
  zpool create -f -o ashift=12 raidz raidz /dev/mapper/crypt-zfs1 /dev/mapper/crypt-zfs2
  zfs create raidz/root
  zfs create raidz/data
  zfs set compression=lz4 raidz
  zfs set atime=off raidz
  pausa
}

function fase_montaje_sistema() {
  echo "🔹 FASE 4 - MONTAJE Y SISTEMA BASE"
  mount /dev/mapper/vol-root /mnt
  swapon /dev/mapper/vol-swap
  mkdir -p /mnt/boot/efi
  mount /dev/sda1 /mnt/boot/efi
  mkdir -p /mnt/data
  zfs mount raidz/data /mnt/data

  reflector --verbose --latest 10 --sort rate --save /etc/pacman.d/mirrorlist
  pacstrap /mnt base linux-zen linux-zen-headers sof-firmware base-devel grub efibootmgr nano vim networkmanager lvm2 cryptsetup
  genfstab -U /mnt > /mnt/etc/fstab

  pausa
}

function fase_post_install() {
  echo "🔹 FASE 5 - POST-INSTALL (CHROOT)"
  arch-chroot /mnt <<EOF
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=es" > /etc/vconsole.conf
echo "ArchLinux" > /etc/hostname

sed -i 's/^HOOKS.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P linux-zen

UUID_ROOT=\$(blkid -s UUID -o value /dev/sda2)
UUID_MAPPER=\$(blkid -s UUID -o value /dev/mapper/vol-root)

sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$UUID_ROOT:cryptroot root=UUID=\$UUID_MAPPER\"|" /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager
EOF

  pausa
}

function fase_hardening_gui() {
  echo "🔹 FASE 6 - HARDENING, GUI Y PERSONALIZACIÓN"
  arch-chroot /mnt <<EOF
passwd
useradd -m -G wheel -s /bin/bash LaraCanBurn
passwd LaraCanBurn
EDITOR=nano visudo

pacman -S --noconfirm xfce4 xorg xorg-server lightdm lightdm-gtk-greeter kitty htop ncdu tree vlc p7zip zip unzip tar neofetch git vim docker kubernetes-cli python python-pip nodejs npm ufw gufw fail2ban openssh net-tools iftop timeshift realtime-privileges

systemctl enable --now lightdm
systemctl enable ufw
ufw enable

echo "blacklist pcspkr" > /etc/modprobe.d/blacklist-pcspkr.conf
modprobe -r pcspkr

cat > /etc/systemd/system/clear-cache.service <<SERV
[Unit]
Description=Clear Cache at Shutdown
DefaultDependencies=no
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=/bin/sync
ExecStart=/bin/sh -c "echo 3 > /proc/sys/vm/drop_caches"

[Install]
WantedBy=shutdown.target
SERV

systemctl enable clear-cache.service
EOF

  pausa
}

## EJECUCIÓN GUIADA ##
fase_preinstall
fase_particiones_cifrado
fase_zfs
fase_montaje_sistema
fase_post_install
fase_hardening_gui

echo "🎉 Instalación COMPLETADA con seguridad, cifrado, RAID ZFS, GUI y hardening aplicados."
