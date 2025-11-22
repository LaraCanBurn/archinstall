#!/bin/bash

set -euo pipefail

# 🎨 Colores con estilo
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

# Variables globales dinámicas
ROOT_DISK=""      # Disco donde se instala el sistema (ej: /dev/sda, /dev/nvme0n1)
BOOT_PART=""      # Partición EFI (ej: /dev/sda1, /dev/nvme0n1p1)
CRYPT_PART=""     # Partición LUKS raíz (ej: /dev/sda2, /dev/nvme0n1p2)
ZFS_DISKS=()      # Array de discos para ZFS (ej: /dev/sdb /dev/sdc)
USERNAME=""       # Usuario que se creará

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

# 🔍 Selección de discos y usuario
function seleccionar_discos_y_usuario() {
  header "SELECCIÓN DE DISCO Y USUARIO"

  echo -e "${CYAN}🔎 Discos disponibles:${RESET}"
  lsblk -dpno NAME,SIZE,MODEL | grep -E '/dev/(sd|vd|nvme|mmcblk)' || true
  echo

  # Seleccionar disco raíz
  while [[ -z "${ROOT_DISK}" ]]; do
    read -rp "➡ Introduce el disco para instalar Arch (ej: /dev/sda, /dev/nvme0n1): " ROOT_DISK
    if [[ ! -b "$ROOT_DISK" ]]; then
      echo -e "${RED}❌ $ROOT_DISK no es un dispositivo de bloque válido.${RESET}"
      ROOT_DISK=""
    fi
  done

  # Seleccionar discos para ZFS (opcional)
  echo
  echo -e "${CYAN}🔎 Discos adicionales detectados (candidatos para ZFS):${RESET}"
  lsblk -dpno NAME,SIZE,MODEL | grep -E '/dev/(sd|vd|nvme|mmcblk)' | grep -v "^$ROOT_DISK" || true
  echo
  read -rp "➡ Discos para ZFS separados por espacio (vacío para ninguno, ej: /dev/sdb /dev/sdc): " ZFS_LINE || true
  if [[ -n "${ZFS_LINE:-}" ]]; then
    # shellcheck disable=SC2206
    ZFS_DISKS=($ZFS_LINE)
    for d in "${ZFS_DISKS[@]}"; do
      if [[ ! -b "$d" ]]; then
        echo -e "${RED}❌ $d no es un dispositivo de bloque válido. Revisa la lista.${RESET}"
        exit 1
      fi
    done
  fi

  echo
  # Usuario
  while [[ -z "${USERNAME}" ]]; do
    read -rp "➡ Nombre de usuario a crear (ej: lara, archuser): " USERNAME
    [[ -z "$USERNAME" ]] && echo -e "${RED}❌ El nombre de usuario no puede estar vacío.${RESET}"
  done

  echo
  echo -e "${GREEN}Resumen de selección:${RESET}"
  echo -e "  🔹 Disco raíz: ${CYAN}${ROOT_DISK}${RESET}"
  echo -e "  🔹 Discos ZFS: ${CYAN}${ZFS_DISKS[*]:-(ninguno)}${RESET}"
  echo -e "  🔹 Usuario:    ${CYAN}${USERNAME}${RESET}"

  echo
  echo -e "${RED}⚠ ATENCIÓN: SE VAN A DESTRUIR LOS DATOS EN ESTOS DISPOSITIVOS:${RESET}"
  echo -e "  • Disco raíz: ${CYAN}${ROOT_DISK}${RESET}"
  if (( ${#ZFS_DISKS[@]} > 0 )); then
    echo -e "  • Discos ZFS: ${CYAN}${ZFS_DISKS[*]}${RESET}"
  else
    echo -e "  • Discos ZFS: (ninguno, no se tocará ningún disco adicional)${RESET}"
  fi
  echo -e "${YELLOW}Esta operación es irreversible. Asegúrate de tener backups.${RESET}"
  read -rp "Escribe exactamente 'BORRAR' para continuar o cualquier otra cosa para salir: " CONFIRM
  if [[ "$CONFIRM" != "BORRAR" ]]; then
    echo -e "${RED}❌ Confirmación incorrecta. Abortando instalación.${RESET}"
    exit 1
  fi

  pausa
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
  echo -e "${YELLOW}⚠ Se va a particionar y cifrar ${ROOT_DISK} para el sistema raíz.${RESET}"
  echo -e "${YELLOW}   Todas las particiones existentes en ese disco serán reemplazadas.${RESET}"
  pausa

  retry cfdisk "$ROOT_DISK"

  # Detectar particiones 1 y 2 tras cfdisk
  local parts
  mapfile -t parts < <(lsblk -ln -o NAME,TYPE "$ROOT_DISK" | awk '$2=="part"{print $1}')
  if (( ${#parts[@]} < 2 )); then
    echo -e "${RED}❌ Se necesitan al menos 2 particiones (EFI + LUKS root) en ${ROOT_DISK}.${RESET}"
    exit 1
  fi
  BOOT_PART="/dev/${parts[0]}"
  CRYPT_PART="/dev/${parts[1]}"

  echo -e "${GREEN}➡ Partición EFI detectada: ${BOOT_PART}${RESET}"
  echo -e "${GREEN}➡ Partición LUKS root detectada: ${CRYPT_PART}${RESET}"

  retry mkfs.vfat -F32 "$BOOT_PART"

  echo -e "${YELLOW}➡ Se cifrará ${CRYPT_PART} (root). Recuerda la contraseña para el arranque.${RESET}"
  retry cryptsetup luksFormat --type luks1 --cipher aes-xts-plain64 --key-size 512 --iter-time 5000 "$CRYPT_PART"
  retry cryptsetup open "$CRYPT_PART" crypt-root

  retry pvcreate /dev/mapper/crypt-root
  retry vgcreate vol /dev/mapper/crypt-root
  retry lvcreate -n swap -L 8G vol
  retry lvcreate -l +100%FREE vol -n root
  retry mkswap /dev/mapper/vol-swap
  retry mkfs.ext4 /dev/mapper/vol-root

  # --- ZFS: particionado y cifrado opcional de discos adicionales ---
  if (( ${#ZFS_DISKS[@]} > 0 )); then
    echo -e "${YELLOW}⚠ También se cifrarán y prepararán para ZFS estos discos:${RESET} ${CYAN}${ZFS_DISKS[*]}${RESET}"
    echo -e "${YELLOW}   Se eliminará cualquier dato previo en ellos.${RESET}"
    pausa

    for disk in "${ZFS_DISKS[@]}"; do
      cfdisk "$disk" || echo -e "${YELLOW}⚠️  cfdisk $disk falló, continuando...${RESET}"
    done

    mkdir -p /mnt/etc/luks-keys

    for idx in "${!ZFS_DISKS[@]}"; do
      local disk="${ZFS_DISKS[$idx]}"
      local map_name="crypt-zfs$((idx+1))"
      local keyfile="/mnt/etc/luks-keys/$(basename "$disk").key"

      echo -e "${CYAN}➡ Preparando disco ZFS ${disk} (${map_name})...${RESET}"
      [ -e "/dev/mapper/${map_name}" ] && cryptsetup close "$map_name" || true

      retry cryptsetup luksFormat --type luks2 "$disk"
      retry cryptsetup open --type luks2 "$disk" "$map_name"

      # Esperar a que el mapeo esté disponible
      for i in {1..5}; do
        [ -b "/dev/mapper/${map_name}" ] && break
        sleep 1
      done
      if [ ! -b "/dev/mapper/${map_name}" ]; then
        echo -e "${RED}❌ No se pudo mapear /dev/mapper/${map_name}. Abortando...${RESET}"
        exit 1
      fi

      openssl rand -base64 64 > "$keyfile"
      retry cryptsetup luksAddKey "$disk" "$keyfile"
      echo -e "${GREEN}✅ Disco ${disk} cifrado y preparado para ZFS.${RESET}"
    done
  else
    echo -e "${YELLOW}ℹ No se seleccionaron discos ZFS. ZFS se podrá configurar más adelante.${RESET}"
  fi

  mkdir -p /mnt/etc/luks-keys
  openssl rand -base64 64 > /mnt/etc/luks-keys/root.key
  retry cryptsetup luksAddKey "$CRYPT_PART" /mnt/etc/luks-keys/root.key

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
  retry mount "$BOOT_PART" /mnt/boot/efi

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
  UUID_SDA2=$(blkid -s UUID -o value "$CRYPT_PART")
  UUID_MAPPER=$(blkid -s UUID -o value /dev/mapper/vol-root)
  if [[ -z "$UUID_SDA2" || -z "$UUID_MAPPER" ]]; then
    echo -e "${RED}❌ No se pudo obtener el UUID de la raíz cifrada. Abortando...${RESET}"
    exit 1
  fi
  echo -e "${GREEN}UUID de raíz cifrada detectado correctamente.${RESET}"

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
    echo -e "${YELLOW}ℹ /mnt/etc/crypttab existe. Se utilizará durante el arranque.${RESET}"
  fi

  pausa
}

function fase_post_install() {
  header "FASE 4 - POST-INSTALL (CHROOT + ZFS)"
  arch-chroot /mnt bash -c "$(declare -f instalar_zfs_autodetect); instalar_zfs_autodetect linux-zen"

  arch-chroot /mnt bash -c "
    set -e
    ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
    hwclock --systohc
    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    sed -i 's/^#es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    echo 'LANG=en_US.UTF-8' > /etc/locale.conf
    echo 'KEYMAP=es' > /etc/vconsole.conf
    echo 'ArchLinux' > /etc/hostname

    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section \"InputClass\"
    Identifier \"system-keyboard\"
    MatchIsKeyboard \"on\"
    Option \"XkbLayout\" \"es\"
EndSection
EOF

    echo 'XKBLAYOUT=es' > /etc/default/keyboard

    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 keyboard filesystems fsck)/' /etc/mkinitcpio.conf

    mkinitcpio -P linux-zen

    UUID_ROOT=\$(blkid -s UUID -o value \"$CRYPT_PART\")
    UUID_MAPPER=\$(blkid -s UUID -o value /dev/mapper/vol-root)

    if ! grep -q '^GRUB_ENABLE_CRYPTODISK=y' /etc/default/grub; then
      echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
    fi

    systemctl enable getty@tty1.service

    sed -i \"s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\\\"cryptdevice=UUID=\$UUID_ROOT:cryptroot root=UUID=\$UUID_MAPPER console=tty1 vconsole.keymap=es\\\"|\" /etc/default/grub

    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg

    mkinitcpio -P linux-zen

    systemctl enable NetworkManager
  "

  pausa
}

function fase_hardening_gui() {
  header "FASE 5 - HARDENING, GUI Y PERSONALIZACIÓN"
  arch-chroot /mnt bash -c "
    set -e
    if ! getent group realtime > /dev/null; then
      groupadd -r realtime
    fi

    until passwd; do echo '❗ Contraseña incorrecta. Intenta de nuevo.'; done

    useradd -m -G wheel,audio,realtime -s /bin/bash '$USERNAME'
    until passwd '$USERNAME'; do echo '❗ Contraseña incorrecta para $USERNAME. Intenta de nuevo.'; done
    EDITOR=nano visudo

    for try in \$(seq 1 3); do
      pacman -S --noconfirm xfce4 xfce4-goodies xorg xorg-server xorg-apps mesa xf86-video-vesa xf86-input-vmmouse lightdm lightdm-gtk-greeter kitty htop ncdu tree vlc p7zip zip unzip tar git vim docker python python-pip nodejs npm ufw gufw fail2ban openssh net-tools iftop timeshift realtime-privileges alsa-utils pulseaudio pulseaudio-alsa pavucontrol open-vm-tools && break
      echo '❗ Error instalando paquetes. Reintentando ('$try'/3)...'
      sleep 2
      if [[ \$try -eq 3 ]]; then echo '❌ Fallo persistente en instalación de paquetes. Abortando...'; exit 1; fi
    done

    systemctl enable vmtoolsd.service
    systemctl enable vmware-vmblock-fuse

    mkdir -p /home/$USERNAME/.config/autostart
    cat > /home/$USERNAME/.config/autostart/vmware-user.desktop <<EOF
[Desktop Entry]
Type=Application
Name=VMware User Agent
Exec=vmware-user
X-GNOME-Autostart-enabled=true
EOF
    chown -R $USERNAME: /home/$USERNAME/.config

    amixer sset Master unmute || true
    amixer sset Master 80% || true
    amixer sset PCM unmute || true
    amixer sset PCM 80% || true
    alsactl store

    sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw

    systemctl enable lightdm
    systemctl enable ufw
    ufw enable

    echo 'pcspkr' > /etc/modules-load.d/pcspkr.conf
    modprobe pcspkr || true

    cat > /etc/systemd/system/clear-cache.service <<SERV
[Unit]
Description=Clear Cache at Shutdown
DefaultDependencies=no
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=/bin/sync
ExecStart=/bin/sh -c \"echo 3 > /proc/sys/vm/drop_caches\"

[Install]
WantedBy=shutdown.target
SERV

    systemctl enable clear-cache.service
  "

  pausa
}

#### 🧩 EJECUCIÓN FINAL ####
header "🚀 INICIO DE INSTALACIÓN ARCH ZFS (fusionado)"

seleccionar_discos_y_usuario
fase_preinstall
fase_particiones_cifrado
fase_montaje_sistema
fase_post_install
fase_hardening_gui

# Desmontar particiones y reiniciar el sistema
header "🔄 Desmontando particiones y reiniciando el sistema"

arch-chroot /mnt systemctl enable lightdm
arch-chroot /mnt systemctl set-default graphical.target

umount -R /mnt || true

echo -e "${GREEN}🎉 Instalación COMPLETA. Sistema Arch con cifrado, RAID-ZFS y hardening/GUI.${RESET}"
echo -e "${YELLOW}El sistema se reiniciará en 5 segundos...${RESET}"
sleep 5
reboot
