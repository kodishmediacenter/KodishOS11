#!/bin/bash
# =============================================================================
#  Kodish OS 11 - Media Center (Kodi + LXDE)
#  Instalador para Arch Linux (UEFI)
#
#  Principais mudanças em relação ao Kodish OS 10:
#   - Foco em vídeo: Kodi como sessão principal (autologin), LXDE como extra
#   - Sem Steam/Wine/lib32 (nada de multilib)
#   - Não faz mais "pacman -Syu" no ISO live (evita estourar a RAM / cowspace)
#   - Escolha do disco pelo usuário (nunca apaga o pendrive de instalação)
#   - Senha pedida na instalação (sem senhas fixas), root bloqueado, SSH desligado
#   - /kodish pertence ao root (755); só /kodish/log é gravável pelo grupo kodish
#   - Valida os pacotes ANTES de apagar o disco
#   - set -e também dentro do chroot
#   - Microcode e drivers de vídeo detectados automaticamente
#   - zram no lugar de swap, Plymouth com hook correto
# =============================================================================
set -Eeuo pipefail
trap 'echo -e "\n\e[0;31m[ERRO]\e[m Falha na linha $LINENO. Instalação interrompida." >&2' ERR

# --- Configuração -------------------------------------------------------------
# IMPORTANTE: troque "main" por um commit/tag específico para fixar a versão
# dos scripts baixados (evita que mudanças futuras no repositório afetem a ISO).
REPO_REF="main"
REPO_RAW="https://raw.githubusercontent.com/kodishmediacenter/Kodish-OS-10/${REPO_REF}"
POS_SCRIPTS=(flatpaks.sh instalar_nyaa.sh hw.sh instalar-kodix.sh)
USUARIO="kodish"
HOSTNAME_NOVO="kodish"

verde() { printf "\e[0;32m%s\e[m\n" "$*"; }
aviso() { printf "\e[0;33m[AVISO]\e[m %s\n" "$*" >&2; }

clear
verde "[===============================================================]"
echo  "++++++++++ Bem-vindo à instalação do Kodish OS 11 (Media Center) ++++++++++"
verde "[===============================================================]"

# --- Verificações iniciais ----------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Execute como root (no ISO live do Arch)."; exit 1; }
[[ -d /sys/firmware/efi ]] || { echo "Este instalador exige boot em modo UEFI."; exit 1; }
ping -c1 -W3 archlinux.org &>/dev/null || { echo "Sem internet. Conecte-se (iwctl / nmcli) e tente de novo."; exit 1; }

loadkeys br-abnt2 || true
timedatectl set-ntp true

# --- Mirrors (antes de qualquer download) ------------------------------------
systemctl stop reflector.service 2>/dev/null || true
if command -v reflector &>/dev/null; then
  reflector --country Brazil,Chile,Argentina,"United States" --age 24 \
            --protocol https --sort rate --latest 15 \
            --save /etc/pacman.d/mirrorlist || aviso "reflector falhou; usando mirrors atuais."
fi

# Apenas sincroniza as bases (NÃO atualiza o live: evita lotar a RAM do ISO)
pacman -Sy --noconfirm

# --- Detecção de hardware -----------------------------------------------------
CPU_VENDOR=$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')
case "$CPU_VENDOR" in
  GenuineIntel) UCODE=(intel-ucode) ;;
  AuthenticAMD) UCODE=(amd-ucode) ;;
  *)            UCODE=() ;;
esac

GPU_INFO=$(lspci -nn | grep -Ei 'vga|3d|display' || true)
GPU_PKGS=(mesa vulkan-icd-loader libva-utils)
HAS_NVIDIA=0
if grep -qi 'nvidia' <<<"$GPU_INFO"; then
  HAS_NVIDIA=1
  GPU_PKGS+=(nvidia-open nvidia-open-lts nvidia-utils libva-nvidia-driver)
  aviso "NVIDIA detectada. nvidia-open exige GPU Turing ou mais nova (GTX 16xx/RTX)."
  aviso "Para placas mais antigas será preciso um driver legado após a instalação."
fi
grep -qi 'intel' <<<"$GPU_INFO" && GPU_PKGS+=(intel-media-driver vulkan-intel)
grep -Eqi 'amd|ati|radeon' <<<"$GPU_INFO" && GPU_PKGS+=(libva-mesa-driver mesa-vdpau vulkan-radeon)
echo "CPU: ${CPU_VENDOR:-desconhecida} | GPU: ${GPU_INFO:-não detectada}"

# --- Listas de pacotes --------------------------------------------------------
# Obrigatórios: se algum não existir, aborta ANTES de apagar o disco
PACOTES=(
  base linux linux-lts linux-firmware sudo vim nano
  grub efibootmgr dosfstools mtools e2fsprogs
  networkmanager bluez bluez-utils
  # Kodi e players
  kodi mpv ffmpeg yt-dlp libcec
  # Áudio
  pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils pavucontrol
  # Rede e compartilhamentos
  samba cifs-utils nfs-utils avahi nss-mdns openssh
  # Discos
  ntfs-3g exfatprogs udisks2 gvfs gvfs-smb polkit
  # Desktop leve (sessão de manutenção)
  xorg-server xorg-xinit xorg-xrandr xf86-input-libinput
  lxde-gtk3 lightdm lightdm-gtk-greeter network-manager-applet
  # Fontes e utilitários
  noto-fonts noto-fonts-emoji noto-fonts-cjk ttf-liberation ttf-dejavu
  firefox flatpak gparted file-roller unzip p7zip git base-devel fuse2
  curl wget jq zenity cronie pciutils reflector plymouth zram-generator
  xdg-user-dirs
  "${UCODE[@]}"
)
# Opcionais: se não existirem no repositório, são ignorados com aviso
OPCIONAIS=(
  kodi-addon-inputstream-adaptive firefox-i18n-pt-br unrar
  "${GPU_PKGS[@]}"
)

faltando=()
for p in "${PACOTES[@]}"; do
  pacman -Si "$p" &>/dev/null || pacman -Sg "$p" &>/dev/null || faltando+=("$p")
done
if ((${#faltando[@]})); then
  echo "Pacotes obrigatórios não encontrados: ${faltando[*]}"
  echo "Nada foi alterado no disco. Ajuste a lista e tente novamente."
  exit 1
fi
for p in "${OPCIONAIS[@]}"; do
  if pacman -Si "$p" &>/dev/null; then PACOTES+=("$p"); else aviso "pacote opcional ignorado: $p"; fi
done

# --- Escolha do disco ---------------------------------------------------------
BOOT_SRC=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
LIVE_DISK=""
if [[ -n "$BOOT_SRC" ]]; then
  PK=$(lsblk -no PKNAME "$BOOT_SRC" 2>/dev/null | head -n1 || true)
  [[ -n "$PK" ]] && LIVE_DISK="/dev/$PK"
fi

echo
echo "Discos disponíveis:"
lsblk -dpno NAME,SIZE,TRAN,MODEL -e 1,7,11
[[ -n "$LIVE_DISK" ]] && echo "(O disco $LIVE_DISK contém o instalador e não pode ser escolhido.)"
echo
read -rp "Digite o disco de destino (ex.: /dev/sda ou /dev/nvme0n1): " DISCO

[[ -b "$DISCO" && "$(lsblk -dno TYPE "$DISCO")" == "disk" ]] || { echo "Disco inválido."; exit 1; }
[[ "$DISCO" != "$LIVE_DISK" ]] || { echo "Esse é o disco do instalador. Escolha outro."; exit 1; }

echo
lsblk "$DISCO"
echo
read -rp "TODOS OS DADOS EM $DISCO SERÃO APAGADOS! Digite APAGAR para continuar: " CONFIRMA
[[ "$CONFIRMA" == "APAGAR" ]] || { echo "Cancelado."; exit 1; }

# --- Senha do usuário ---------------------------------------------------------
while true; do
  read -rsp "Defina a senha do usuário '$USUARIO': " SENHA; echo
  read -rsp "Confirme a senha: " SENHA2; echo
  [[ -n "$SENHA" && "$SENHA" == "$SENHA2" ]] && break
  echo "As senhas estão vazias ou não conferem. Tente novamente."
done

# --- Particionamento ----------------------------------------------------------
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
wipefs -af "$DISCO"

parted -s "$DISCO" mklabel gpt
parted -s "$DISCO" mkpart ESP fat32 1MiB 1025MiB
parted -s "$DISCO" set 1 esp on
parted -s "$DISCO" mkpart primary ext4 1025MiB 100%
partprobe "$DISCO"
udevadm settle
sleep 1

if [[ "$DISCO" == *nvme* || "$DISCO" == *mmcblk* ]]; then
  EFI="${DISCO}p1"; ROOT="${DISCO}p2"
else
  EFI="${DISCO}1";  ROOT="${DISCO}2"
fi

mkfs.fat -F32 -n KODISH_EFI "$EFI"
mkfs.ext4 -F -L kodish_root "$ROOT"

mount "$ROOT" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI" /mnt/boot/efi

# Cache do pacman do live vai para o DISCO (não consome RAM)
mkdir -p /mnt/var/cache/pacman/pkg
mount --bind /mnt/var/cache/pacman/pkg /var/cache/pacman/pkg
pacman -S --noconfirm --needed archlinux-keyring

# --- Instalação base ----------------------------------------------------------
pacstrap -K /mnt "${PACOTES[@]}"
genfstab -U /mnt >> /mnt/etc/fstab

# --- Script de configuração dentro do chroot ----------------------------------
cat > /mnt/root/chroot-setup.sh <<'CHROOT'
#!/bin/bash
set -Eeuo pipefail
trap 'echo "[ERRO no chroot] linha $LINENO" >&2' ERR

REPO_REF="${REPO_REF:-main}"
NVIDIA="${NVIDIA:-0}"
USUARIO="${USUARIO:-kodish}"
HOSTNAME_NOVO="${HOSTNAME_NOVO:-kodish}"
REPO_RAW="https://raw.githubusercontent.com/kodishmediacenter/Kodish-OS-10/${REPO_REF}"

dl() { curl -fsSL --retry 3 "$1" -o "$2" || echo "[AVISO] falha ao baixar $1" >&2; }

# --- Localização ---
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
hwclock --systohc
sed -i 's/^#\(pt_BR.UTF-8 UTF-8\)/\1/; s/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=pt_BR.UTF-8" > /etc/locale.conf
echo "KEYMAP=br-abnt2" > /etc/vconsole.conf

# --- Hostname ---
echo "$HOSTNAME_NOVO" > /etc/hostname
cat > /etc/hosts <<'HOSTS'
127.0.0.1   localhost
::1         localhost
HOSTS
echo "127.0.1.1   ${HOSTNAME_NOVO}.localdomain ${HOSTNAME_NOVO}" >> /etc/hosts

# --- zram (no lugar de partição swap) ---
cat > /etc/systemd/zram-generator.conf <<'ZRAM'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM

# --- Teclado no X (ABNT2) ---
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<'XKB'
Section "InputClass"
    Identifier "keyboard-br"
    MatchIsKeyboard "on"
    Option "XkbLayout" "br"
    Option "XkbModel" "abnt2"
EndSection
XKB

# --- mpv com aceleração por hardware ---
mkdir -p /etc/mpv
cat > /etc/mpv/mpv.conf <<'MPV'
hwdec=auto-safe
vo=gpu-next
gpu-context=auto
MPV

# --- Descoberta de rede (.local) ---
sed -i '/^hosts:/ s/resolve/mdns_minimal [NOTFOUND=return] resolve/' /etc/nsswitch.conf

# --- Aliases para novos usuários (antes do useradd, via /etc/skel) ---
cat >> /etc/skel/.bashrc <<'ALIASES'

# Kodish OS
alias update='sudo pacman -Syu && flatpak update -y'
alias fupdate='flatpak update -y'
alias ftk='sudo pacman -S'
alias stremio='flatpak run com.stremio.Stremio'
alias wallpaper='pcmanfm --desktop-pref'
alias pos='sudo /kodish/scripts/flatpaks.sh'
alias inyaa='sudo /kodish/scripts/instalar_nyaa.sh'
alias info='/kodish/scripts/hw.sh'
alias videoinfo='vainfo'
iftk() { flatpak install -y "${1##*/}"; }
ALIASES

# --- Usuário (senha é definida fora do chroot; root fica bloqueado) ---
getent group autologin >/dev/null || groupadd -r autologin
useradd -m -G wheel,audio,video,input,storage,autologin -s /bin/bash "$USUARIO"
passwd -l root
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# --- Estrutura /kodish (root:root 755; só o log é gravável pelo grupo) ---
install -d -m 755 /kodish /kodish/scripts /kodish/icon /kodish/config
install -d -m 775 -o root -g "$USUARIO" /kodish/log
echo "Kodish OS 11.0" > /kodish/version

cat > /kodish/config/flatpaks.list <<'FPK'
# Um ID do Flathub por linha (instalados no primeiro boot)
com.stremio.Stremio
FPK

for s in flatpaks.sh instalar_nyaa.sh hw.sh instalar-kodix.sh; do
  dl "${REPO_RAW}/scripts-kodish-gamer/${s}" "/kodish/scripts/${s}"
done

# --- Serviço de primeiro boot ---
cat > /kodish/scripts/firstboot.sh <<'FIRSTBOOT'
#!/bin/bash
set -Eeuo pipefail
exec >>/kodish/log/firstboot.log 2>&1
echo "== $(date) =="
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
if [[ -f /kodish/config/flatpaks.list ]]; then
  while read -r app; do
    [[ -z "$app" || "$app" == \#* ]] && continue
    flatpak install -y --noninteractive flathub "$app" || echo "falhou: $app"
  done < /kodish/config/flatpaks.list
fi
touch /kodish/.firstboot-done
echo "firstboot concluído"
FIRSTBOOT

cat > /etc/systemd/system/kodish-firstboot.service <<'UNIT'
[Unit]
Description=Kodish OS - configuração do primeiro boot
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/kodish/.firstboot-done

[Service]
Type=oneshot
ExecStart=/kodish/scripts/firstboot.sh

[Install]
WantedBy=multi-user.target
UNIT

chown -R root:root /kodish/scripts /kodish/icon /kodish/config
chmod 755 /kodish/scripts/* || true

# --- LightDM: autologin no Kodi; LXDE disponível no greeter ---
cat > /usr/share/xsessions/kodish-tv.desktop <<'SESSION'
[Desktop Entry]
Name=Kodish TV
Comment=Kodi Media Center
Exec=/usr/bin/kodi-standalone
Type=Application
SESSION

cat > /etc/lightdm/lightdm.conf <<LDM
[LightDM]
run-directory=/run/lightdm

[Seat:*]
greeter-session=lightdm-gtk-greeter
autologin-user=${USUARIO}
autologin-user-timeout=0
autologin-session=kodish-tv
LDM

# --- Plymouth (hook + splash) ---
sed -i '/^HOOKS=/ s/\budev\b/udev plymouth/' /etc/mkinitcpio.conf
THEME="spinner"
mkdir -p /tmp/kodish-theme
if curl -fsSL --retry 3 "${REPO_RAW}/Kodish%20OS/logo-slider.zip" -o /tmp/kodish-theme/logo-slider.zip; then
  if unzip -oq /tmp/kodish-theme/logo-slider.zip -d /tmp/kodish-theme && [[ -d /tmp/kodish-theme/logo-slider ]]; then
    cp -r /tmp/kodish-theme/logo-slider /usr/share/plymouth/themes/
    THEME="logo-slider"
  fi
fi
rm -rf /tmp/kodish-theme
plymouth-set-default-theme -R "$THEME"

# --- GRUB (UEFI, removível) ---
CMDLINE="quiet splash"
[[ "$NVIDIA" == "1" ]] && CMDLINE="$CMDLINE nvidia_drm.modeset=1"
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${CMDLINE}\"|" /etc/default/grub
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
             --bootloader-id=Kodish --removable --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# --- Serviços (somente "enable"; o chroot não roda o systemd) ---
systemctl enable NetworkManager NetworkManager-wait-online bluetooth \
                 avahi-daemon cronie systemd-timesyncd lightdm \
                 kodish-firstboot.service
systemctl set-default graphical.target
# SSH fica DESLIGADO por padrão. Para ativar: sudo systemctl enable --now sshd

echo "Configuração do chroot concluída."
CHROOT

chmod 700 /mnt/root/chroot-setup.sh
arch-chroot /mnt env REPO_REF="$REPO_REF" NVIDIA="$HAS_NVIDIA" \
    USUARIO="$USUARIO" HOSTNAME_NOVO="$HOSTNAME_NOVO" \
    /bin/bash /root/chroot-setup.sh
rm -f /mnt/root/chroot-setup.sh

# --- Senha do usuário (fora do chroot para não ficar em arquivo) ---------------
echo "${USUARIO}:${SENHA}" | arch-chroot /mnt chpasswd
unset SENHA SENHA2

# --- Finalização --------------------------------------------------------------
umount /var/cache/pacman/pkg 2>/dev/null || true
umount -R /mnt

clear
verde "[===============================================================]"
echo  "  Kodish OS 11 instalado com sucesso!"
echo  "  Usuário: ${USUARIO}  |  root: bloqueado (use sudo)"
echo  "  Remova o pendrive e reinicie: reboot"
verde "[===============================================================]"
