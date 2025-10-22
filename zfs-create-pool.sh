#!/usr/bin/env bash
set -euo pipefail

# zfs-create-pool.sh — automatiza LUKS + ZFS (idempotente, con modo dry-run)
# Características:
# - Comprueba binarios necesarios
# - Opciones: --dry-run, --yes, --use-keyfiles, --mkinitcpio
# - Crea keyfiles seguros (si se pide) y los añade a LUKS
# - Añade entradas a /etc/crypttab usando luksUUID (evita duplicados)
# - Edita opcionalmente /etc/mkinitcpio.conf para incluir 'encrypt' y 'zfs'
# - Abre dispositivos LUKS, crea pool/datasets de forma idempotente
# - Crea unidad systemd para importar el pool tras desbloqueo

# Colores para salida
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

SDB=${SDB:-/dev/sdb}
SDC=${SDC:-/dev/sdc}
MAP1=/dev/mapper/crypt-zfs1
MAP2=/dev/mapper/crypt-zfs2
POOL_NAME=${POOL_NAME:-zdata}
DRY_RUN=0
ASSUME_YES=0
USE_KEYFILES=0
MKINITCPIO=0
ARG_COUNT_INIT=$#
INTERACTIVE=0

usage() {
  cat <<EOF
Usage: $0 [options]
Options:
  --dry-run         Mostrar acciones sin ejecutar
  --yes             No pedir confirmación para acciones destructivas
  --use-keyfiles    Crear y usar keyfiles en /etc/luks-keys
  --mkinitcpio      Modificar /etc/mkinitcpio.conf y ejecutar mkinitcpio -P
  --auto            Ejecutar en modo completamente automático (sin pausas, asume yes)
  --sdb <device>    Disco 1 (default: /dev/sdb)
  --sdc <device>    Disco 2 (default: /dev/sdc)
  -h, --help        Mostrar esta ayuda
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
      --dry-run) DRY_RUN=1; shift;;
      --yes) ASSUME_YES=1; shift;;
      --use-keyfiles) USE_KEYFILES=1; shift;;
      --mkinitcpio) MKINITCPIO=1; shift;;
      --auto) INTERACTIVE=0; ASSUME_YES=1; shift;;
    --sdb) SDB=$2; shift 2;;
    --sdc) SDC=$2; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo -e "${YELLOW}Aviso: argumento desconocido: $1${RESET}"; usage; exit 1;;
  esac
done

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "[DRY-RUN] $*"
  else
    echo -e "[RUN] $*"
    eval "$@"
  fi
}

# Ejecuta un comando, captura su salida y código de salida, y la muestra.
# Mantiene comportamiento de dry-run. Usar para pasos que quieres inspeccionar.
run_and_show() {
  local cmd="$*"
  echo -e "${CYAN}=> Ejecutando: $cmd${RESET}"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "[DRY-RUN] $cmd"
    return 0
  fi
  local output
  output=$(eval "$cmd" 2>&1) || true
  local status=$?
  if [ -n "$output" ]; then
    echo "----- salida -----"
    echo "$output"
    echo "----- fin salida -----"
  else
    echo "(sin salida)"
  fi
  if [ $status -ne 0 ]; then
    echo -e "${RED}Comando terminó con código $status${RESET}"
  else
    echo -e "${GREEN}Comando OK${RESET}"
  fi
  return $status
}

# Pausa interactiva entre pasos (solo si se lanzó sin argumentos)
pause() {
  if [ "$INTERACTIVE" -eq 1 ]; then
    read -r -p $'Presiona Enter para continuar (Ctrl+C para abortar)\n'
  fi
}

confirm() {
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  read -r -p "$1 [y/N]: " ans
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) return 0;;
    *) return 1;;
  esac
}

check_bin() {
  for b in "$@"; do
    if ! command -v "$b" >/dev/null 2>&1; then
      echo -e "${RED}Error: $b no está instalado o no está en PATH.${RESET}" >&2
      exit 1
    fi
  done
}

# Comprobar si un dispositivo tiene particiones o sistemas de ficheros montados
check_device_safety() {
  for dev in "$SDB" "$SDC"; do
    if [ ! -b "$dev" ]; then
      echo -e "${RED}Error: dispositivo $dev no encontrado.${RESET}"
      exit 1
    fi
    # ¿tiene particiones? lsblk mostrará hijos
    parts=$(lsblk -no NAME "$dev" | wc -l || true)
    if [ "$parts" -gt 1 ]; then
      echo -e "${YELLOW}Advertencia: $dev parece tener particiones (lsblk muestra $parts líneas).${RESET}"
      if ! confirm "Continuar y usar $dev (puede destruir datos)?"; then
        echo "Abortado por usuario."; exit 1
      fi
    fi
    # ¿tiene sistema de ficheros montado?
    mountpoint=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "$mountpoint" ]; then
      echo -e "${YELLOW}Advertencia: $dev tiene mountpoint(s): $mountpoint${RESET}"
      if ! confirm "Continuar y usar $dev (puede desmontar/matar montajes)?"; then
        echo "Abortado por usuario."; exit 1
      fi
    fi
  done
}

check_bin sudo cryptsetup zpool zfs systemctl
if [ "$MKINITCPIO" -eq 1 ]; then
  check_bin mkinitcpio
fi

# Si no se pasaron argumentos al script, activar modo interactivo (pausas)
if [ "$ARG_COUNT_INIT" -eq 0 ]; then
  INTERACTIVE=1
  echo -e "${CYAN}Modo interactivo activado: el script hará pausas entre pasos para verificación.${RESET}"
fi

# Verificar si el módulo zfs está disponible para el kernel
if ! modinfo zfs >/dev/null 2>&1; then
  cat <<MSG
${YELLOW}Aviso: el módulo kernel 'zfs' no está disponible para tu kernel.${RESET}
Esto significa que no hay módulos ZFS compilados e instalados para el kernel actual.
Sigue estos pasos (Arch Linux / linux-zen como ejemplo):

1) Instala los headers del kernel y DKMS:
   sudo pacman -Syu
   sudo pacman -S --needed base-devel dkms linux-zen-headers
   # ajusta linux-zen-headers si usas otro kernel (linux, linux-lts, ...)

2) Instala ZFS via AUR (recomendado: spl-dkms y zfs-dkms, y zfs-utils):
   # con un ayudante AUR como yay o paru:
   yay -S spl-dkms zfs-dkms zfs-utils
   # o compila manualmente con makepkg desde AUR

3) Forzar compilación DKMS (si es necesario):
   sudo dkms autoinstall

4) Cargar el módulo:
   sudo modprobe zfs

Si prefieres que el script te muestre estas instrucciones en vez del error crudo, ejecuta el script tras instalar zfs.
MSG
  exit 1
fi

pause

echo -e "${CYAN}Inicio de la automatización LUKS+ZFS (pool=${POOL_NAME})${RESET}"

# Cargar módulo zfs si está disponible
if [ "$DRY_RUN" -eq 0 ]; then
  run sudo modprobe zfs || true
  pause
else
  echo -e "[DRY-RUN] modprobe zfs"
fi

# Validar dispositivos
if [ ! -b "$SDB" ] || [ ! -b "$SDC" ]; then
  echo -e "${RED}Error: No se detectaron ambos dispositivos: $SDB y/o $SDC no existen.${RESET}"
  exit 1
fi

echo -e "${CYAN}Dispositivos: $SDB, $SDC${RESET}"

# Opcional: crear keyfiles
pause

# Comprobar seguridad de los dispositivos antes de operaciones destructivas
check_device_safety

KEY_DIR=/etc/luks-keys
KEY_SDB=$KEY_DIR/$(basename "$SDB").key
KEY_SDC=$KEY_DIR/$(basename "$SDC").key
if [ "$USE_KEYFILES" -eq 1 ]; then
  if [ ! -d "$KEY_DIR" ]; then
    run sudo mkdir -p "$KEY_DIR"
    run sudo chmod 700 "$KEY_DIR"
  fi
  for k in "$KEY_SDB" "$KEY_SDC"; do
    if [ ! -f "$k" ]; then
      echo -e "${CYAN}Generando keyfile $k${RESET}"
      run sudo dd if=/dev/urandom of="$k" bs=4096 count=1 status=none
      run sudo chmod 600 "$k"
      run sudo chown root:root "$k"
    else
      echo -e "${YELLOW}Keyfile $k ya existe, se conservará.${RESET}"
    fi
  done
  # Añadir la key a LUKS (intentaremos añadir, si falla pedir intervención)
  if [ "$DRY_RUN" -eq 0 ]; then
    echo -e "${CYAN}Añadiendo keyfiles a LUKS (te pedirá la passphrase si es necesario)...${RESET}"
      pause
    sudo cryptsetup isLuks "$SDB" && sudo cryptsetup luksAddKey "$SDB" "$KEY_SDB" || true
    sudo cryptsetup isLuks "$SDC" && sudo cryptsetup luksAddKey "$SDC" "$KEY_SDC" || true
  else
    echo -e "[DRY-RUN] cryptsetup luksAddKey $SDB $KEY_SDB"
    echo -e "[DRY-RUN] cryptsetup luksAddKey $SDC $KEY_SDC"
  fi
fi

# Obtener UUIDs LUKS
pause

UUID_SDB=$(sudo cryptsetup luksUUID "$SDB" 2>/dev/null || true)
UUID_SDC=$(sudo cryptsetup luksUUID "$SDC" 2>/dev/null || true)

if [ -z "$UUID_SDB" ] || [ -z "$UUID_SDC" ]; then
  echo -e "${YELLOW}Advertencia: uno o ambos dispositivos no devuelven luksUUID. Asegúrate de que son LUKS.${RESET}"
fi

# Backup /etc/crypttab
if [ -f /etc/crypttab ]; then
  run sudo cp /etc/crypttab /etc/crypttab.bak-$(date +%Y%m%d-%H%M%S)
  pause
fi

# Añadir entradas a /etc/crypttab (evitar duplicados por nombre)
# Decidir si usamos keyfile (solo si --use-keyfiles y el archivo existe)
KEYFIELD_SDB=none
KEYFIELD_SDC=none
if [ "$USE_KEYFILES" -eq 1 ]; then
  if [ -f "$KEY_SDB" ]; then
    KEYFIELD_SDB=$KEY_SDB
  else
    echo -e "${YELLOW}Advertencia: se solicitó --use-keyfiles pero $KEY_SDB no existe; se usará passphrase interactiva para $SDB${RESET}"
  fi
  if [ -f "$KEY_SDC" ]; then
    KEYFIELD_SDC=$KEY_SDC
  else
    echo -e "${YELLOW}Advertencia: se solicitó --use-keyfiles pero $KEY_SDC no existe; se usará passphrase interactiva para $SDC${RESET}"
  fi
fi

if [ -n "$UUID_SDB" ]; then
  entry1="crypt-zfs1\tUUID=$UUID_SDB\t$KEYFIELD_SDB\tluks"
else
  entry1="crypt-zfs1\t$SDB\t$KEYFIELD_SDB\tluks"
fi
if [ -n "$UUID_SDC" ]; then
  entry2="crypt-zfs2\tUUID=$UUID_SDC\t$KEYFIELD_SDC\tluks"
else
  entry2="crypt-zfs2\t$SDC\t$KEYFIELD_SDC\tluks"
fi

if ! sudo grep -q -F "crypt-zfs1" /etc/crypttab 2>/dev/null; then
  echo -e "${CYAN}Añadiendo crypt-zfs1 a /etc/crypttab${RESET}"
  run sudo sh -c "printf '%s\n' '$entry1' >> /etc/crypttab"
  pause
else
  echo -e "${YELLOW}Entrada crypt-zfs1 ya existe en /etc/crypttab, omitiendo.${RESET}"
fi
if ! sudo grep -q -F "crypt-zfs2" /etc/crypttab 2>/dev/null; then
  echo -e "${CYAN}Añadiendo crypt-zfs2 a /etc/crypttab${RESET}"
  run sudo sh -c "printf '%s\n' '$entry2' >> /etc/crypttab"
  pause
else
  echo -e "${YELLOW}Entrada crypt-zfs2 ya existe en /etc/crypttab, omitiendo.${RESET}"
fi

# Opcional: actualizar mkinitcpio.conf
if [ "$MKINITCPIO" -eq 1 ]; then
  MKCONF=/etc/mkinitcpio.conf
  pause
  run sudo cp "$MKCONF" "$MKCONF.bak-$(date +%Y%m%d-%H%M%S)"
  # Añadir zfs a MODULES si no existe
  if ! sudo grep -q "MODULES=.*zfs" "$MKCONF" 2>/dev/null; then
    echo -e "${CYAN}Añadiendo 'zfs' a MODULES en $MKCONF${RESET}"
    run sudo sed -i "s/^MODULES=(/MODULES=(zfs /" "$MKCONF" || true
    pause
  fi
  # Asegurar 'encrypt' en HOOKS antes de filesystems
  if ! sudo grep -q "hooks=.*encrypt" "$MKCONF" 2>/dev/null; then
    echo -e "${CYAN}Añadiendo 'encrypt' a HOOKS en $MKCONF${RESET}"
    run sudo sed -i "s/^HOOKS=(\(.*\)filesystems/HOOKS=(\1encrypt filesystems/" "$MKCONF" || true
    pause
  fi
  echo -e "${CYAN}Regenerando initramfs...${RESET}"
  run sudo mkinitcpio -P
  pause
fi

# Intentar abrir los dispositivos si no están mapeados
if [ ! -b "$MAP1" ]; then
  if sudo cryptsetup isLuks "$SDB" >/dev/null 2>&1; then
    echo -e "${CYAN}Abriendo $SDB -> crypt-zfs1${RESET}"
    run sudo cryptsetup open "$SDB" crypt-zfs1 || true
      pause
  else
    echo -e "${YELLOW}Advertencia: $SDB no parece LUKS, omitiendo open.${RESET}"
  fi
fi
if [ ! -b "$MAP2" ]; then
  if sudo cryptsetup isLuks "$SDC" >/dev/null 2>&1; then
    echo -e "${CYAN}Abriendo $SDC -> crypt-zfs2${RESET}"
    run sudo cryptsetup open "$SDC" crypt-zfs2 || true
      pause
  else
    echo -e "${YELLOW}Advertencia: $SDC no parece LUKS, omitiendo open.${RESET}"
  fi
fi

# Esperar a mapeos
for i in {1..10}; do
  if [ -b "$MAP1" ] && [ -b "$MAP2" ]; then
    break
  fi
  pause
  sleep 1
done

if ! [ -b "$MAP1" ] || ! [ -b "$MAP2" ]; then
  echo -e "${RED}Error: No se detectaron ambos mapeos en /dev/mapper (crypt-zfs1/2). Abortando.${RESET}"
  exit 1
  pause
fi

echo -e "${GREEN}Mappers detectados: $(ls -l $MAP1 $MAP2 2>/dev/null)${RESET}"

# Crear zpool si no existe
if sudo zpool list "$POOL_NAME" >/dev/null 2>&1; then
  echo -e "${YELLOW}El pool $POOL_NAME ya existe, omitiendo creación.${RESET}"
  pause
else
  # volver a comprobar seguridad justo antes de crear el pool
  check_device_safety
  echo -e "${CYAN}Creando pool $POOL_NAME en mirror...${RESET}"
  run sudo zpool create -o ashift=12 \
    -O compression=lz4 \
    -O atime=off \
    -O xattr=sa \
    -O acltype=posixacl \
    -O mountpoint=/zdata \
    "$POOL_NAME" mirror "$MAP1" "$MAP2"
fi

# Crear datasets idempotentemente
pause

create_dataset() {
  ds="$1"
  mp="$2"
  if sudo zfs list "$ds" >/dev/null 2>&1; then
    echo -e "${YELLOW}Dataset $ds ya existe, omitiendo.${RESET}"
    pause
  else
    echo -e "${CYAN}Creando dataset $ds con mountpoint=$mp${RESET}"
    run sudo zfs create -o mountpoint="$mp" "$POOL_NAME/$ds"
    pause
  fi
}

create_dataset home /home
create_dataset var /var
create_dataset srv /srv
create_dataset tmp /tmp
pause

# Asegurar permisos tmp
for i in {1..10}; do
  [ -d /zdata/tmp ] && break
  sleep 1
done
if [ -d /zdata/tmp ]; then
  run sudo chmod 1777 /zdata/tmp
  pause
else
  echo -e "${YELLOW}Advertencia: /zdata/tmp no existe tras crear dataset tmp.${RESET}"
fi
create_dataset root /root

echo -e "${GREEN}Pool y datasets preparados.${RESET}"

pause

# Habilitar servicios ZFS
for svc in zfs-import-cache zfs-import-scan zfs-mount zfs.target; do
  echo -e "${CYAN}Habilitando servicio $svc${RESET}"
  run sudo systemctl enable "$svc"
  pause
done

# Crear unidad systemd para importar el pool después del desbloqueo
pause

SERVICE_FILE=/etc/systemd/system/zfs-import-${POOL_NAME}.service
if [ -f "$SERVICE_FILE" ]; then
  echo -e "${YELLOW}Servicio $SERVICE_FILE ya existe, omitiendo creación.${RESET}"
else
  echo -e "${CYAN}Creando unidad systemd $SERVICE_FILE${RESET}"
  run sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Importar pool ZFS ${POOL_NAME} después de desbloquear LUKS
Requires=systemd-cryptsetup@crypt-zfs1.service systemd-cryptsetup@crypt-zfs2.service
After=systemd-cryptsetup@crypt-zfs1.service systemd-cryptsetup@crypt-zfs2.service

[Service]
Type=oneshot
ExecStart=/usr/bin/zpool import ${POOL_NAME}
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF
  run sudo systemctl daemon-reload
  run sudo systemctl enable "zfs-import-${POOL_NAME}"
fi

pause

echo -e "${GREEN}Automatización completada. Revisa /etc/crypttab y el servicio systemd antes de reiniciar.${RESET}"

echo -e "${CYAN}Comandos de verificación sugeridos:${RESET}"
echo "  ls /dev/mapper/crypt-zfs*"
echo "  sudo systemctl status systemd-cryptsetup@crypt-zfs1.service systemd-cryptsetup@crypt-zfs2.service"
echo "  sudo systemctl status zfs-import-${POOL_NAME}"
echo "  sudo zpool status"
echo "  sudo zfs list"
pause
