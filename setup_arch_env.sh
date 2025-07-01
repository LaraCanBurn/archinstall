#!/bin/bash

# Verifica permisos
if [[ $EUID -ne 0 ]]; then
  echo "Este script debe ejecutarse como root (usa sudo)." 
  exit 1
fi

# Actualiza el sistema
echo "Actualizando el sistema..."
pacman -Syu --noconfirm

# Instala paquetes esenciales
echo "Instalando paquetes esenciales..."
pacman -S --noconfirm bspwm sxhkd picom rofi polybar feh kitty zsh bat lsd neovim git curl unzip

# Instala Powerlevel10k
echo "Instalando Powerlevel10k..."
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git /usr/share/zsh-theme-powerlevel10k
echo 'source /usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme' >> /etc/zsh/zshrc

# Configura ZSH como shell por defecto para el usuario actual
echo "Cambiando shell por defecto a ZSH para el usuario actual..."
chsh -s /bin/zsh $SUDO_USER

# Extrae los dotfiles desde el archivo local del repositorio
echo "Extrayendo dotfiles locales..."
unzip "$(dirname "$0")/arch_dotfiles.zip" -d /home/$SUDO_USER/

# Da permisos de ejecución al script de bspwm
chmod +x /home/$SUDO_USER/.config/bspwm/bspwmrc

# Cambia el propietario de los archivos extraídos
chown -R $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.config
chown $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.zshrc

# Instala y configura NVChad
echo "Instalando NVChad..."
git clone https://github.com/NvChad/NvChad /home/$SUDO_USER/.config/nvim --depth 1
chown -R $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.config/nvim

# Mensaje final
echo "¡Listo! Reinicia tu sesión e inicia el entorno gráfico con bspwm."
