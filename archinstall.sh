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
  # IMPORTANTE: La contraseña que introduzcas aquí para /dev/sda2 será la que deberás usar al arrancar el sistema (GRUB la pedirá).
  retry cfdisk /dev/sda
  retry mkfs.vfat -F32 /dev/sda1

  # Aquí se te pedirá que introduzcas una contraseña para el cifrado de /dev/sda2.
  # GUARDA esa contraseña, ya que será necesaria cada vez que arranques el sistema.
  retry cryptsetup luksFormat --type luks1 --cipher aes-xts-plain64 --key-size 512 --iter-time 5000 /dev/sda2
  retry cryptsetup open /dev/sda2 crypt-root

  retry pvcreate /dev/mapper/crypt-root
  retry vgcreate vol /dev/mapper/crypt-root
  retry lvcreate -n swap -L 8G vol
  retry lvcreate -l +100%FREE vol -n root
  retry mkswap /dev/mapper/vol-swap
  retry mkfs.ext4 /dev/mapper/vol-root

  # Permitir que cfdisk en sdb y sdc fallen sin abortar el script
  cfdisk /dev/sdb || echo -e "${YELLOW}⚠️  cfdisk /dev/sdb falló, continuando...${RESET}"
  cfdisk /dev/sdc || echo -e "${YELLOW}⚠️  cfdisk /dev/sdc falló, continuando...${RESET}"

  # Solo ejecutar cryptsetup si el dispositivo existe
  if [ -b /dev/sdb ]; then
    mkdir -p /mnt/etc/luks-keys
    # Cierra el mapeo si ya existe
    [ -e /dev/mapper/crypt-zfs1 ] && cryptsetup close crypt-zfs1 || true
    retry cryptsetup luksFormat --type luks2 /dev/sdb
    retry cryptsetup open --type luks2 /dev/sdb crypt-zfs1
    # Esperar a que el mapeo esté disponible
    for i in {1..5}; do
      [ -b /dev/mapper/crypt-zfs1 ] && break
      sleep 1
    done
    if [ ! -b /dev/mapper/crypt-zfs1 ]; then
      echo -e "${RED}❌ No se pudo mapear /dev/mapper/crypt-zfs1. Abortando...${RESET}"
      exit 1
    fi
    openssl rand -base64 64 > /mnt/etc/luks-keys/sdb.key
    retry cryptsetup luksAddKey /dev/sdb /mnt/etc/luks-keys/sdb.key
  else
    echo -e "${YELLOW}⚠️  /dev/sdb no existe, saltando cifrado y apertura de /dev/sdb...${RESET}"
  fi

  if [ -b /dev/sdc ]; then
    mkdir -p /mnt/etc/luks-keys
    # Cierra el mapeo si ya existe
    [ -e /dev/mapper/crypt-zfs2 ] && cryptsetup close crypt-zfs2 || true
    retry cryptsetup luksFormat --type luks2 /dev/sdc
    retry cryptsetup open --type luks2 /dev/sdc crypt-zfs2
    # Esperar a que el mapeo esté disponible
    for i in {1..5}; do
      [ -b /dev/mapper/crypt-zfs2 ] && break
      sleep 1
    done
    if [ ! -b /dev/mapper/crypt-zfs2 ]; then
      echo -e "${RED}❌ No se pudo mapear /dev/mapper/crypt-zfs2. Abortando...${RESET}"
      exit 1
    fi
    openssl rand -base64 64 > /mnt/etc/luks-keys/sdc.key
    retry cryptsetup luksAddKey /dev/sdc /mnt/etc/luks-keys/sdc.key
  else
    echo -e "${YELLOW}⚠️  /dev/sdc no existe, saltando cifrado y apertura de /dev/sdc...${RESET}"
  fi

  mkdir -p /mnt/etc/luks-keys  # <-- Esto puede quedarse para root.key, pero ya está creado arriba
  openssl rand -base64 64 > /mnt/etc/luks-keys/root.key
  retry cryptsetup luksAddKey /dev/sda2 /mnt/etc/luks-keys/root.key

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

  # --- Comprobación de microcode ---
  echo -e "${CYAN}🔎 Comprobando microcode...${RESET}"
  CPU_VENDOR=$(lscpu | grep -i 'vendor' | awk '{print $3}' | head -n1)
  if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
    if ! pacman -Qq intel-ucode &>/dev/null; then
      echo -e "${YELLOW}⚠️  Instalando intel-ucode...${RESET}"
      pacman -Sy --noconfirm intel-ucode
    fi
    MICROCODE="intel-ucode.img"
  elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    if ! pacman -Qq amd-ucode &>/dev/null; then
      echo -e "${YELLOW}⚠️  Instalando amd-ucode...${RESET}"
      pacman -Sy --noconfirm amd-ucode
    fi
    MICROCODE="amd-ucode.img"
  else
    MICROCODE=""
  fi

  retry pacstrap /mnt base linux-zen linux-zen-headers sof-firmware base-devel grub efibootmgr nano vim networkmanager lvm2 cryptsetup $([[ -n "$MICROCODE" ]] && echo "${MICROCODE%.img}")

  genfstab -U /mnt > /mnt/etc/fstab

  # --- Comprobaciones adicionales ---
  echo -e "${CYAN}🔎 Comprobando mapeo LUKS y UUIDs...${RESET}"
  if ! ls /dev/mapper/crypt-root &>/dev/null; then
    echo -e "${RED}❌ El mapeo /dev/mapper/crypt-root no existe. Abortando...${RESET}"
    exit 1
  fi
  UUID_SDA2=$(blkid -s UUID -o value /dev/sda2)
  UUID_MAPPER=$(blkid -s UUID -o value /dev/mapper/vol-root)
  if [[ -z "$UUID_SDA2" || -z "$UUID_MAPPER" ]]; then
    echo -e "${RED}❌ No se pudo obtener el UUID de /dev/sda2 o /dev/mapper/vol-root. Abortando...${RESET}"
    exit 1
  fi
  echo -e "${GREEN}UUID de /dev/sda2: $UUID_SDA2${RESET}"
  echo -e "${GREEN}UUID de /dev/mapper/vol-root: $UUID_MAPPER${RESET}"

  echo -e "${CYAN}🔎 Comprobando fstab...${RESET}"
  if ! grep -q "$UUID_MAPPER" /mnt/etc/fstab; then
    echo -e "${RED}❌ El UUID de la raíz no está en /mnt/etc/fstab. Abortando...${RESET}"
    exit 1
  fi
  echo -e "${GREEN}fstab contiene la raíz correctamente.${RESET}"

  # --- Verificación de instalación base, kernel e initramfs ---
  echo -e "${CYAN}🔎 Comprobando instalación base y archivos críticos...${RESET}"
  if [[ ! -x /mnt/bin/bash ]]; then
    echo -e "${RED}❌ /mnt/bin/bash no existe. La instalación base ha fallado. Abortando...${RESET}"
    exit 1
  fi
  if [[ ! -f /mnt/boot/vmlinuz-linux-zen ]]; then
    echo -e "${RED}❌ /mnt/boot/vmlinuz-linux-zen no existe. El kernel no se ha instalado. Abortando...${RESET}"
    exit 1
  fi
  if [[ ! -f /mnt/boot/initramfs-linux-zen.img ]]; then
    echo -e "${RED}❌ /mnt/boot/initramfs-linux-zen.img no existe. El initramfs no se ha generado. Abortando...${RESET}"
    exit 1
  fi
  if [[ -n "$MICROCODE" && ! -f /mnt/boot/$MICROCODE ]]; then
    echo -e "${RED}❌ /mnt/boot/$MICROCODE no existe. El microcode no se ha instalado. Abortando...${RESET}"
    exit 1
  fi
  echo -e "${GREEN}Sistema base, kernel, initramfs y microcode detectados correctamente.${RESET}"

  # --- Comprobación de consola ---
  echo -e "${CYAN}🔎 Comprobando existencia de consola...${RESET}"
  if arch-chroot /mnt test ! -c /dev/console; then
    echo -e "${YELLOW}⚠️  /mnt/dev/console no existe. Creando...${RESET}"
    arch-chroot /mnt mknod -m 600 /dev/console c 5 1
  else
    echo -e "${GREEN}/mnt/dev/console ya existe.${RESET}"
  fi

  # --- Comprobación de crypttab ---
  if [[ -f /mnt/etc/crypttab ]]; then
    echo -e "${YELLOW}⚠️  /mnt/etc/crypttab existe. Su contenido es:${RESET}"
    cat /mnt/etc/crypttab
  fi

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

    # Configuración de teclado español para Xorg
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "es"
EndSection
EOF

    # Opcional: para compatibilidad con otros DMs
    echo "XKBLAYOUT=es" > /etc/default/keyboard

    # Asegura que el hook keyboard esté presente antes de filesystems
    sed -i "s/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 keyboard filesystems fsck)/" /etc/mkinitcpio.conf

    mkinitcpio -P linux-zen

    UUID_ROOT=$(blkid -s UUID -o value /dev/sda2)
    UUID_MAPPER=$(blkid -s UUID -o value /dev/mapper/vol-root)

    # Habilitar cryptodisk en grub
    if ! grep -q "^GRUB_ENABLE_CRYPTODISK=y" /etc/default/grub; then
      echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
    fi

    # Habilitar getty en tty1 para asegurar login en consola
    systemctl enable getty@tty1.service

    # Forzar arranque en modo texto y consola y teclado español
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$UUID_ROOT:cryptroot root=UUID=$UUID_MAPPER console=tty1 vconsole.keymap=es\"|" /etc/default/grub

    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg

    # Regenerar initramfs tras cambios en HOOKS
    mkinitcpio -P linux-zen

    systemctl enable NetworkManager
  '

  pausa
}

function fase_hardening_gui() {
  header "FASE 5 - HARDENING, GUI Y PERSONALIZACIÓN"
  arch-chroot /mnt bash -c '
    set -e
    # Crear grupo realtime si no existe (dentro del chroot)
    if ! getent group realtime > /dev/null; then
      groupadd -r realtime
    fi

    # Contraseña root con reintentos
    until passwd; do echo "❗ Contraseña incorrecta. Intenta de nuevo."; done
    # Usuario admin
    useradd -m -G wheel,audio,realtime -s /bin/bash LaraCanBurn
    until passwd LaraCanBurn; do echo "❗ Contraseña incorrecta para LaraCanBurn. Intenta de nuevo."; done
    EDITOR=nano visudo

    # Instalación de entorno gráfico, drivers, utilidades y audio, y open-vm-tools
    for try in $(seq 1 3); do
      pacman -S --noconfirm xfce4 xfce4-goodies xorg xorg-server xorg-apps mesa xf86-video-vesa xf86-input-vmmouse lightdm lightdm-gtk-greeter kitty htop ncdu tree vlc p7zip zip unzip tar git vim docker python python-pip nodejs npm ufw gufw fail2ban openssh net-tools iftop timeshift realtime-privileges alsa-utils pulseaudio pulseaudio-alsa pavucontrol open-vm-tools && break
      echo "❗ Error instalando paquetes. Reintentando (\$try/3)..."
      sleep 2
      if [[ \$try -eq 3 ]]; then echo "❌ Fallo persistente en instalación de paquetes. Abortando..."; exit 1; fi
    done

    # Habilitar servicios de VMware Tools
    systemctl enable vmtoolsd.service
    systemctl enable vmware-vmblock-fuse

    # Autostart del redimensionado automático en XFCE (para usuario LaraCanBurn)
    mkdir -p /home/LaraCanBurn/.config/autostart
    cat > /home/LaraCanBurn/.config/autostart/vmware-user.desktop <<EOF
[Desktop Entry]
Type=Application
Name=VMware User Agent
Exec=vmware-user
X-GNOME-Autostart-enabled=true
EOF
    chown -R LaraCanBurn: /home/LaraCanBurn/.config

    # Configuración básica de ALSA: volumen por defecto y sin mute
    amixer sset Master unmute || true
    amixer sset Master 80% || true
    amixer sset PCM unmute || true
    amixer sset PCM 80% || true

    # Crear configuración persistente de ALSA
    alsactl store

    # Eliminar arranque global de PulseAudio (no recomendado en Arch)
    systemctl --global disable pulseaudio || true
    systemctl --global stop pulseaudio || true

    # Habilitar y arrancar PulseAudio solo para el usuario (esto lo hará XFCE automáticamente)
    # systemctl --user enable pulseaudio || true
    # systemctl --user start pulseaudio || true

    # Deshabilitar IPv6 en UFW para evitar errores si el módulo no está disponible
    sed -i "s/^IPV6=.*/IPV6=no/" /etc/default/ufw

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
WantedBy=shutdown.target
SERV

    systemctl enable clear-cache.service
  '

  pausa
}
#### 🧩 EJECUCIÓN FINAL ####
header "🚀 INICIO DE INSTALACIÓN ARCH ZFS (fusionado)"
fase_preinstall
fase_particiones_cifrado
fase_montaje_sistema
fase_post_install
fase_hardening_gui

# Desmontar particiones y reiniciar el sistema
header "🔄 Desmontando particiones y reiniciando el sistema"

# Habilitar LightDM para que el entorno gráfico se inicie automáticamente tras el reinicio
arch-chroot /mnt systemctl enable lightdm

# Establecer graphical.target como objetivo por defecto
arch-chroot /mnt systemctl set-default graphical.target

# Elimina cualquier arranque global de PulseAudio (NO poner esto aquí)
# arch-chroot /mnt systemctl --global enable pulseaudio
# arch-chroot /mnt systemctl --global start pulseaudio

# swapoff -a || true
umount -R /mnt || true

echo -e "${GREEN}🎉 Instalación COMPLETA. Sistema Arch con cifrado, RAID-ZFS y hardening/GUI.${RESET}"
echo -e "${YELLOW}El sistema se reiniciará en 5 segundos...${RESET}"
sleep 5
reboot
sleep 5
reboot
reboot
sleep 5
reboot
reboot
reboot
reboot
