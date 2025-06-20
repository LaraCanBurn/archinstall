# archinstall
# Detalles de instalación

Este script automatiza la instalación de Arch Linux con cifrado completo, LVM, ZFS, entorno gráfico y medidas de hardening. Está pensado para facilitar y estandarizar el proceso de instalación en sistemas nuevos.

## ¿Para qué sirve este script?

- Automatiza el particionado, cifrado y configuración de discos.
- Instala y configura el sistema base de Arch Linux.
- Añade soporte para ZFS y RAID.
- Configura usuarios, red, entorno gráfico (XFCE) y utilidades esenciales.
- Aplica medidas de seguridad y personalización.

## Instalación rápida

Puedes descargar el repositorio y descomprimirlo usando:

```bash
curl -s -v -L -o archinstall-main.zip https://github.com/LaraCanBurn/archinstall/archive/refs/heads/main.zip
unzip archinstall-main.zip
cd archinstall-main/archinstall
```
Da permisos al script principal: 

```bash
chmod +x archinstall.sh
```

Luego ejecuta el script principal:

```bash
bash archinstall.sh
```
Tras iniciar sesion con tu usuario: 

```bash
sudo systemctl start lightdm 
```

