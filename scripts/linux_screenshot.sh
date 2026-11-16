#!/usr/bin/env bash
# Capture a Linux niri guest's accelerated output as a host-side binary PPM.
# QMP screendump only supports CPU surfaces, not GL texture/dmabuf scanouts.
set -euo pipefail
: "${GUIX_DIR:?set GUIX_DIR}"
: "${GUIX_SSH_PORT:?set GUIX_SSH_PORT}"
: "${SSH_KEY_DIR:?set SSH_KEY_DIR}"
: "${SSH_HOST:=127.0.0.1}"
output="${1:-$GUIX_DIR/screen.ppm}"
case "$output" in
    /*) ;;
    *) output="$PWD/$output" ;;
esac
[[ -d "$(dirname "$output")" ]] || {
    echo "linux_screenshot: output directory does not exist" >&2
    exit 1
}
guest_png=/home/peon/hurdkit-screen.png
guest_script="$GUIX_DIR/screenshot-guest.sh"
cat > "$guest_script" <<'GUEST'
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-1
NIRI_SOCKET=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s \
    -name "niri.${WAYLAND_DISPLAY}.*.sock" -print -quit)
export NIRI_SOCKET
: "${NIRI_SOCKET:?no niri IPC socket found}"
rm -f /home/peon/hurdkit-screen.png
niri msg action screenshot-screen --path /home/peon/hurdkit-screen.png
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s /home/peon/hurdkit-screen.png ]] && exit 0
    sleep 1
done
echo 'niri did not write the screenshot' >&2
exit 1
GUEST
ssh_args=(
    -o IdentitiesOnly=yes -o IdentityAgent=none
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes
)
ssh -i "$SSH_KEY_DIR/peon_ed25519" "${ssh_args[@]}" \
    -p "$GUIX_SSH_PORT" "peon@$SSH_HOST" bash -s < "$guest_script"
rm -f "$output"
scp -q -i "$SSH_KEY_DIR/peon_ed25519" "${ssh_args[@]}" \
    -P "$GUIX_SSH_PORT" "peon@$SSH_HOST:$guest_png" "$GUIX_DIR/screen.png"
magick "$GUIX_DIR/screen.png" -alpha off "$output"
printf '%s\n' "$output"
