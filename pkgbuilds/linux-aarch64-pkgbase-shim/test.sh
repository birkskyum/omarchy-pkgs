#!/bin/bash
set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export OMARCHY_KERNEL_SHIM_ROOT=$scratch
export SHIM_NATIVE=0 SHIM_KERNEL_PRESENT=1

pacman() {
  if [[ $1 == -Qlq ]]; then
    printf '/usr/lib/initcpio/install/test\n'
    return 0
  fi
  case $2 in
    /boot/Image | /usr/lib/modules/test)
      ((SHIM_KERNEL_PRESENT)) || return 1
      printf 'linux-aarch64\n'
      ;;
    /usr/lib/modules/test/pkgbase | /usr/lib/modules/test/vmlinuz)
      ((SHIM_NATIVE)) || return 1
      printf 'linux-aarch64\n'
      ;;
    *) return 1 ;;
  esac
}
export -f pacman

modules=$scratch/usr/lib/modules/test
mkdir -p "$modules" "$scratch/boot" "$scratch/etc/pacman.d/hooks" \
  "$scratch/usr/share/libalpm/scripts"
printf 'first-kernel' >"$scratch/boot/Image"
cat >"$scratch/usr/share/libalpm/scripts/limine-mkinitcpio-install" <<'SCRIPT'
#!/bin/bash
cat >>"$OMARCHY_KERNEL_SHIM_ROOT/rebuilds"
SCRIPT
chmod +x "$scratch/usr/share/libalpm/scripts/limine-mkinitcpio-install"

run_shim() {
  printf '%s\n' "$1" | bash "$package_dir/linux-aarch64-pkgbase-shim"
}

run_shim usr/lib/modules/test/
[[ $(<"$modules/pkgbase") == linux-aarch64 ]]
cmp "$scratch/boot/Image" "$modules/vmlinuz"
[[ $(stat -c %a "$modules/vmlinuz") == $(stat -c %a "$scratch/boot/Image") ]]
[[ ! -e $scratch/rebuilds ]]
echo 'ok - kernel installation supplies metadata before the normal rebuild hook'

printf 'replacement-kernel' >"$scratch/boot/Image"
run_shim usr/lib/modules/test/
cmp "$scratch/boot/Image" "$modules/vmlinuz"
echo 'ok - reinstalling the same kernel version refreshes its image'

printf 'shim-upgrade' >"$scratch/boot/Image"
run_shim linux-aarch64-pkgbase-shim
[[ $(<"$scratch/rebuilds") == rebuild ]]
run_shim linux-aarch64-pkgbase-shim
[[ $(wc -l <"$scratch/rebuilds") == 1 ]]
echo 'ok - unchanged images do not trigger redundant rebuilds'

ln -s /dev/null "$scratch/etc/pacman.d/hooks/90-mkinitcpio-install.hook"
printf 'deferred-kernel' >"$scratch/boot/Image"
run_shim linux-aarch64-pkgbase-shim
cmp "$scratch/boot/Image" "$modules/vmlinuz"
[[ $(wc -l <"$scratch/rebuilds") == 1 ]]
echo 'ok - the installer can defer boot-image regeneration'

SHIM_NATIVE=1
printf 'package-owned' >"$modules/vmlinuz"
run_shim usr/lib/modules/test/
[[ $(<"$modules/vmlinuz") == package-owned ]]
echo 'ok - native package-owned kernel files are preserved'

SHIM_NATIVE=0
SHIM_KERNEL_PRESENT=0
run_shim usr/lib/modules/test/
[[ ! -d $modules ]]
echo 'ok - kernel removal cleans up leftover shim metadata'
