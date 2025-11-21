#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# zfs-create-pool.sh
# Crea o actualiza un pool ZFS cifrado (LUKS + RAIDZ) con auto-montaje persistente.
# Funciona en Arch Linux y similares.
#
# Uso:
#   sudo ./zfs-create-pool.sh          # salida solo por consola, sin logs en disco
#   sudo ./zfs-create-pool.sh --log    # además guarda /var/log/zfs-create-pool.log
# ------------------------------------------------------------------------------

set -euo pipefail

# =====================
# COLORES
# =====================
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

# =====================
# CONFIG GLOBAL
# =====================

POOL_NAME="zdata"
RAID_LEVEL="raidz1"            # raidz1, raidz2, raidz3, mirror
DISKS=("/dev/sdb" "/dev/sdc")  # ajusta según tu hardware / VM
KEY_DIR="/etc/luks-keys"
DATASETS=(home var srv tmp root)

# Logging
LOG_TO_FILE=0                  # 0 = NO escribir a fichero (por defecto), 1 = sí
LOG_FILE="/var/log/zfs-create-pool.log"

# =====================
# PARÁMETROS CLI
# =====================

usage() {
  local me
  me="$(basename "$0")"
  cat <<EOF
Uso: sudo $me [opciones]

Opciones:
  --log        Además de la consola, guarda mensajes en $LOG_FILE
  -h, --help   Muestra esta ayuda y sale

Sin opciones, el script solo usa salida por consola y no guarda logs en disco.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log)
      LOG_TO_FILE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}[ERROR]${RESET} Opción desconocida: $1"
      usage
      exit 1
      ;;
  esac
done

# =====================
# FUNCIONES AUXILIARES
# =====================

_log_write_file() {
  local level="$1"
  local msg="$2"
  if [ "$LOG_TO_FILE" -eq 1 ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%F %T') [$level] $msg" >> "$LOG_FILE"
  fi
}

log() {
  echo -e "${CYAN}[INFO]${RESET} $1"
  _log_write_file "INFO" "$1"
}

success() {
  echo -e "${GREEN}[OK]  ${RESET} $1"
  _log_write_file "OK" "$1"
}

warn() {
  echo -e "${YELLOW}[WARN]${RESET} $1"
  _log_write_file "WARN" "$1"
}

error() {
  echo -e "${RED}[ERR] ${RESET} $1"
  _log_write_file "ERROR" "$1"
}

run() {
  echo -e "${CYAN}[RUN] ${RESET}$*"
  "$@"
}

# =====================
# COMPROBACIONES INICIALES
# =====================

echo -e "${CYAN}========================================================${RESET}"
echo -e "${CYAN}   Script ZFS cifrado (${POOL_NAME}) - RAID: ${RAID_LEVEL}${RESET}"
echo -e "${CYAN}========================================================${RESET}"

if ! command -v zpool >/dev/null 2>&1; then
  error "ZFS no está instalado. Instala 'zfs-dkms' y 'zfs-utils'."
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  error "Debes ejecutar este script como root o con sudo."
  exit 1
fi

log "Discos configurados: ${DISKS[*]}"
if [ "$LOG_TO_FILE" -eq 1 ]; then
  log "Logging a fichero habilitado: $LOG_FILE"
else
  log "Logging persistente desactivado (solo consola)."
fi

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

declare -A MAPS    # dev físico -> /dev/mapper/crypt-xxx
declare -a MAPPERS # lista de nombres de mapeo (crypt-sdb, crypt-sdc, ...)

# =====================
# PASO 1/5: LUKS + KEYFILES
# =====================

echo -e "${CYAN}=== PASO 1/5: Preparando LUKS y keyfiles ==================${RESET}"

for dev in "${DISKS[@]}"; do
  name="crypt-$(basename "$dev")"
  keyfile="$KEY_DIR/$(basename "$dev").key"

  log "Procesando disco ${dev} → mapeo ${name}"

  if cryptsetup isLuks "$dev" >/dev/null 2>&1; then
    warn "$dev ya está cifrado con LUKS, no se reformatea."
  else
    log "Creando LUKS en ${dev}"
    run dd if=/dev/random of="$keyfile" bs=1 count=64 status=none
    run chmod 600 "$keyfile"
    run cryptsetup luksFormat "$dev" "$keyfile" --type luks2 --batch-mode
    success "LUKS creado en ${dev}"
  fi

  if ! cryptsetup status "$name" >/dev/null 2>&1; then
    log "Abriendo ${dev} como ${name}"
    run cryptsetup open "$dev" "$name" --key-file "$keyfile"
    success "Mapa ${name} abierto."
  else
    warn "${name} ya estaba abierto."
  fi

  MAPS["$dev"]="/dev/mapper/$name"
  MAPPERS+=("$name")
done

# =====================
# PASO 2/5: POOL ZFS
# =====================

echo -e "${CYAN}=== PASO 2/5: Creando o actualizando el pool ZFS ==========${RESET}"

if zpool list "$POOL_NAME" >/dev/null 2>&1; then
  success "Pool ${POOL_NAME} ya existe. Comprobando si hay discos nuevos..."

  existing_disks=($(zpool status "$POOL_NAME" | awk '/raidz|mirror/{f=1; next} f && NF{print $1}' | sort))
  new_devices=()

  for dev in "${DISKS[@]}"; do
    map_dev="${MAPS[$dev]}"           # /dev/mapper/crypt-sdX
    base_map="$(basename "$map_dev")" # crypt-sdX
    if ! printf '%s\n' "${existing_disks[@]}" | grep -q "^${base_map}\$"; then
      new_devices+=("$map_dev")
    fi
  done

  if [ ${#new_devices[@]} -gt 0 ]; then
    warn "Detectados nuevos dispositivos para el pool: ${new_devices[*]}"
    warn "Se intentará 'zpool add' (añadir vdevs simples; no cambia el nivel RAID existente)."
    for new_dev in "${new_devices[@]}"; do
      log "Añadiendo ${new_dev} al pool ${POOL_NAME}"
      if ! run zpool add "$POOL_NAME" "$new_dev"; then
        warn "No se pudo añadir $new_dev automáticamente. Revisa manualmente."
      else
        success "${new_dev} añadido al pool ${POOL_NAME}."
      fi
    done
    run zpool status "$POOL_NAME"
  else
    success "No hay nuevos discos que añadir al pool ${POOL_NAME}."
  fi

else
  log "Creando nuevo pool ${POOL_NAME} con tipo ${RAID_LEVEL}"
  run zpool create -o ashift=12 \
    -O compression=lz4 \
    -O atime=off \
    -O xattr=sa \
    -O acltype=posixacl \
    -O mountpoint=/zdata \
    -O cachefile=/etc/zfs/zpool.cache \
    "$POOL_NAME" "$RAID_LEVEL" "${MAPS[@]}"
  success "Pool ${POOL_NAME} creado correctamente."
fi

run zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"

# =====================
# PASO 3/5: DATASETS
# =====================

echo -e "${CYAN}=== PASO 3/5: Creando datasets y puntos de montaje =========${RESET}"

create_dataset() {
  local name="$1"
  local mountpoint="$2"

  if zfs list "${POOL_NAME}/${name}" >/dev/null 2>&1; then
    warn "Dataset ${POOL_NAME}/${name} ya existe, se mantiene."
  else
    log "Creando dataset ${POOL_NAME}/${name} → ${mountpoint}"
    run zfs create -o mountpoint="$mountpoint" "${POOL_NAME}/${name}"
    success "Dataset ${POOL_NAME}/${name} creado."
  fi
}

for ds in "${DATASETS[@]}"; do
  case "$ds" in
    tmp)  mp="/tmp"  ;;
    root) mp="/root" ;;
    *)    mp="/${ds}";;
  esac
  create_dataset "$ds" "$mp"
done

if [ -d /tmp ]; then
  run chmod 1777 /tmp
fi

# =====================
# PASO 4/5: SYSTEMD AUTO-IMPORT
# =====================

echo -e "${CYAN}=== PASO 4/5: Configurando auto-import y auto-mount (systemd)${RESET}"

log "Deshabilitando importadores genéricos de ZFS (si existían)..."
run systemctl disable zfs-import-cache.service zfs-import-scan.service || true

log "Habilitando zfs-mount.service y zfs.target..."
run systemctl enable zfs-mount.service zfs.target

CRYPT_UNITS=$(printf 'systemd-cryptsetup@%s.service ' "${MAPPERS[@]}")

SERVICE_FILE="/etc/systemd/system/zfs-import-${POOL_NAME}.service"
log "Creando servicio systemd personalizado: $(basename "$SERVICE_FILE")"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Importar pool ZFS ${POOL_NAME} después de desbloquear LUKS
Requires=${CRYPT_UNITS}
After=${CRYPT_UNITS}
Before=zfs-mount.service

[Service]
Type=oneshot
ExecStart=/usr/bin/zpool import -N ${POOL_NAME}
RemainAfterExit=yes
TimeoutStartSec=90

[Install]
WantedBy=zfs.target
EOF

run systemctl daemon-reload
run systemctl enable "zfs-import-${POOL_NAME}.service"
success "Servicio zfs-import-${POOL_NAME}.service configurado y habilitado."

# =====================
# PASO 5/5: /etc/crypttab
# =====================

echo -e "${CYAN}=== PASO 5/5: Actualizando /etc/crypttab ===================${RESET}"

log "Sincronizando entradas de LUKS en /etc/crypttab (sin mostrar UUIDs por pantalla)."

for dev in "${DISKS[@]}"; do
  name="crypt-$(basename "$dev")"
  keyfile="$KEY_DIR/$(basename "$dev").key"
  uuid=$(cryptsetup luksUUID "$dev")
  if grep -q "$uuid" /etc/crypttab 2>/dev/null; then
    warn "Entrada crypttab para ${name} ya existe, se mantiene."
  else
    echo "${name}  UUID=${uuid}  ${keyfile}  luks" >> /etc/crypttab
    success "Añadida entrada crypttab para ${name}."
  fi
done

# =====================
# RESUMEN FINAL
# =====================

echo -e "${CYAN}=== RESUMEN: ESTADO DEL POOL Y DATASETS ====================${RESET}"
run zpool status
run zfs list

echo -e "${GREEN}========================================================${RESET}"
echo -e "${GREEN}[OK]  Configuración completa. Reinicia el sistema para que el pool${RESET}"
echo -e "${GREEN}      y todos los datasets se importen y monten automáticamente.${RESET}"
echo -e "${GREEN}========================================================${RESET}"

exit 0
