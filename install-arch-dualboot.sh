#!/usr/bin/env bash
set -uo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# install-arch-dualboot.sh
#
# Instalador interactivo de Arch Linux con soporte para:
#   - Arch Linux solo (disco limpio)
#   - Dual boot Windows + Arch (Windows ya instalado, usamos espacio libre)
#
# Uso:  sudo ./install-arch-dualboot.sh
# ═══════════════════════════════════════════════════════════════════════════════

# ── Estética ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'
info()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()   { echo -e "  ${RED}✗${NC} $1"; }
title() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
bail()  { err "$1"; exit 1; }

ask() {
  local prompt="$1" var_name="$2" default="${3:-}"
  local answer
  if [[ -n "$default" ]]; then
    read -rp "  ${prompt} [$default]: " answer
    echo "${answer:-$default}"
  else
    read -rp "  ${prompt}: " answer
    echo "$answer"
  fi
}

confirm() {
  local prompt="$1" default="${2:-s}"
  local answer
  read -rp "  ${prompt} [${default}/n]: " answer
  [[ "${answer:-$default}" == "s" || "${answer:-$default}" == "S" || "${answer:-$default}" == "y" || "${answer:-$default}" == "Y" ]]
}

# Determinar el prefijo de partición según el tipo de disco
# NVMe → nvme0n1p1, SATA → sda1, VirtIO → vda1, MMC → mmcblk0p1
part_name() {
  local disk="$1" num="$2"
  local base
  base=$(basename "$disk")
  if echo "$base" | grep -qE 'nvme[0-9]+n[0-9]+'; then
    echo "${disk}p${num}"
  elif echo "$base" | grep -qE 'mmcblk[0-9]+'; then
    echo "${disk}p${num}"
  else
    echo "${disk}${num}"
  fi
}

# Listar particiones de un disco
list_parts() {
  local disk="$1"
  local base
  base=$(basename "$disk")
  lsblk -n -o NAME "$disk" 2>/dev/null | grep -v "^${base}$" | grep "^${base}" || true
}

select_disk() {
  echo "" >&2
  echo "  Discos disponibles:" >&2
  echo "" >&2
  lsblk -d -n -o NAME,SIZE,MODEL -e 7,11 2>/dev/null | grep -v loop | while read -r line; do
    echo "    /dev/$line" >&2
  done
  echo "" >&2
  local disk
  disk=$(ask "Selecciona el disco" "DISK" "/dev/sda")
  [[ -b "$disk" ]] || bail "El disco $disk no existe"
  echo "$disk"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || bail "Ejecutar como root: sudo $0"

echo -e "\n${CYAN}${BOLD}  Arch Linux Installer${NC}"
echo "  ==================="
echo ""
echo "  Este script instalará Arch Linux con:"
echo "    • Kernel linux + linux-zen"
echo "    • LUKS + Btrfs con subvolúmenes"
echo "    • systemd-boot"
echo "    • Plymouth, ZRAM, Snapper"
echo "    • Soporte dual boot o instalación limpia"
echo ""

# ── Modo ──────────────────────────────────────────────────────────────────────
title "Detectando disco"

DISK=$(select_disk)
DISK_NAME=$(basename "$DISK")

# Detectar particiones existentes
EXISTING_PARTITIONS=$(lsblk -n -o NAME "$DISK" 2>/dev/null | grep -v "^${DISK_NAME}$" | wc -l)
HAS_ESP=false
ESP_PART=""
WINDOWS_PART=""
FREE_SPACE=false

if [[ $EXISTING_PARTITIONS -gt 0 ]]; then
  # Buscar ESP
  for part in $(list_parts "$DISK" | sort); do
    fstype=$(lsblk -n -o FSTYPE "/dev/$part" 2>/dev/null)
    if [[ "$fstype" == "vfat" ]]; then
      # Verificar que sea una ESP (tiene /EFI)
      tmpmount=$(mktemp -d)
      mount "/dev/$part" "$tmpmount" 2>/dev/null && {
        if [[ -d "$tmpmount/EFI" ]]; then
          HAS_ESP=true
          ESP_PART="/dev/$part"
        fi
        umount "$tmpmount" 2>/dev/null
      }
      rmdir "$tmpmount" 2>/dev/null
    fi
    # Detectar Windows (NTFS grande)
    if [[ "$fstype" == "ntfs" ]]; then
      WINDOWS_PART="/dev/$part"
    fi
  done

  # Verificar espacio libre
  if parted -s "$DISK" unit MB print free 2>/dev/null | grep -q "Free Space"; then
    FREE_SPACE=true
  fi
fi

DUAL_BOOT=false
if $HAS_ESP && [[ -n "$WINDOWS_PART" ]]; then
  echo ""
  echo "  Detectado:"
  echo "    ESP:      $ESP_PART"
  echo "    Windows:  $WINDOWS_PART"
  echo ""
  if confirm "¿Modo dual boot (Windows + Arch)?"; then
    DUAL_BOOT=true
    if ! $FREE_SPACE; then
      warn "No se detectó espacio libre en el disco."
      warn "Desde Windows: Administración de discos → reducir C: → dejar ~226 GB libres"
      echo ""
      if ! confirm "¿Ya redujiste la partición de Windows?"; then
        bail "Ejecuta de nuevo el script después de reducir Windows"
      fi
      # Verificar de nuevo
      FREE_SPACE=true
    fi
  fi
fi

if $DUAL_BOOT; then
  info "Modo: Dual boot (Windows + Arch)"
else
  info "Modo: Arch Linux solo"
fi

# ── Información del sistema ───────────────────────────────────────────────────
title "Configuración del sistema"

HOSTNAME=$(ask "Hostname" "HOSTNAME" "lenovo-arch")
USERNAME=$(ask "Usuario" "USERNAME" "jolman")

while true; do
  read -rsp "  Contraseña (oculta): " ROOT_PASS
  echo ""
  read -rsp "  Repetir contraseña: " ROOT_PASS2
  echo ""
  [[ "$ROOT_PASS" == "$ROOT_PASS2" && -n "$ROOT_PASS" ]] && break
  err "Las contraseñas no coinciden o están vacías"
done

KEYBOARD=$(ask "Layout de teclado" "KEYBOARD" "la-latin1")
TIMEZONE=$(ask "Zona horaria" "TIMEZONE" "America/Bogota")
LOCALE=$(ask "Locale" "LOCALE" "es_CO.UTF-8")
CREATE_SWAP=false
if confirm "¿Crear swapfile? (ZRAM ya está configurado)" "n"; then
  CREATE_SWAP=true
  SWAP_SIZE=$(ask "Tamaño del swapfile" "SWAP_SIZE" "16G")
fi

echo ""
info "Resumen: hostname=$HOSTNAME user=$USERNAME locale=$LOCALE swap=${SWAP_SIZE:-ninguno}"

# ── Particionado ──────────────────────────────────────────────────────────────
title "Particionado"

if $DUAL_BOOT; then
  # Encontrar el inicio del espacio libre
  FREE_START=$(parted -s "$DISK" unit MB print free 2>/dev/null | awk '/Free Space/ {print $1}' | head -1)
  FREE_END=$(parted -s "$DISK" unit MB print free 2>/dev/null | awk '/Free Space/ {print $2}' | head -1)

  if [[ -z "$FREE_START" || -z "$FREE_END" ]]; then
    bail "No se pudo detectar el espacio libre"
  fi

  FREE_START=$(echo "$FREE_START" | sed 's/MB//')
  FREE_END=$(echo "$FREE_END" | sed 's/MB//')

  info "Espacio libre detectado: ${FREE_START}MB → ${FREE_END}MB"

  PART_NUM=$(list_parts "$DISK" | wc -l)
  PART_NUM=$(( PART_NUM + 1 ))
  PART_LUKS=$(part_name "$DISK" "$PART_NUM")

  parted -s "$DISK" mkpart primary "${FREE_START}MB" "${FREE_END}MB"
  sleep 2
  udevadm settle 2>/dev/null || sleep 2

  info "Partición LUKS creada: $PART_LUKS"
else
  # Arch solo: crear GPT + ESP + LUKS
  info "Creando tabla GPT..."
  parted -s "$DISK" mklabel gpt

  # ESP
  parted -s "$DISK" mkpart ESP fat32 1MB 501MB
  parted -s "$DISK" set 1 esp on
  sleep 1
  ESP_PART=$(part_name "$DISK" 1)
  mkfs.vfat -F32 "$ESP_PART"
  info "ESP creada: $ESP_PART"

  # LUKS
  DISK_BYTES=$(blockdev --getsize64 "$DISK")
  DISK_END=$(echo "$DISK_BYTES" | awk '{printf "%.0f", $1/1024/1024}')
  # Dejar 1MB de margen al final
  DISK_END=$(( DISK_END - 1 ))
  parted -s "$DISK" mkpart primary 501MB "${DISK_END}MB"
  sleep 2
  udevadm settle 2>/dev/null || sleep 2
  PART_LUKS=$(part_name "$DISK" 2)

  info "Partición LUKS creada: $PART_LUKS"
fi

# ── LUKS ──────────────────────────────────────────────────────────────────────
title "Configurando LUKS"

echo ""
echo "  Vas a configurar la contraseña de cifrado de disco."
echo "  Puede ser diferente a la de usuario."
echo ""

while true; do
  read -rsp "  Contraseña LUKS (oculta): " LUKS_PASS
  echo ""
  read -rsp "  Repetir LUKS: " LUKS_PASS2
  echo ""
  [[ "$LUKS_PASS" == "$LUKS_PASS2" && -n "$LUKS_PASS" ]] && break
  err "Las contraseñas no coinciden o están vacías"
done

echo "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$PART_LUKS" -d -
echo "$LUKS_PASS" | cryptsetup open "$PART_LUKS" cryptroot -d -

LUKS_UUID=$(cryptsetup luksUUID "$PART_LUKS")
info "LUKS configurado (UUID: $LUKS_UUID)"

# ── Btrfs ─────────────────────────────────────────────────────────────────────
title "Formateando Btrfs"

mkfs.btrfs -L arch /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@swap

umount /mnt

info "Subvolúmenes Btrfs creados"

# ── Montaje ───────────────────────────────────────────────────────────────────
title "Montando particiones"

BTRFS_OPTS="compress=zstd:3,noatime,ssd,space_cache=v2"

mount -o subvol=@,$BTRFS_OPTS /dev/mapper/cryptroot /mnt
mount --mkdir -o subvol=@home,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/home
mount --mkdir -o subvol=@snapshots,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/.snapshots
mount --mkdir -o subvol=@var_log,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/var/log
if $CREATE_SWAP; then
  mount --mkdir -o subvol=@swap,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/swap
fi

mount "$ESP_PART" /mnt/boot

info "Particiones montadas"

# ── SWAP ──────────────────────────────────────────────────────────────────────
title "Swapfile"

if $CREATE_SWAP; then
  SWAP_BYTES=$(numfmt --from=iec "$SWAP_SIZE" 2>/dev/null || echo "16G")
  truncate -s 0 /mnt/swap/.swapfile
  chattr +C /mnt/swap/.swapfile
  fallocate -l "$SWAP_BYTES" /mnt/swap/.swapfile || dd if=/dev/zero of=/mnt/swap/.swapfile bs=1M count=$(( ${SWAP_SIZE%G} * 1024 )) status=progress
  chmod 600 /mnt/swap/.swapfile
  mkswap /mnt/swap/.swapfile
  info "Swapfile creado ($SWAP_SIZE)"
else
  info "Swapfile omitido — usando ZRAM"
fi

# ── Pacstrap ──────────────────────────────────────────────────────────────────
title "Instalando base"

PACSTRAP_PKGS=(
  base base-devel
  linux linux-headers
  linux-zen linux-zen-headers
  linux-firmware
  amd-ucode
  btrfs-progs
  sudo vim neovim
  networkmanager
  git
  man-db man-pages
  bluez bluez-utils
  pipewire pipewire-pulse wireplumber
  zram-generator
  snapper snap-pac grub-btrfs
  plymouth
  acpid ntp
  reflector openssh
  zsh zsh-completions
  fastfetch
)

pacstrap -K /mnt "${PACSTRAP_PKGS[@]}"

info "Paquetes base instalados"

# ── Fstab ─────────────────────────────────────────────────────────────────────
title "Configurando sistema"

genfstab -L /mnt >> /mnt/etc/fstab

# Arreglar /swap/.swapfile en fstab si se creó
if $CREATE_SWAP && ! grep -q "swapfile" /mnt/etc/fstab 2>/dev/null; then
  echo "/swap/.swapfile none swap defaults 0 0" >> /mnt/etc/fstab
fi

# ── Chroot setup ──────────────────────────────────────────────────────────────
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

# Timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Locale
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYBOARD" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Root password
echo "root:$ROOT_PASS" | chpasswd

# User
useradd -m -G wheel,storage,power,audio,video,lp "$USERNAME"
echo "$USERNAME:$ROOT_PASS" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel

# mkinitcpio — hooks con sd-encrypt + plymouth
sed -i 's/^HOOKS=.*/HOOKS=(base systemd plymouth autodetect microcode modconf kms keyboard keymap sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

# Añadir btrfs a MODULES si no está
if ! grep -q "btrfs" /etc/mkinitcpio.conf; then
  sed -i 's/^MODULES=(.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
fi

mkinitcpio -P

# Plymouth theme
plymouth-set-default-theme spinner 2>/dev/null || true

# systemd-boot
bootctl install

# loader.conf
cat > /boot/loader/loader.conf <<LOADER
timeout 5
console-mode max
default @saved
LOADER

# Arch entry
ROOT_UUID=$LUKS_UUID
cat > /boot/loader/entries/arch.conf <<ARCH
title   ARCHLINUX
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options rd.luks.name=\${ROOT_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 rd.systemd.show_status=auto
ARCH

# Zen entry
cat > /boot/loader/entries/arch-zen.conf <<ZEN
title   ARCHLINUX-ZEN
linux   /vmlinuz-linux-zen
initrd  /amd-ucode.img
initrd  /initramfs-linux-zen.img
options rd.luks.name=\${ROOT_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 rd.systemd.show_status=auto
ZEN

# Windows entry (solo si hay Windows)
if [[ -n "$WINDOWS_PART" ]] && [[ -f /boot/EFI/Microsoft/Boot/bootmgfw.efi ]]; then
  cat > /boot/loader/entries/windows.conf <<WIN
title   Windows 11
efi     /EFI/Microsoft/Boot/bootmgfw.efi
WIN
  echo "  Entry Windows creada"
fi

# ZRAM
cat > /etc/systemd/zram-generator.conf <<ZRAM
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

# Journald limits (como tenías)
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/limits.conf <<JOURNAL
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=10M
JOURNAL

# Enable services
systemctl enable NetworkManager.service
systemctl enable bluetooth.service
systemctl enable acpid.service
systemctl enable ntpd.service
systemctl enable fstrim.timer
systemctl enable paccache.timer 2>/dev/null || true
systemctl enable reflector.timer 2>/dev/null || true

# Plymouth
systemctl enable plymouth-start.service 2>/dev/null || true

# Shell para el usuario
chsh -s /usr/bin/zsh "$USERNAME"
EOF

info "Configuración del sistema completada"

# ── Snapper ───────────────────────────────────────────────────────────────────
title "Configurando Snapper"

arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

# Root snapper config
snapper -c root create-config /
chmod 750 /.snapshots
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

# Snapper before/after pacman (snap-pac ya lo maneja)
EOF

info "Snapper configurado"

# ── Resumen ───────────────────────────────────────────────────────────────────
title "Resumen final"

echo ""
echo "  ${BOLD}Instalación completada${NC}"
echo ""
echo "  Discos:"
lsblk "$DISK" -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | sed 's/^/    /'
echo ""

if $DUAL_BOOT; then
  echo "  ${BOLD}Dual boot listo${NC}"
  echo "  Al reiniciar, systemd-boot mostrará:"
  echo "    1. ARCHLINUX"
  echo "    2. ARCHLINUX-ZEN"
  echo "    3. Windows 11"
else
  echo "  ${BOLD}Arch Linux solo${NC}"
  echo "  Al reiniciar, systemd-boot mostrará:"
  echo "    1. ARCHLINUX"
  echo "    2. ARCHLINUX-ZEN"
fi
echo ""
echo "  ${YELLOW}⚠ RECUERDA:${NC}"
echo "  • La contraseña LUKS se pide al arrancar"
echo "  • La contraseña de usuario es para entrar al sistema"
echo "  • Para restaurar tu backup:"
echo "    rsync -a /ruta/al/backup/30-desktop/ ~/.config/"
echo "    rsync -a /ruta/al/backup/10-shell/dotfiles/ ~/"
echo "    pacman -S --needed - < /ruta/00-system/package-list/pacman-Qe.txt"
echo ""
echo -e "  ${GREEN}${BOLD}✅ Instalación finalizada.${NC}"
echo "  Puedes reiniciar con:  umount -R /mnt && reboot"
echo ""
