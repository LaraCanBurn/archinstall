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
Para abrir los discos zfs: 

```bash
sudo cryptsetup open /dev/sdb crypt-zfs1
sudo cryptsetup open /dev/sdc crypt-zfs2
ls /dev/mapper/crypt-zfs*
```
Para que el pool ZFS y los datasets se monten automáticamente después de reiniciar, sigue estos pasos:

1. **Configura `/etc/crypttab`**  
   Añade estas líneas para que los discos cifrados se abran al arrancar:

   - **Si usas contraseña interactiva:**
     ```
     crypt-zfs1   /dev/sdb   none   luks
     crypt-zfs2   /dev/sdc   none   luks
     ```
   - **Si usas clave en archivo (recomendado para servidores):**
     ```
     crypt-zfs1   /dev/sdb   /etc/luks-keys/sdb.key   luks
     crypt-zfs2   /dev/sdc   /etc/luks-keys/sdc.key   luks
     ```
     Asegúrate de que los archivos de clave existen y tienen los permisos adecuados.

2. **Edita /etc/mkinitcpio.conf y agrega zfs en la línea de MODULES**
    Después recarga con sudo mkinitcpio -P 


3. **Habilita los servicios ZFS en el arranque**
   ```bash
   sudo systemctl enable zfs-import-cache
   sudo systemctl enable zfs-mount
   sudo systemctl enable zfs.target
   sudo systemctl enable zfs-import-scan
   ```

4. **No añadas los puntos de montaje ZFS a `/etc/fstab`**  
   ZFS monta los datasets automáticamente.

5. **Verifica tras reiniciar**
   ```bash
   sudo zpool status
   sudo zfs list
   ```
6. **Si esto no funciona, prueba a montarlo manualmente**
    ```bash
    sudo zpool import zdata
    ```
Con esto, tus discos cifrados se abrirán y el pool/datasets ZFS se montarán automáticamente en cada arranque.