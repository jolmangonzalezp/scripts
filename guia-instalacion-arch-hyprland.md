# Guía de instalación — Arch Linux + Hyprland

## Requisitos

- USB booteable de Arch Linux
- Conexión a internet (WiFi o Ethernet)
- Disco limpio (instalación única) O Windows ya instalado (dual boot)

---

## 1. Arrancar desde el USB

Conecta el USB, enciende el equipo y entra a la BIOS/UEFI (F2, F12, Supr). Selecciona el USB como primer dispositivo de arranque.

Al iniciar el USB, selecciona **"Arch Linux install medium (x86_64, UEFI)"**.

Verifica que estés en modo UEFI:

```bash
ls /sys/firmware/efi/efivars
# Si el directorio existe → estás en modo UEFI ✓
```

## 2. Conectar a internet

### WiFi

```bash
iwctl                           # Entra al interactive wireless controller
[iwd]# device list              # Muestra las interfaces (ej: wlan0)
[iwd]# station wlan0 scan
[iwd]# station wlan0 get-networks
[iwd]# station wlan0 connect "NombreDeTuRed"
# Ingresa la contraseña cuando pida
[iwd]# exit
```

### Verificar conexión

```bash
ping -c 3 archlinux.org
```

## 3. Actualizar reloj del sistema

```bash
timedatectl set-ntp true
timedatectl status
```

## 4. Particionado

### Identificar el disco

```bash
lsblk
```

El disco NVMe principal suele ser `/dev/nvme0n1`.

### Modo A: Arch Linux solo (disco limpio)

```bash
parted /dev/nvme0n1 mklabel gpt
parted /dev/nvme0n1 mkpart ESP fat32 1MB 501MB
parted /dev/nvme0n1 set 1 esp on
mkfs.vfat -F32 /dev/nvme0n1p1

parted /dev/nvme0n1 mkpart primary 501MB 100%
partprobe /dev/nvme0n1
```

Resultado:

| Partición | Tamaño | Sistema de archivos | Propósito |
|---|---|---|---|
| `nvme0n1p1` | 500 MB | vfat | ESP |
| `nvme0n1p2` | resto | LUKS → Btrfs | Arch Linux |

### Modo B: Dual boot (Windows + Arch)

Windows ya debe estar instalado y ocupando parte del disco.

Desde Windows: **Administración de discos → botón derecho en C: → Reducir volumen → dejar ~226 GB sin asignar**.

Luego, desde el USB de Arch:

```bash
# El espacio libre ya está disponible, solo crear la partición LUKS
# (el script install-arch-dualboot.sh lo hace automáticamente)
```

Resultado:

| Partición | Sistema de archivos | Propósito |
|---|---|---|
| `nvme0n1p1` | vfat | ESP (compartida) |
| `nvme0n1p2` | MSR | Microsoft Reserved |
| `nvme0n1p3` | NTFS | Windows |
| `nvme0n1p4` | LUKS → Btrfs | Arch Linux |

## 5. Cifrado LUKS + Btrfs

```bash
# Crear y abrir LUKS
cryptsetup luksFormat --type luks2 /dev/nvme0n1p2   # o nvme0n1p4 en dual boot
cryptsetup open /dev/nvme0n1p2 cryptroot

# Formatear Btrfs
mkfs.btrfs -L arch /dev/mapper/cryptroot

# Crear subvolúmenes
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@swap
umount /mnt

# Montar subvolúmenes
BTRFS_OPTS="compress=zstd:3,noatime,ssd,space_cache=v2"

mount -o subvol=@,$BTRFS_OPTS /dev/mapper/cryptroot /mnt
mount --mkdir -o subvol=@home,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/home
mount --mkdir -o subvol=@snapshots,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/.snapshots
mount --mkdir -o subvol=@var_log,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/var/log
mount --mkdir -o subvol=@swap,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/swap

# Montar ESP
mount /dev/nvme0n1p1 /mnt/boot
```

## 6. Swapfile

```bash
truncate -s 0 /mnt/swap/.swapfile
chattr +C /mnt/swap/.swapfile
fallocate -l 16G /mnt/swap/.swapfile
chmod 600 /mnt/swap/.swapfile
mkswap /mnt/swap/.swapfile
```

## 7. Instalación base

```bash
pacstrap -K /mnt base base-devel linux linux-headers \
  linux-zen linux-zen-headers linux-firmware amd-ucode \
  btrfs-progs sudo vim neovim networkmanager git \
  man-db man-pages bluez bluez-utils \
  pipewire pipewire-pulse wireplumber \
  zram-generator snapper snap-pac grub-btrfs plymouth \
  acpid ntp reflector openssh zsh zsh-completions fastfetch

genfstab -L /mnt >> /mnt/etc/fstab
```

## 8. Configuración del sistema

```bash
arch-chroot /mnt /bin/bash
```

Dentro del chroot:

```bash
# Zona horaria (ajusta tu ciudad)
ln -sf /usr/share/zoneinfo/America/Bogota /etc/localtime
hwclock --systohc

# Locale
echo "es_CO.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=es_CO.UTF-8" > /etc/locale.conf
echo "KEYMAP=la-latin1" > /etc/vconsole.conf

# Hostname
echo "lenovo-arch" > /etc/hostname

# Hosts
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   lenovo-arch.localdomain lenovo-arch
EOF

# mkinitcpio (hooks con sd-encrypt + plymouth)
sed -i 's/^HOOKS=.*/HOOKS=(base systemd plymouth autodetect microcode modconf kms keyboard keymap sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
sed -i 's/^MODULES=(.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Plymouth
plymouth-set-default-theme spinner

# Contraseña de root
passwd

# Crear usuario
useradd -m -G wheel,storage,power,audio,video,lp jolman
passwd jolman
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel

# Shell
chsh -s /usr/bin/zsh jolman

# ZRAM
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

# Límites de journald
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/limits.conf <<EOF
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=10M
EOF

# Habilitar servicios
systemctl enable NetworkManager.service
systemctl enable bluetooth.service
systemctl enable fstrim.timer
systemctl enable acpid.service
systemctl enable ntpd.service
systemctl enable plymouth-start.service
```

## 9. Bootloader (systemd-boot)

```bash
# Obtener UUID de LUKS
cryptsetup luksUUID /dev/nvme0n1p2   # o nvme0n1p4 en dual boot
# Ejemplo: abc12345-...

bootctl install

# loader.conf
cat > /boot/loader/loader.conf <<EOF
timeout 5
console-mode max
default @saved
EOF

# Arch entry
cat > /boot/loader/entries/arch.conf <<EOF
title   ARCHLINUX
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=TU_UUID=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 rd.systemd.show_status=auto
EOF

# Zen entry (opcional)
cat > /boot/loader/entries/arch-zen.conf <<EOF
title   ARCHLINUX-ZEN
linux   /vmlinuz-linux-zen
initrd  /amd-ucode.img
initrd  /initramfs-linux-zen.img
options rd.luks.name=TU_UUID=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 rd.systemd.show_status=auto
EOF
```

### Dual boot: entrada para Windows

```bash
cat > /boot/loader/entries/windows.conf <<EOF
title   Windows 11
efi     /EFI/Microsoft/Boot/bootmgfw.efi
EOF
```

## 10. Snapper

```bash
snapper -c root create-config /
chmod 750 /.snapshots
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer
```

Salir del chroot:

```bash
exit
umount -R /mnt
reboot
```

Al reiniciar, systemd-boot mostrará el menú. Selecciona **ARCHLINUX**, ingresa la contraseña LUKS y luego la de usuario.

---

## 11. Instalación de Hyprland

Ya dentro de Arch, instala el entorno gráfico:

```bash
# Hyprland y componentes base
sudo pacman -S hyprland hypridle hyprlock \
  waybar wofi rofi alacritty \
  dunst swww waypaper \
  wlogout grim slurp \
  xdg-desktop-portal-hyprland \
  polkit-gnome gnome-keyring \
  qt5-wayland qt6-wayland qt5ct qt6ct \
  nautilus pcmanfm \
  network-manager-applet \
  brightnessctl pavucontrol playerctl \
  ttf-jetbrains-mono ttf-fira-code ttf-hack \
  ttf-cascadia-code-nerd ttf-meslo-nerd \
  noto-fonts noto-fonts-emoji otf-firamono-nerd
```

### Archivos de configuración

Rutas principales:

| Archivo | Propósito |
|---|---|
| `~/.config/hypr/hyprland.conf` | Configuración del compositor |
| `~/.config/hypr/hypridle.conf` | Gestión de suspensión |
| `~/.config/hypr/hyprlock.conf` | Pantalla de bloqueo |
| `~/.config/waybar/config.jsonc` | Barra de estado |
| `~/.config/waybar/style.css` | Estilo de la barra |
| `~/.config/wofi/config` | Menú de aplicaciones |
| `~/.config/wofi/style.css` | Estilo del menú |
| `~/.config/alacritty/alacritty.toml` | Terminal |
| `~/.config/rofi/config.rasi` | Lanzador alternativo |
| `~/.config/dunst/dunstrc` | Notificaciones |
| `~/.config/wlogout/layout` | Menú de apagado |

### Autostart

Agrega esto al final de `hyprland.conf`:

```
exec-once = swww-daemon &
exec-once = waypaper --restore &
exec-once = waybar &
exec-once = dunst &
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &
exec-once = gnome-keyring-daemon --start --components=secrets
exec-once = nm-applet &
```

### Variables de entorno

```
env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = XDG_SESSION_DESKTOP,Hyprland
env = MOZ_ENABLE_WAYLAND,1
env = QT_QPA_PLATFORMTHEME,qt6ct
env = QT_QPA_PLATFORM,wayland;xcb
env = QT_AUTO_SCREEN_SCALE_FACTOR,1
env = GDK_SCALE,1
```

### Iniciar Hyprland

```bash
# Desde la terminal
Hyprland

# O configurar greetd para inicio automático
sudo systemctl enable greetd.service
```

---

## 12. Restaurar backup

```bash
BACKUP=~/Backups/config-2025-05-30_201249

# Desktop (hypr, waybar, rofi, etc.)
rsync -a "$BACKUP"/30-desktop/ ~/.config/

# NVim
rsync -a "$BACKUP"/40-dev/nvim/config/ ~/.config/nvim/
rsync -a "$BACKUP"/40-dev/nvim/share/ ~/.local/share/nvim/

# Shell
rsync -a "$BACKUP"/10-shell/dotfiles/ ~/
rsync -a "$BACKUP"/10-shell/oh-my-zsh-custom/ ~/.oh-my-zsh/custom/
rsync -a "$BACKUP"/10-shell/scripts/ ~/.scripts/

# Git/SSH
rsync -a "$BACKUP"/20-git/.gitconfig ~/
rsync -a "$BACKUP"/20-git/.ssh/ ~/.ssh/
chmod 600 ~/.ssh/id_ed25519

# Seguridad
rsync -a "$BACKUP"/60-security/gnupg/ ~/.gnupg/
rsync -a "$BACKUP"/60-security/keyrings/ ~/.local/share/keyrings/

# Pulse audio
rsync -a "$BACKUP"/50-apps/pulse/ ~/.config/pulse/

# Paquetes
sudo pacman -S --needed - < "$BACKUP"/00-system/package-list/pacman-Qe.txt

# Sistema (sudo)
sudo rsync -a "$BACKUP"/00-system/etc/ /etc/
```

---

## 13. Referencia rápida — Atajos de Hyprland

| Atajo | Acción |
|---|---|
| `SUPER + Enter` | Terminal (alacritty) |
| `SUPER + Q` | Cerrar ventana |
| `SUPER + Space` | Lanzador de apps (rofi) |
| `SUPER + B` | Navegador |
| `SUPER + V` | VS Code |
| `SUPER + F` | Alternar flotante |
| `SUPER + [1-9]` | Cambiar workspace |
| `SUPER + SHIFT + [1-9]` | Mover ventana a workspace |
| `SUPER + flechas` | Navegar entre ventanas |
| `SUPER + mouse(arrastrar)` | Mover ventana |
| `SUPER + Escape` | Menú de apagado (wlogout) |
| `Print` | Captura de pantalla completa |
| `SUPER + Print` | Captura de área |
| `XF86AudioRaiseVolume` | Subir volumen |
| `XF86AudioLowerVolume` | Bajar volumen |
| `XF86AudioMute` | Silenciar audio |
| `XF86MonBrightnessUp/Down` | Brillo de pantalla |

---

## 14. Solución de problemas comunes

### No arranca Hyprland

```bash
# Verificar que el GPU esté correcto
lspci | grep VGA

# Verificar drivers
lsmod | grep amdgpu  # para AMD
lsmod | grep i915    # para Intel

# Ejecutar Hyprland manualmente para ver errores
Hyprland
```

### Sin audio

```bash
# Verificar estado de PipeWire
systemctl --user status pipewire.service
systemctl --user status wireplumber.service

# Instalar si falta
sudo pacman -S pipewire pipewire-pulse wireplumber
```

### WiFi no funciona

```bash
# Verificar NetworkManager
nmcli device status
nmtui  # Interfaz TUI para conectarse
```

### Sin sonido en Bluetooth

```bash
# Verificar que el servicio esté activo
systemctl status bluetooth.service

# Instalar paquetes
sudo pacman -S bluez bluez-utils blueman

# Conectar desde blueman-applet
```
