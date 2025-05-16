#!/bin/bash

set -e

# Colores bonitos
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RED="\e[31m"
RESET="\e[0m"

function header() {
  echo -e "${CYAN}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "🛡️  ${1}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${RESET}"
}

function pause() {
  echo -e "${YELLOW}✅ Fase completada. Pulsa Enter para continuar...${RESET}"
  read
}

function retry_command() {
  local cmd="$1"
  local description="$2"
  local retries=3
  local count=0

  while true; do
    echo -e "${GREEN}➡ Intento: ${description}${RESET}"
    if eval "$cmd"; then
      break
    else
      echo -e "${RED}❌ Error en '${description}'.${RESET}"
      count=$((count + 1))
      if [ "$count" -ge "$retries" ]; then
        echo -e "${YELLOW}⚠ Has fallado ${retries} veces. ¿Deseas volver a intentar? (s/n)${RESET}"
        read -r retry_choice
        if [[ "$retry_choice" != "s" ]]; then
          echo -e "${RED}Abortando por decisión del usuario.${RESET}"
          exit 1
        else
          count=0
        fi
      fi
    fi
  done
}

function fase_preinstall() {
  header "FASE 1 - PRE-INSTALL Y RED"
  loadkeys es
  retry_command "ls /sys/firmware/efi/efivars" "Verificando UEFI"
  retry_command "ping -c 1 archlinux.org" "Verificando conexión"
  pause
}

function fase_particiones_cifrado() {
  header "FASE 2 - PARTICIONES Y CIFRADO"
  cfdisk /dev/sda
  mkfs.vfat -F32 /dev/sda1

  retry_command "cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --pbkdf argon2id /dev/sda2" "Cifrando Root con LUKS"
  retry_command "cryptsetup open /dev/sda2 crypt-root" "Abriendo volumen cifrado Root"

  pvcreate /dev/mapper/crypt-root
  vgcreate vol /dev/mapper/crypt-root
  lvcreate -n swap -L 8G vol
  lvcreate -l +100%FREE vol -n root
  mkswap /dev/mapper/vol-swap
  mkfs.ext4 /dev/mapper/vol-root

  cfdisk /dev/sdb
  cfdisk /dev/sdc
  retry_command "cryptsetup luksFormat --type luks2 /dev/sdb" "Cifrando ZFS disco 1"
  retry_command "cryptsetup luksFormat --type luks2 /dev/sdc" "Cifrando ZFS disco 2"
  retry_command "cryptsetup open /dev/sdb crypt-zfs1" "Abriendo volumen cifrado ZFS1"
  retry_command "cryptsetup open /dev/sdc crypt-zfs2" "Abriendo volumen cifrado ZFS2"

  mkdir -p /mnt/etc/luks-keys
  openssl rand -base64 64 > /mnt/etc/luks-keys/root.key
  openssl rand -base64 64 > /mnt/etc/luks-keys/sdb.key
  openssl rand -base64 64 > /mnt/etc/luks-keys/sdc.key

  retry_command "cryptsetup luksAddKey /dev/sda2 /mnt/etc/luks-keys/root.key" "Agregando key a Root"
  retry_command "cryptsetup luksAddKey /dev/sdb /mnt/etc/luks-keys/sdb.key" "Agregando key a SDB"
  retry_command "cryptsetup luksAddKey /dev/sdc /mnt/etc/luks-keys/sdc.key" "Agregando key a SDC"

  pause
}

# El resto igual excepto hardening, donde añadimos loops también en passwd y useradd

function fase_hardening_gui() {
  header "FASE 6 - HARDENING, GUI Y PERSONALIZACIÓN"
  arch-chroot /mnt <<EOF
while true; do
  passwd && break
  echo "❌ Error al establecer la contraseña de root. Inténtalo de nuevo."
done

while true; do
  useradd -m -G wheel -s /bin/bash LaraCanBurn && break
  echo "❌ Error al crear usuario LaraCanBurn. Inténtalo de nuevo."
done

while true; do
  passwd LaraCanBurn && break
  echo "❌ Error al establecer la contraseña de LaraCanBurn. Inténtalo de nuevo."
done

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
fase_preinstall
fase_particiones_cifrado
fase_zfs
fase_montaje_sistema
fase_post_install
fase_hardening_gui

echo -e "${GREEN}🎉 Instalación COMPLETA y segura. Sistema listo para disfrutar.${RESET}"


