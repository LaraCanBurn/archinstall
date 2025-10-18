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

  # Intenta abrir los mapeos si no existen
  if [ ! -b /dev/mapper/crypt-zfs1 ]; then
    echo -e "${YELLOW}Intentando abrir /dev/sdb como crypt-zfs1...${RESET}"
    sudo cryptsetup open /dev/sdb crypt-zfs1 || true
  fi
  if [ ! -b /dev/mapper/crypt-zfs2 ]; then
    echo -e "${YELLOW}Intentando abrir /dev/sdc como crypt-zfs2...${RESET}"
    sudo cryptsetup open /dev/sdc crypt-zfs2 || true
  fi

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

      usage() {
        cat <<EOF
      Usage: $0 [options]
      Options:
        --dry-run         Mostrar acciones sin ejecutar
        --yes             No pedir confirmación para acciones destructivas
        --use-keyfiles    Crear y usar keyfiles en /etc/luks-keys
        --mkinitcpio      Modificar /etc/mkinitcpio.conf y ejecutar mkinitcpio -P
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

      check_bin sudo cryptsetup zpool zfs systemctl
      if [ "$MKINITCPIO" -eq 1 ]; then
        check_bin mkinitcpio
      fi

      echo -e "${CYAN}Inicio de la automatización LUKS+ZFS (pool=${POOL_NAME})${RESET}"

      # Cargar módulo zfs si está disponible
      if [ "$DRY_RUN" -eq 0 ]; then
        sudo modprobe zfs || true
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
          sudo cryptsetup isLuks "$SDB" && sudo cryptsetup luksAddKey "$SDB" "$KEY_SDB" || true
          sudo cryptsetup isLuks "$SDC" && sudo cryptsetup luksAddKey "$SDC" "$KEY_SDC" || true
        else
          echo -e "[DRY-RUN] cryptsetup luksAddKey $SDB $KEY_SDB"
          echo -e "[DRY-RUN] cryptsetup luksAddKey $SDC $KEY_SDC"
        fi
      fi

      # Obtener UUIDs LUKS
      UUID_SDB=$(sudo cryptsetup luksUUID "$SDB" 2>/dev/null || true)
      UUID_SDC=$(sudo cryptsetup luksUUID "$SDC" 2>/dev/null || true)

      if [ -z "$UUID_SDB" ] || [ -z "$UUID_SDC" ]; then
        echo -e "${YELLOW}Advertencia: uno o ambos dispositivos no devuelven luksUUID. Asegúrate de que son LUKS.${RESET}"
      fi

      # Backup /etc/crypttab
      if [ -f /etc/crypttab ]; then
        run sudo cp /etc/crypttab /etc/crypttab.bak-$(date +%Y%m%d-%H%M%S)
      fi

      # Añadir entradas a /etc/crypttab (evitar duplicados por nombre)
      if [ -n "$UUID_SDB" ]; then
        entry1="crypt-zfs1	UUID=$UUID_SDB	${KEY_SDB:-none}	luks"
      else
        entry1="crypt-zfs1	$SDB	${KEY_SDB:-none}	luks"
      fi
      if [ -n "$UUID_SDC" ]; then
        entry2="crypt-zfs2	UUID=$UUID_SDC	${KEY_SDC:-none}	luks"
      else
        entry2="crypt-zfs2	$SDC	${KEY_SDC:-none}	luks"
      fi

      if ! sudo grep -q -F "crypt-zfs1" /etc/crypttab 2>/dev/null; then
        echo -e "${CYAN}Añadiendo crypt-zfs1 a /etc/crypttab${RESET}"
        run sudo sh -c "printf '%s\n' '$entry1' >> /etc/crypttab"
      else
        echo -e "${YELLOW}Entrada crypt-zfs1 ya existe en /etc/crypttab, omitiendo.${RESET}"
      fi
      if ! sudo grep -q -F "crypt-zfs2" /etc/crypttab 2>/dev/null; then
        echo -e "${CYAN}Añadiendo crypt-zfs2 a /etc/crypttab${RESET}"
        run sudo sh -c "printf '%s\n' '$entry2' >> /etc/crypttab"
      else
        echo -e "${YELLOW}Entrada crypt-zfs2 ya existe en /etc/crypttab, omitiendo.${RESET}"
      fi

      # Opcional: actualizar mkinitcpio.conf
      if [ "$MKINITCPIO" -eq 1 ]; then
        MKCONF=/etc/mkinitcpio.conf
        run sudo cp "$MKCONF" "$MKCONF.bak-$(date +%Y%m%d-%H%M%S)"
        # Añadir zfs a MODULES si no existe
        if ! sudo grep -q "MODULES=.*zfs" "$MKCONF" 2>/dev/null; then
          echo -e "${CYAN}Añadiendo 'zfs' a MODULES en $MKCONF${RESET}"
          run sudo sed -i "s/^MODULES=(/MODULES=(zfs /" "$MKCONF" || true
        fi
        # Asegurar 'encrypt' en HOOKS antes de filesystems
        if ! sudo grep -q "hooks=.*encrypt" "$MKCONF" 2>/dev/null; then
          echo -e "${CYAN}Añadiendo 'encrypt' a HOOKS en $MKCONF${RESET}"
          run sudo sed -i "s/^HOOKS=(\(.*\)filesystems/HOOKS=(\1encrypt filesystems/" "$MKCONF" || true
        fi
        echo -e "${CYAN}Regenerando initramfs...${RESET}"
        run sudo mkinitcpio -P
      fi

      # Intentar abrir los dispositivos si no están mapeados
      if [ ! -b "$MAP1" ]; then
        if sudo cryptsetup isLuks "$SDB" >/dev/null 2>&1; then
          echo -e "${CYAN}Abriendo $SDB -> crypt-zfs1${RESET}"
          run sudo cryptsetup open "$SDB" crypt-zfs1 || true
        else
          echo -e "${YELLOW}Advertencia: $SDB no parece LUKS, omitiendo open.${RESET}"
        fi
      fi
      if [ ! -b "$MAP2" ]; then
        if sudo cryptsetup isLuks "$SDC" >/dev/null 2>&1; then
          echo -e "${CYAN}Abriendo $SDC -> crypt-zfs2${RESET}"
          run sudo cryptsetup open "$SDC" crypt-zfs2 || true
        else
          echo -e "${YELLOW}Advertencia: $SDC no parece LUKS, omitiendo open.${RESET}"
        fi
      fi

      # Esperar a mapeos
      for i in {1..10}; do
        if [ -b "$MAP1" ] && [ -b "$MAP2" ]; then
          break
        fi
        sleep 1
      done

      if ! [ -b "$MAP1" ] || ! [ -b "$MAP2" ]; then
        echo -e "${RED}Error: No se detectaron ambos mapeos en /dev/mapper (crypt-zfs1/2). Abortando.${RESET}"
        exit 1
      fi

      echo -e "${GREEN}Mappers detectados: $(ls -l $MAP1 $MAP2 2>/dev/null)${RESET}"

      # Crear zpool si no existe
      if sudo zpool list "$POOL_NAME" >/dev/null 2>&1; then
        echo -e "${YELLOW}El pool $POOL_NAME ya existe, omitiendo creación.${RESET}"
      else
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
      create_dataset() {
        ds="$1"
        mp="$2"
        if sudo zfs list "$ds" >/dev/null 2>&1; then
          echo -e "${YELLOW}Dataset $ds ya existe, omitiendo.${RESET}"
        else
          echo -e "${CYAN}Creando dataset $ds con mountpoint=$mp${RESET}"
          run sudo zfs create -o mountpoint="$mp" "$POOL_NAME/$ds"
        fi
      }

      create_dataset home /home
      create_dataset var /var
      create_dataset srv /srv
      create_dataset tmp /tmp
      # Asegurar permisos tmp
      for i in {1..10}; do
        [ -d /zdata/tmp ] && break
        sleep 1
      done
      if [ -d /zdata/tmp ]; then
        run sudo chmod 1777 /zdata/tmp
      else
        echo -e "${YELLOW}Advertencia: /zdata/tmp no existe tras crear dataset tmp.${RESET}"
      fi
      create_dataset root /root

      echo -e "${GREEN}Pool y datasets preparados.${RESET}"

      # Habilitar servicios ZFS
      for svc in zfs-import-cache zfs-import-scan zfs-mount zfs.target; do
        echo -e "${CYAN}Habilitando servicio $svc${RESET}"
        run sudo systemctl enable "$svc"
      done

      # Crear unidad systemd para importar el pool después del desbloqueo
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

      echo -e "${GREEN}Automatización completada. Revisa /etc/crypttab y el servicio systemd antes de reiniciar.${RESET}"

      echo -e "${CYAN}Comandos de verificación sugeridos:${RESET}"
      echo "  ls /dev/mapper/crypt-zfs*"
      echo "  sudo systemctl status systemd-cryptsetup@crypt-zfs1.service systemd-cryptsetup@crypt-zfs2.service"
      echo "  sudo systemctl status zfs-import-${POOL_NAME}"
      echo "  sudo zpool status"
      echo "  sudo zfs list"
