#!/bin/bash

set -euo pipefail

# 🎨 Colores con estilo
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

# 🔁 Función para reintentos de comandos
function retry() {
  local n=1
  local max=3
  local delay=2
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo -e "${YELLOW}❗ Error ejecutando '$*'. Reintento $n/$max en $delay s...${RESET}"
        sleep $delay
      else
        echo -e "${RED}❌ Error persistente tras $max intentos. Abortando...${RESET}"
        exit 1
      fi
    }
  done
}

# 🕹️ Utilidad visual
function header() {
  echo -e "${CYAN}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "🛡️  ${1}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${RESET}"
}

function pausa() {
  echo -e "${YELLOW}✅ Fase completada. Pulsa Enter para continuar...${RESET}"
  read
}

# 🔹 Fase 1 - Preinstall
function fase_preinstall() {
  header "FASE 1 - PRE-INSTALL Y RED"
  loadkeys es
  echo -e "${GREEN}➡ Verificando UEFI...${RESET}"
  ls /sys/firmware/efi/efivars || { echo -e "${RED}❌ UEFI NO detectado. Abortando...${RESET}"; exit 1; }
  echo -e "${GREEN}➡ Verificando conexión...${RESET}"
  retry ping -c 1 archlinux.org
  pausa
}

# 🔹 Fase 2 - Particiones y cifrado
function fase_particiones_cifrado() {
  header "FASE 2 - PARTICIONES Y CIFRADO"
  retry cfdisk /dev/sda
  retry mkfs.vfat -F32 /dev/sda1

  retry cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --pbkdf argon2id /dev/sda2
  retry cryptsetup open /dev/sda2 crypt-root

  retry pvcreate /dev/mapper/crypt-root
  retry vgcreate vol /dev/mapper/crypt-root
  retry lvcreate -n swap -L 8G vol
  retry lvcreate -l +100%FREE vol -n root
  retry mkswap /dev/mapper/vol-swap
  retry mkfs.ext4 /dev/mapper/vol-root

  retry cfdisk /dev/sdb
  retry cfdisk /dev/sdc
  retry cryptsetup luksFormat --type luks2 /dev/sdb
  retry cryptsetup luksFormat --type luks2 /dev/sdc
  retry cryptsetup open /dev/sdb crypt-zfs1
  retry cryptsetup open /dev/sdc crypt-zfs2

  mkdir -p /mnt/etc/luks-keys
  openssl rand -base64 64 > /mnt/etc/luks-keys/root.key
  openssl rand -base64 64 > /mnt/etc/luks-keys/sdb.key
  openssl rand -base64 64 > /mnt/etc/luks-keys/sdc.key

  retry cryptsetup luksAddKey /dev/sda2 /mnt/etc/luks-keys/root.key
  retry cryptsetup luksAddKey /dev/sdb /mnt/etc/luks-keys/sdb.key
  retry cryptsetup luksAddKey /dev/sdc /mnt/etc/luks-keys/sdc.key

  pausa
}

# 🔧 Instalación de ZFS (post-pacstrap)
function instalar_zfs_autodetect() {
  echo -e "${CYAN}🔍 Instalando ZFS DKMS para cualquier kernel...${RESET}"

  if ! grep -q "\[archzfs\]" /etc/pacman.conf; then
    echo -e "\n[archzfs]\nServer = https://archzfs.com/\$repo/x86_64" >> /etc/pacman.conf
    pacman-key --recv-keys F75D9D76 --keyserver keyserver.ubuntu.com
    pacman-key --lsign-key F75D9D76
    pacman -Sy
  fi

  echo -e "${CYAN}📦 Instalando zfs-dkms y zfs-utils...${RESET}"
  pacman -S --noconfirm zfs-dkms zfs-utils || {
    echo -e "${YELLOW}⚠️ Fallback a AUR...${RESET}"
    if command -v paru &>/dev/null; then
      paru -S --noconfirm zfs-dkms zfs-utils
    elif command -v yay &>/dev/null; then
      yay -S --noconfirm zfs-dkms zfs-utils
    else
      echo -e "${RED}❌ No se encontró yay/paru.${RESET}"
      exit 1
    fi
  }
  echo -e "${GREEN}✅ ZFS DKMS instalado correctamente.${RESET}"
}

function fase_montaje_sistema() {
  header "FASE 3 - MONTAJE Y SISTEMA BASE"
  retry mount /dev/mapper/vol-root /mnt
  retry swapon /dev/mapper/vol-swap
  mkdir -p /mnt/boot/efi
  retry mount /dev/sda1 /mnt/boot/efi

  retry reflector --verbose --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

  retry pacstrap /mnt base linux-zen linux-zen-headers sof-firmware base-devel grub efibootmgr nano vim networkmanager lvm2 cryptsetup
  genfstab -U /mnt > /mnt/etc/fstab
  pausa
}

function fase_post_install() {
  header "FASE 4 - POST-INSTALL (CHROOT + ZFS)"
  arch-chroot /mnt bash -c "$(declare -f instalar_zfs_autodetect); instalar_zfs_autodetect linux-zen"

  arch-chroot /mnt bash -c '
    set -e
    ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
    hwclock --systohc
    sed -i "s/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
    sed -i "s/^#es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/" /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    echo "KEYMAP=es" > /etc/vconsole.conf
    echo "ArchLinux" > /etc/hostname

    sed -i "s/^HOOKS.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/" /etc/mkinitcpio.conf
    mkinitcpio -P linux-zen

    UUID_ROOT=$(blkid -s UUID -o value /dev/sda2)
    UUID_MAPPER=$(blkid -s UUID -o value /dev/mapper/vol-root)

    # Habilitar cryptodisk en grub
    if ! grep -q "^GRUB_ENABLE_CRYPTODISK=y" /etc/default/grub; then
      echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
    fi

    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$UUID_ROOT:cryptroot root=UUID=$UUID_MAPPER\"|" /etc/default/grub

    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg

    systemctl enable NetworkManager
  '

  pausa
}

function fase_hardening_gui() {
  header "FASE 5 - HARDENING, GUI Y PERSONALIZACIÓN"
  arch-chroot /mnt bash -c '
    set -e
    # Contraseña root con reintentos
    until passwd; do echo "❗ Contraseña incorrecta. Intenta de nuevo."; done
    # Usuario admin
    useradd -m -G wheel -s /bin/bash LaraCanBurn
    until passwd LaraCanBurn; do echo "❗ Contraseña incorrecta para LaraCanBurn. Intenta de nuevo."; done
    EDITOR=nano visudo

    # Instalación de entorno gráfico y utilidades
    for try in {1..3}; do
      pacman -S --noconfirm xfce4 xorg xorg-server lightdm lightdm-gtk-greeter kitty htop ncdu tree vlc p7zip zip unzip tar git vim docker python python-pip nodejs npm ufw gufw fail2ban openssh net-tools iftop timeshift realtime-privileges && break
      echo "❗ Error instalando paquetes. Reintentando ($try/3)..."
      sleep 2
      if [[ $try -eq 3 ]]; then echo "❌ Fallo persistente en instalación de paquetes. Abortando..."; exit 1; fi
    done

    # Deshabilitar IPv6 en UFW para evitar errores si el módulo no está disponible
    sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw

    systemctl enable lightdm
    systemctl enable ufw
    ufw enable

    # Habilitar altavoz del sistema (pcspkr)
    echo "pcspkr" > /etc/modules-load.d/pcspkr.conf
    modprobe pcspkr || true

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
  '
  pausa
}
tedBy=shutdown.target
#### 🧩 EJECUCIÓN FINAL ####
header "🚀 INICIO DE INSTALACIÓN ARCH ZFS (fusionado)"
fase_preinstall    systemctl enable clear-cache.service
fase_particiones_cifrado
fase_montaje_sistema
fase_post_install
fase_hardening_gui
NAL ####
echo -e "${GREEN}🎉 Instalación COMPLETA. Sistema Arch con cifrado, RAID-ZFS y hardening/GUI.${RESET}" DE INSTALACIÓN ARCH ZFS (fusionado)"
fase_hardening_gui

echo -e "${GREEN}🎉 Instalación COMPLETA. Sistema Arch con cifrado, RAID-ZFS y hardening/GUI.${RESET}"
