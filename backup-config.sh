#!/usr/bin/env bash
set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
HOME_DIR="/home/jolman"
BACKUP_BASE="$HOME_DIR/Backups"
DATE=$(date +%Y-%m-%d_%H%M%S)
BACKUP_DIR="$BACKUP_BASE/config-$DATE"
DRY_RUN=false
DO_TAR=false
FULL=false

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }
title() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ── Help ───────────────────────────────────────────────────────────────────────
show_help() {
  cat <<EOF
Uso: backup-config.sh [OPCIONES]

Opciones:
  --help       Muestra esta ayuda
  --dry-run    Solo muestra qué se respaldaría (no copia nada)
  --tar        Además empaqueta el backup en .tar.zst
  --full       Incluye datos opcionales pesados (Chromium, Steam, Telegram, etc.)

Sin opciones: backup esencial (configs + shell + git/ssh + desktop + nvim + pulse + seguridad)
EOF
  exit 0
}

# ── Args ───────────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --help)    show_help ;;
    --dry-run) DRY_RUN=true ;;
    --tar)     DO_TAR=true ;;
    --full)    FULL=true ;;
    *)         echo "Opción desconocida: $arg"; show_help ;;
  esac
done

# ── Rsync wrapper ──────────────────────────────────────────────────────────────
do_rsync() {
  local src="$1" dst="$2"
  shift 2
  local extra=("$@")

  if $DRY_RUN; then
    # Collapse repeated slashes for a cleaner log
    local src_norm="${src//\/\//\/}"
    local dst_norm="${dst//\/\//\/}"
    echo "    rsync ${extra[*]} $src_norm → $dst_norm"
    return
  fi

  mkdir -p "$(dirname "$dst")"
  rsync -a --info=progress2 "${extra[@]}" "$src" "$dst" 2>/dev/null || true
}

# ── Start ──────────────────────────────────────────────────────────────────────
if $DRY_RUN; then
  echo -e "\n${YELLOW}═══ DRY RUN — no se copiará nada ═══${NC}\n"
else
  mkdir -p "$BACKUP_DIR"
  echo -e "\n${CYAN}═══ Backup → $BACKUP_DIR ═══${NC}"
fi

# ───────────────────────────────────────────────────────────────────────────────
# 00-system
# ───────────────────────────────────────────────────────────────────────────────
title "00 — System"

SYS_DST="$BACKUP_DIR/00-system"

declare -a SYS_FILES=(
  /etc/pacman.conf
  /etc/mkinitcpio.conf
  /etc/fstab
  /etc/greetd/config.toml
  /etc/vconsole.conf
  /etc/systemd/journald.conf
  /etc/systemd/zram-generator.conf
  /etc/plymouth/plymouthd.conf
  /etc/snapper/configs/root
)

for f in "${SYS_FILES[@]}"; do
  [[ -f "$f" ]] && do_rsync "$f" "$SYS_DST$f"
done

for d in /etc/docker /etc/polkit-1/rules.d /etc/sudoers.d; do
  [[ -d "$d" ]] && do_rsync "$d/" "$SYS_DST$d/"
done

if [[ -d /boot/loader ]]; then
  do_rsync "/boot/loader/" "$BACKUP_DIR/00-system/boot-loader/"
fi

if ! $DRY_RUN; then
  mkdir -p "$BACKUP_DIR/00-system/package-list"
  pacman -Qe --noconfirm 2>/dev/null | sort > "$BACKUP_DIR/00-system/package-list/pacman-Qe.txt" || true
  pacman -Qm --noconfirm 2>/dev/null | sort > "$BACKUP_DIR/00-system/package-list/pacman-Qm.txt" || true
  info "Package lists exported"
fi

# ───────────────────────────────────────────────────────────────────────────────
# 10-shell
# ───────────────────────────────────────────────────────────────────────────────
title "10 — Shell"

SHELL_DST="$BACKUP_DIR/10-shell"

for f in .zshrc .zprofile .p10k.zsh .bashrc .bash_profile; do
  [[ -f "$HOME_DIR/$f" ]] && do_rsync "$HOME_DIR/$f" "$SHELL_DST/dotfiles/$f"
done

[[ -d "$HOME_DIR/.oh-my-zsh/custom" ]] && do_rsync \
  "$HOME_DIR/.oh-my-zsh/custom/" "$SHELL_DST/oh-my-zsh-custom/" \
  --exclude='*.zwc'

[[ -d "$HOME_DIR/.scripts" ]] && do_rsync "$HOME_DIR/.scripts/" "$SHELL_DST/scripts/"

# ───────────────────────────────────────────────────────────────────────────────
# 20-git
# ───────────────────────────────────────────────────────────────────────────────
title "20 — Git"

GIT_DST="$BACKUP_DIR/20-git"

[[ -f "$HOME_DIR/.gitconfig" ]] && do_rsync "$HOME_DIR/.gitconfig" "$GIT_DST/.gitconfig"

if [[ -d "$HOME_DIR/.ssh" ]]; then
  for f in config id_ed25519 id_ed25519.pub authorized_keys; do
    [[ -f "$HOME_DIR/.ssh/$f" ]] && do_rsync "$HOME_DIR/.ssh/$f" "$GIT_DST/.ssh/$f"
  done
fi

# ───────────────────────────────────────────────────────────────────────────────
# 30-desktop
# ───────────────────────────────────────────────────────────────────────────────
title "30 — Desktop"

DESKTOP_DST="$BACKUP_DIR/30-desktop"

for dir in hypr waybar rofi wofi alacritty dunst wlogout nitrogen waypaper; do
  src="$HOME_DIR/.config/$dir"
  [[ -d "$src" ]] && do_rsync "$src/" "$DESKTOP_DST/$dir/"
done

# ───────────────────────────────────────────────────────────────────────────────
# 40-dev
# ───────────────────────────────────────────────────────────────────────────────
title "40 — Dev / NVim"

NVIM_DST="$BACKUP_DIR/40-dev/nvim"

[[ -d "$HOME_DIR/.config/nvim" ]] && do_rsync "$HOME_DIR/.config/nvim/" "$NVIM_DST/config/"

if [[ -d "$HOME_DIR/.local/share/nvim" ]]; then
  do_rsync "$HOME_DIR/.local/share/nvim/" "$NVIM_DST/share/" \
    --exclude='.cache' --exclude='shada' --exclude='swap' --exclude='backup' \
    --exclude='view' --exclude='session'
fi

# ───────────────────────────────────────────────────────────────────────────────
# 50-apps
# ───────────────────────────────────────────────────────────────────────────────
title "50 — Apps / Pulse"

[[ -d "$HOME_DIR/.config/pulse" ]] && do_rsync "$HOME_DIR/.config/pulse/" "$BACKUP_DIR/50-apps/pulse/"

# ───────────────────────────────────────────────────────────────────────────────
# 60-security
# ───────────────────────────────────────────────────────────────────────────────
title "60 — Security"

SEC_DST="$BACKUP_DIR/60-security"

[[ -d "$HOME_DIR/.gnupg" ]] && do_rsync "$HOME_DIR/.gnupg/" "$SEC_DST/gnupg/"
[[ -d "$HOME_DIR/.local/share/keyrings" ]] && do_rsync "$HOME_DIR/.local/share/keyrings/" "$SEC_DST/keyrings/"
[[ -d "$HOME_DIR/.local/share/kwalletd" ]] && do_rsync "$HOME_DIR/.local/share/kwalletd/" "$SEC_DST/kwallet/"

# ───────────────────────────────────────────────────────────────────────────────
# 70-fonts
# ───────────────────────────────────────────────────────────────────────────────
title "70 — Fonts list"

if ! $DRY_RUN; then
  mkdir -p "$BACKUP_DIR/70-fonts"
  fc-list ': family' 2>/dev/null | sort -u > "$BACKUP_DIR/70-fonts/fonts-list.txt"
  info "Font list saved ($(wc -l < "$BACKUP_DIR/70-fonts/fonts-list.txt") families)"
fi

# ───────────────────────────────────────────────────────────────────────────────
# 80-optional (solo con --full)
# ───────────────────────────────────────────────────────────────────────────────
if $FULL; then
  title "80 — Optional (full)"

  OPT_DST="$BACKUP_DIR/80-optional"

  [[ -d "$HOME_DIR/.config/chromium" ]] && do_rsync "$HOME_DIR/.config/chromium/" "$OPT_DST/chromium/" \
    --exclude='Cache' --exclude='Code Cache' --exclude='GPUCache' \
    --exclude='DawnGraphiteCache' --exclude='DawnWebGPUCache' \
    --exclude='GrShaderCache' --exclude='GraphiteDawnCache' \
    --exclude='Crash Reports' --exclude='BrowserMetrics*'

  [[ -d "$HOME_DIR/.local/share/Steam" ]] && do_rsync "$HOME_DIR/.local/share/Steam/" "$OPT_DST/steam/" \
    --exclude='steamapps/downloading' --exclude='steamapps/temp' \
    --exclude='steamapps/shadercache' --exclude='steamapps/workshop' \
    --exclude='logs' --exclude='cache'

  [[ -d "$HOME_DIR/.local/share/TelegramDesktop" ]] && do_rsync \
    "$HOME_DIR/.local/share/TelegramDesktop/" "$OPT_DST/telegram/"

  [[ -d "$HOME_DIR/.local/share/claude" ]] && do_rsync \
    "$HOME_DIR/.local/share/claude/" "$OPT_DST/claude/"

  [[ -d "$HOME_DIR/.local/share/waydroid" ]] && do_rsync \
    "$HOME_DIR/.local/share/waydroid/" "$OPT_DST/waydroid/"
fi

# ───────────────────────────────────────────────────────────────────────────────
# Manifest
# ───────────────────────────────────────────────────────────────────────────────
if ! $DRY_RUN; then
  title "Writing MANIFEST.md"

  {
    echo "# Backup Config — $DATE"
    echo
    echo "## Sistema"
    echo "- Host: $(cat /etc/hostname 2>/dev/null || echo '?')"
    echo "- OS:  $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
    echo "- Kernel: $(uname -r)"
    echo
    echo "## Contenido"
    du -sh "$BACKUP_DIR"/*/ 2>/dev/null | while read -r line; do echo "- $line"; done
    echo
    echo "## Paquetes instalados"
    echo "- Explícitos: $(wc -l < "$BACKUP_DIR/00-system/package-list/pacman-Qe.txt" 2>/dev/null || echo 0)"
    echo "- AUR: $(wc -l < "$BACKUP_DIR/00-system/package-list/pacman-Qm.txt" 2>/dev/null || echo 0)"
    echo
    echo "## Fuentes"
    echo "- Familias: $(wc -l < "$BACKUP_DIR/70-fonts/fonts-list.txt" 2>/dev/null || echo 0)"
  } > "$BACKUP_DIR/MANIFEST.md"

  info "MANIFEST.md written"
fi

# ───────────────────────────────────────────────────────────────────────────────
# Tar
# ───────────────────────────────────────────────────────────────────────────────
if $DO_TAR && ! $DRY_RUN; then
  title "Packaging"
  TAR_FILE="$BACKUP_BASE/config-$DATE.tar.zst"
  tar -I 'zstd -19' -cf "$TAR_FILE" -C "$BACKUP_BASE" "config-$DATE"
  info "Packaged → $TAR_FILE ($(du -h "$TAR_FILE" | cut -f1))"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo
if $DRY_RUN; then
  warn "Dry-run — no se copió nada"
else
  info "Backup completo → $BACKUP_DIR"
  du -sh "$BACKUP_DIR" 2>/dev/null
fi
echo
