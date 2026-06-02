# =====================
# GLOBAL ALIASES (ArchInstall)
# =====================

# Evita que el archivo se cargue más de una vez
[ -n "$__ARCHINSTALL_ALIASES_LOADED" ] && return
export __ARCHINSTALL_ALIASES_LOADED=1


# =====================
# 📂 LISTADO DE ARCHIVOS
# =====================

# ls mejorado: muestra permisos, tamaños, ocultos y colores
alias ls='ls --color=auto -lah'

# equivalente a ls completo (por comodidad)
alias ll='ls -lah'

# lista archivos ocultos sin saturar tanto como -lah
alias la='ls -A'


# =====================
# 📁 NAVEGACIÓN ENTRE DIRECTORIOS
# =====================

# subir un nivel
alias ..='cd ..'

# subir dos niveles
alias ...='cd ../..'

# subir tres niveles
alias ....='cd ../../..'


# =====================
# 💾 INFORMACIÓN DEL SISTEMA
# =====================

# uso de disco en formato legible (GB, MB)
alias df='df -h'

# tamaño de archivos/directorios en formato legible
alias du='du -h'

# uso de memoria RAM en formato legible
alias free='free -h'


# =====================
# 🔍 BÚSQUEDA
# =====================

# resalta coincidencias al usar grep
alias grep='grep --color=auto'


# =====================
# 🌐 RED
# =====================

# comando ip con colores (más legible)
alias ip='ip -c'

# muestra puertos abiertos y procesos asociados
alias ports='ss -tulpen'

# muestra tu IP pública (solo si curl está disponible)
command -v curl >/dev/null 2>&1 && alias myip='curl -s ifconfig.me'


# =====================
# 🧠 PROCESOS
# =====================

# busca procesos por nombre (ej: psg nginx)
alias psg='ps aux | grep -i'


# =====================
# 📜 LOGS DEL SISTEMA
# =====================

# muestra errores recientes del sistema (systemd)
command -v journalctl >/dev/null 2>&1 && alias logs='journalctl -xe'

# muestra logs en tiempo real (modo seguimiento)
command -v journalctl >/dev/null 2>&1 && alias logf='journalctl -f'


# =====================
# 🧹 UTILIDAD GENERAL
# =====================

# limpia la pantalla (tipo Windows "cls")
alias cls='clear'

# acceso rápido al historial de comandos
alias h='history'


# =====================
# 🔐 SEGURIDAD (EVITAR ERRORES)
# =====================

# pide confirmación antes de borrar archivos
alias rm='rm -i'

# pide confirmación antes de sobrescribir al copiar
alias cp='cp -i'

# pide confirmación antes de sobrescribir al mover
alias mv='mv -i'


# =====================
# 📦 GESTIÓN DE PAQUETES (PACMAN)
# =====================

# actualizar sistema completo (Arch Linux)
command -v pacman >/dev/null 2>&1 && alias update='sudo pacman -Syu'

# instalar paquetes
command -v pacman >/dev/null 2>&1 && alias install='sudo pacman -S'

# eliminar paquetes y dependencias
command -v pacman >/dev/null 2>&1 && alias remove='sudo pacman -Rns'

# buscar paquetes en repositorios
command -v pacman >/dev/null 2>&1 && alias search='pacman -Ss'


# =====================
# 🧠 DEBUG / UTILIDADES EXTRA
# =====================

# muestra cada ruta del PATH en una línea distinta
alias path='echo -e ${PATH//:/\\n}'

# muestra fecha y hora actual en formato claro
alias now='date +"%Y-%m-%d %H:%M:%S"'

