#!/bin/bash
set -euo pipefail

# Colores
CYAN='\033[36m'
YELLOW='\033[33m'
RESET='\033[0m'

echo -e "${CYAN}Cargando módulos ZFS...${RESET}"
sudo modprobe zfs

# Verifica que los discos físicos existen
if [ -b /dev/sdb ] && [ -b /dev/sdc ]; then
  echo -e "${CYAN}Detectados discos físicos /dev/sdb y /dev/sdc:${RESET}"
  lsblk -no NAME,TYPE,SIZE,MODEL /dev/sdb /dev/sdc 2>/dev/null || true

  # Esperar a que los mapeos existan (máx 5s)
  for i in {1..5}; do
    if [ -b /dev/mapper/crypt-zfs1 ] && [ -b /dev/mapper/crypt-zfs2 ]; then
      break
    fi
    sleep 1
  done

  if [ -b /dev/mapper/crypt-zfs1 ] && [ -b /dev/mapper/crypt-zfs2 ]; then
    echo -e "${CYAN}Usando mapeos cifrados:"
    lsblk -no NAME,TYPE,SIZE /dev/mapper/crypt-zfs1 /dev/mapper/crypt-zfs2 2>/dev/null || true
    echo -e "${CYAN}🔧 Creando pool ZFS 'zdata' en RAID-1...${RESET}"
    sudo zpool create -f -o ashift=12 \
      -O compression=lz4 \
      -O atime=off \
      -O xattr=sa \
      -O acltype=posixacl \
      -O mountpoint=/zdata \
      zdata mirror /dev/mapper/crypt-zfs1 /dev/mapper/crypt-zfs2

    echo -e "${CYAN}🔧 Creando datasets ZFS para el sistema...${RESET}"
    sudo zfs create -o mountpoint=/home zdata/home
    sudo zfs create -o mountpoint=/var zdata/var
    sudo zfs create -o mountpoint=/srv zdata/srv
    sudo zfs create -o mountpoint=/tmp zdata/tmp
    sudo zfs create -o mountpoint=/root zdata/root
    sudo chmod 1777 /zdata/tmp

    echo -e "${CYAN}✅ Pool y datasets ZFS creados correctamente.${RESET}"
  else
    echo -e "${YELLOW}⚠️  No se detectaron ambos mapeos cifrados, omitiendo creación de pool/datasets...${RESET}"
  fi
else
  echo -e "${YELLOW}⚠️  No se detectaron ambos discos físicos /dev/sdb y /dev/sdc, omitiendo creación de pool/datasets...${RESET}"
fi
