#!/usr/bin/env bash

set -Eeuo pipefail

# =========================================================
# ARCHINSTALL - KERNEL UPDATE SCRIPT
# Compatible con:
# - Arch Linux
# - linux-zen
# - ZFS DKMS
# - VMware
# - futuros entornos bare metal
# =========================================================

LOG_DIR="/var/log/archinstall"
LOG_FILE="$LOG_DIR/kernel-update.log"

mkdir -p "$LOG_DIR"

exec > >(tee -a "$LOG_FILE")
exec 2>&1

# =========================================================
# COLORS
# =========================================================

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
RESET='\033[0m'

# =========================================================
# HELPERS
# =========================================================

header() {
    echo -e "\n${BLUE}=================================================${RESET}"
    echo -e "${CYAN}$1${RESET}"
    echo -e "${BLUE}=================================================${RESET}\n"
}

success() {
    echo -e "${GREEN}✔ $1${RESET}"
}

warn() {
    echo -e "${YELLOW}⚠ $1${RESET}"
}

error_exit() {
    echo -e "${RED}✖ ERROR: $1${RESET}"
    exit 1
}

# =========================================================
# ROOT CHECK
# =========================================================

[[ $EUID -eq 0 ]] || error_exit "Ejecuta este script como root"

# =========================================================
# INTERNET CHECK
# =========================================================

header "🌐 Verificando conexión"

ping -c 1 archlinux.org >/dev/null 2>&1 \
    || error_exit "No hay conexión a internet"

success "Conexión OK"

# =========================================================
# DETECT ENVIRONMENT
# =========================================================

header "🔍 Detectando entorno"

KERNEL=$(uname -r)

if systemd-detect-virt -q; then
    VIRT=$(systemd-detect-virt)
    warn "Entorno virtual detectado: $VIRT"
else
    success "Bare metal detectado"
fi

if pacman -Q zfs-dkms >/dev/null 2>&1; then
    USE_ZFS=true
    success "ZFS DKMS detectado"
else
    USE_ZFS=false
    warn "ZFS DKMS no instalado"
fi

# =========================================================
# REFRESH KEYS
# =========================================================

header "🔑 Refrescando keyrings"

pacman-key --populate archlinux || true

# =========================================================
# UPDATE SYSTEM
# =========================================================

header "⬆ Actualizando kernel y sistema"

pacman -Syu --needed \
    linux-zen \
    linux-zen-headers \
    --noconfirm \
    || error_exit "Fallo actualizando kernel"

success "Kernel actualizado"

# =========================================================
# DKMS REBUILD
# =========================================================

if [[ "$USE_ZFS" == true ]]; then

    header "🔧 Recompilando módulos DKMS"

    pacman -S --needed \
        zfs-dkms \
        zfs-utils \
        dkms \
        --noconfirm \
        || error_exit "Fallo instalando paquetes DKMS"

    dkms autoinstall \
        || error_exit "Fallo en DKMS autoinstall"

    success "DKMS recompilado"

fi

# =========================================================
# MKINITCPIO
# =========================================================

header "🛠 Regenerando initramfs"

mkinitcpio -P \
    || error_exit "Fallo regenerando initramfs"

success "Initramfs regenerado"

# =========================================================
# ZFS VALIDATION
# =========================================================

if [[ "$USE_ZFS" == true ]]; then

    header "🧪 Validando módulos ZFS"

    if modprobe zfs; then
        success "Módulo ZFS cargado correctamente"
    else
        error_exit "No se pudo cargar el módulo ZFS"
    fi

    zpool list \
        || warn "No se detectan pools ZFS activos"

fi

# =========================================================
# BOOT VALIDATION
# =========================================================

header "🔍 Validando boot"

[[ -f /boot/vmlinuz-linux-zen ]] \
    || error_exit "Kernel linux-zen no encontrado en /boot"

[[ -f /boot/initramfs-linux-zen.img ]] \
    || error_exit "Initramfs no encontrado"

success "Archivos boot OK"

# =========================================================
# GRUB REBUILD
# =========================================================

header "🧱 Regenerando GRUB"

grub-mkconfig -o /boot/grub/grub.cfg \
    || error_exit "Fallo regenerando GRUB"

success "GRUB regenerado"

# =========================================================
# FINAL INFO
# =========================================================

header "✅ ACTUALIZACIÓN COMPLETADA"

echo "Kernel actual : $(uname -r)"
echo "Logs           : $LOG_FILE"

warn "Reinicia el sistema para usar el nuevo kernel"

pacman -Q | grep linux

dkms status