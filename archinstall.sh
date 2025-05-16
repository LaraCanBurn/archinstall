#!/bin/bash

set -e

# Colores bonitos
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RED="\e[31m"
RESET="\e[0m"

LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/arch-install.log"

mkdir -p "$LOG_DIR"
echo "" > "$LOG_FILE"

CURRENT_PHASE=""

function header() {
  echo -e "${CYAN}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "🛡️  ${1}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${RESET}"
}

function log() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${1}" | tee -a "$LOG_FILE"
}

function pause() {
  echo -e "${YELLOW}✅ Fase completada. Pulsa Enter para continuar...${RESET}"
  read
}

function phase_wrapper() {
  local phase_function="$1"
  CURRENT_PHASE="$phase_function"
  local phase_log="${LOG_DIR}/${phase_function}.log"
  echo "" > "$phase_log"

  while true; do
    log "🚀 Iniciando fase: ${phase_function}"
    {
      trap 'handle_error "${phase_function}" "${phase_log}"' ERR
      $phase_function
      trap - ERR
      log "✅ Fase completada correctamente: ${phase_function}"
      break
    } 2>&1 | tee -a "$phase_log" | grep --line-buffered -v '^'
  done
}

function handle_error() {
  local phase="$1"
  local phase_log="$2"
  log "❌ Error en fase: $phase"
  log "🔎 Revisa el log: $phase_log"
  echo -e "${RED}❌ Error detectado en la fase: ${phase}${RESET}"
  echo -e "${YELLOW}¿Deseas repetir esta fase? (s/n)${RESET}"
  read -r choice
  if [[ "$choice" != "s" ]]; then
    log "❌ Abortando por decisión del usuario en la fase: $phase"
    exit 1
  else
    log "🔄 Repitiendo fase: $phase"
  fi
}

#### Tus fases originales abajo (sin cambios, se auto-loggean con el wrapper) ####

function fase_preinstall() {
  header "FASE 1 - PRE-INSTALL Y RED"
  loadkeys es
  ls /sys/firmware/efi/efivars
  ping -c 1 archlinux.org
  pause
}

function fase_particiones_cifrado() {
  header "FASE 2 - PARTICIONES Y CIFRADO"
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

  pause
}

function fase_zfs() {
  header "FASE 3 - CONFIGURACIÓN ZFS"
  pacman -Sy --noconfirm zfs-dkms zfs-utils
  zpool create -f -o ashift=12 raidz raidz /dev/mapper/crypt-zfs1 /dev/mapper/crypt-zfs2
  zfs create raidz/root
  zfs create raidz/data
  zfs set compression=lz4 raidz
  zfs set atime=off raidz
  pause
}

function fase_montaje_sistema() {
  header "FASE 4 - MONTAJE Y SISTEMA BASE"
  mount /dev/mapper/vol-root /mnt
  swapon /dev/mapper/vol-swap
  mkdir -p /mnt/boot/efi
  mount /dev/sda1 /mnt/boot/efi
  mkdir -p /mnt/data
  zfs mount raidz/data /mnt/data

  reflector --verbose --latest 10 --sort rate --save /etc/pacman.d/mirrorlist
  pacstrap /mnt base linux-zen linux-zen-headers sof-firmware base-devel grub efibootmgr nano vim networkmanager lvm2 cryptsetup
  genfstab -U /mnt > /mnt/etc/fstab

  pause
}

function fase_post_install() {
  header "FASE 5 - POST-INSTALL (CHROOT)"
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

  pause
}

function fase_hardening_gui() {
  header "FASE 6 - HARDENING, GUI Y PERSONALIZACIÓN"
  arch-chroot /mnt <<EOF
until passwd; do echo "Error al establecer contraseña de root. Reintentando..."; done
until useradd -m -G wheel -s /bin/bash LaraCanBurn; do echo "Error al crear usuario. Reintentando..."; done
until passwd LaraCanBurn; do echo "Error al establecer contraseña de usuario. Reintentando..."; done

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

  pause
}

#### EJECUCIÓN ####
header "INICIO DEL SCRIPT DE INSTALACIÓN AVANZADA ARCH LINUX 🔥"
phase_wrapper fase_preinstall
phase_wrapper fase_particiones_cifrado
phase_wrapper fase_zfs
phase_wrapper fase_montaje_sistema
phase_wrapper fase_post_install
phase_wrapper fase_hardening_gui

log "🎉 Instalación COMPLETA y segura. Sistema listo para disfrutar."

