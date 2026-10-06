#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
extractor="$package_dir/qcom-firmware-extract"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# macOS' install(1) gives -D a different meaning. Prefer GNU coreutils when
# this focused test runs on a contributor's Mac; Arch uses GNU install already.
test_bin="$scratch/bin"
mkdir -p "$test_bin"
if command -v ginstall >/dev/null 2>&1; then
  ln -s "$(command -v ginstall)" "$test_bin/install"
fi

dt_root="$scratch/device-tree"
firmware_root="$scratch/firmware"
driver_store="$scratch/DriverStore"
stage="$scratch/stage"
node="$dt_root/remoteproc@0"
firmware_path="qcom/x1e80100/LENOVO/83ED"

# Pin the kernel's firmware decompressors instead of reading /proc/config.gz.
export QCOM_FW_KERNEL_CONFIG="$scratch/config.gz"
set_kernel_config() { printf '%s\n' "$@" | gzip >"$QCOM_FW_KERNEL_CONFIG"; }
set_kernel_config CONFIG_FW_LOADER_COMPRESS_ZSTD=y CONFIG_FW_LOADER_COMPRESS_XZ=y

mkdir -p "$node" "$firmware_root/$firmware_path" \
  "$driver_store/wrong" "$driver_store/matching"
printf '%s\0%s\0' \
  "$firmware_path/qccdsp8380.mbn" \
  "$firmware_path/cdsp_dtbs.elf" >"$node/firmware-name"

# Make the incompatible Windows firmware newer than the matching variant.
printf 'installed-cdsp' >"$firmware_root/$firmware_path/qccdsp8380.mbn"
printf 'other-cdsp' >"$driver_store/wrong/qccdsp8380.mbn"
printf 'wrong-dtb' >"$driver_store/wrong/cdsp_dtbs.elf"
printf 'installed-cdsp' >"$driver_store/matching/qccdsp8380.mbn"
printf 'matching-dtb' >"$driver_store/matching/cdsp_dtbs.elf"
touch -t 203001010000 "$driver_store/wrong/cdsp_dtbs.elf"
touch -t 202001010000 "$driver_store/matching/cdsp_dtbs.elf"

QCOM_FW_DT_ROOT="$dt_root" \
  QCOM_FW_FIRMWARE_ROOT="$firmware_root" \
  PATH="$test_bin:$PATH" \
  bash "$extractor" --stage "$stage" -d "$driver_store"

[[ $(<"$stage/$firmware_path/cdsp_dtbs.elf") == matching-dtb ]] || {
  echo "not ok - extractor did not select the DTB matching the installed DSP image" >&2
  exit 1
}

echo "ok - extractor selects an ambiguous DTB by its companion firmware hash"

# Runs under a test root prefix, as if root.
run_extractor() {
  QCOM_FW_DT_ROOT="$dt_root" \
    QCOM_FW_FIRMWARE_ROOT="$firmware_root" \
    QCOM_FW_ROOT="$scratch/root" \
    QCOM_FW_TEST_EUID=0 \
    PATH="$test_bin:$PATH" \
    bash "$extractor" "$@"
}

# A different remote processor must not supply the matching companion.
mkdir -p "$dt_root/remoteproc@1" "$driver_store/unrelated"
printf '%s\0' "$firmware_path/qcadsp8380.mbn" >"$dt_root/remoteproc@1/firmware-name"
printf 'installed-adsp' >"$firmware_root/$firmware_path/qcadsp8380.mbn"
printf 'installed-adsp' >"$driver_store/unrelated/qcadsp8380.mbn"
printf 'unrelated-dtb' >"$driver_store/unrelated/cdsp_dtbs.elf"
printf 'missing-cdsp' >"$firmware_root/$firmware_path/qccdsp8380.mbn"
run_extractor --stage "$scratch/unmatched" -d "$driver_store"
[[ ! -e $scratch/unmatched/$firmware_path/cdsp_dtbs.elf ]]
echo "ok - companion matching stays within the exact device-tree node"

# Firmware not found in Windows must not stop other files from being staged.
printf '%s\0%s\0%s\0' "$firmware_path/not-in-windows.mbn" \
  "$firmware_path/cdsp_dtbs.elf" "$firmware_path/qccdsp8380.mbn" >"$node/firmware-name"
printf 'installed-cdsp' >"$firmware_root/$firmware_path/qccdsp8380.mbn"
run_extractor --stage "$scratch/partial" -d "$driver_store"
[[ $(<"$scratch/partial/$firmware_path/cdsp_dtbs.elf") == matching-dtb ]]
run_extractor --install --no-rebuild --stage-dir "$scratch/partial"
[[ $(<"$firmware_root/updates/$firmware_path/cdsp_dtbs.elf") == matching-dtb ]]
echo "ok - missing firmware does not abort staging or installation"

# Windows names the Surface Pro 11's DSP device-tree images *_dtbs.elf.
surface_path="qcom/x1e80100/microsoft/Denali"
mkdir -p "$driver_store/surfacepro_ext_adsp8380"
printf '%s\0' "$surface_path/adsp_dtb.mbn" >"$node/firmware-name"
printf 'surface-adsp-dtb' >"$driver_store/surfacepro_ext_adsp8380/adsp_dtbs.elf"
run_extractor --stage "$scratch/windows-name" -d "$driver_store"
[[ $(<"$scratch/windows-name/$surface_path/adsp_dtb.mbn") == surface-adsp-dtb ]] || {
  echo "not ok - extractor did not find a DSP device-tree image under its Windows name" >&2
  exit 1
}
run_extractor --install --no-rebuild --stage-dir "$scratch/windows-name"
[[ $(<"$firmware_root/updates/$surface_path/adsp_dtb.mbn") == surface-adsp-dtb ]]
rm "$firmware_root/updates/$surface_path/adsp_dtb.mbn"
printf 'exact-name' >"$driver_store/surfacepro_ext_adsp8380/adsp_dtb.mbn"
run_extractor --stage "$scratch/exact-name" -d "$driver_store"
[[ $(<"$scratch/exact-name/$surface_path/adsp_dtb.mbn") == exact-name ]]
rm "$driver_store/surfacepro_ext_adsp8380/adsp_dtb.mbn"
echo "ok - DSP device-tree images are found under their Windows names, exact names first"

# With no companion, only byte-identical duplicates are safe to select.
printf '%s\0' "$firmware_path/duplicate.mbn" >"$node/firmware-name"
printf 'one' >"$driver_store/wrong/duplicate.mbn"
printf 'two' >"$driver_store/matching/duplicate.mbn"
run_extractor --stage "$scratch/ambiguous" -d "$driver_store"
[[ ! -e $scratch/ambiguous/$firmware_path/duplicate.mbn ]]
printf 'one' >"$driver_store/matching/duplicate.mbn"
run_extractor --stage "$scratch/identical" -d "$driver_store"
[[ $(<"$scratch/identical/$firmware_path/duplicate.mbn") == one ]]
echo "ok - differing variants require a unique match"

# A name that matches another as a regular expression keeps its manifest line.
printf 'first' >"$driver_store/matching/dotXmbn"
printf 'second' >"$driver_store/matching/dot.mbn"
printf '%s\0' "$firmware_path/dotXmbn" >"$node/firmware-name"
run_extractor --install --no-rebuild -d "$driver_store"
printf '%s\0' "$firmware_path/dot.mbn" >"$node/firmware-name"
run_extractor --install --no-rebuild -d "$driver_store"
[[ $(grep -c /dot "$scratch/root/var/lib/omarchy/qcom-firmware/manifest") == 2 ]]
echo "ok - manifest updates match firmware names exactly"

# A packaged zap shader still needs an initramfs entry when nothing is missing.
printf '%s\0' "$firmware_path/qccdsp8380.mbn" >"$node/firmware-name"
mkdir -p "$dt_root/gpu@0/zap-shader"
printf '%s\0' "$firmware_path/qcdxkmsuc8380.mbn" >"$dt_root/gpu@0/zap-shader/firmware-name"
zap="$firmware_path/qcdxkmsuc8380.mbn"
config="$scratch/root/etc/mkinitcpio.conf.d/qcom-firmware.conf"
for compression in zstd xz; do
  if [[ $compression == zstd ]]; then suffix=zst; else suffix=xz; fi
  printf 'zap' | "$compression" -c >"$firmware_root/$zap.$suffix"
  run_extractor --install --no-rebuild -d "$driver_store"
  [[ -z $(run_extractor --list-missing) ]]
  grep -Fq "$zap.$suffix" "$config"
  rm "$firmware_root/$zap.$suffix"
done
echo "ok - zstd and xz firmware are loadable and included in the initramfs"

# Arch Linux ARM's kernel loads xz firmware but not zstd.
set_kernel_config CONFIG_FW_LOADER_COMPRESS_XZ=y
printf 'zap' | zstd -c >"$firmware_root/$zap.zst"
[[ $(run_extractor --list-missing) == "$zap" ]]
rm "$firmware_root/$zap.zst"
set_kernel_config CONFIG_FW_LOADER_COMPRESS_ZSTD=y CONFIG_FW_LOADER_COMPRESS_XZ=y
echo "ok - zstd firmware counts as missing when the kernel cannot load it"

printf 'zap' | gzip >"$firmware_root/$zap.gz"
[[ $(run_extractor --list-missing) == "$zap" ]]
run_extractor --install --no-rebuild -d "$driver_store"
[[ ! -e $config ]]
printf 'zap' >"$driver_store/matching/qcdxkmsuc8380.mbn"
run_extractor --install --no-rebuild -d "$driver_store"
cmp "$driver_store/matching/qcdxkmsuc8380.mbn" "$firmware_root/updates/$zap"
grep -Fq "updates/$zap" "$config"
echo "ok - gzip does not hide missing firmware or prevent extraction"

# Compressed updates must not take precedence over a plain packaged file.
mv "$firmware_root/updates/$zap" "$firmware_root/$zap"
printf 'update' | zstd -c >"$firmware_root/updates/$zap.zst"
run_extractor --install --no-rebuild -d "$driver_store"
grep -Fq "$firmware_root/$zap" "$config"
if grep -Fq "updates/$zap" "$config"; then
  echo "not ok - firmware selection differs from the kernel search order" >&2
  exit 1
fi
printf 'update' >"$firmware_root/updates/$zap"
run_extractor --install --no-rebuild -d "$driver_store"
grep -Fq "updates/$zap" "$config"
echo "ok - plain firmware is preferred before compressed directory overrides"

limine-update() { printf 'rebuild\n' >>"$QCOM_FW_ROOT/rebuilds"; }
export -f limine-update
run_extractor --install -d "$driver_store"
[[ ! -e $scratch/root/rebuilds ]]
rm "$scratch/root/etc/mkinitcpio.conf.d/qcom-firmware.conf"
run_extractor --install -d "$driver_store"
[[ $(<"$scratch/root/rebuilds") == rebuild ]]
echo "ok - configuration-only changes rebuild the initramfs once"

# Reruns: an earlier stage, even an empty one, must not hide a later source.
rerun="$scratch/rerun"
rerun_dt="$rerun/device-tree"
adsp="qcom/glymur/vendor/board/qcadsp.mbn"
dtb="qcom/glymur/vendor/board/adsp_dtbs.elf"
windows_store="$rerun/windows/nvme0n1p3/Windows/System32/DriverStore/FileRepository/adsp.inf_1"
mkdir -p "$rerun_dt/remoteproc@0" "$rerun/root/run" "$rerun/empty-store" \
  "$rerun/store" "$rerun/adsp-only-store" "$windows_store"
printf '%s\0%s\0' "$adsp" "$dtb" >"$rerun_dt/remoteproc@0/firmware-name"
printf 'store-adsp' >"$rerun/store/qcadsp.mbn"
printf 'store-dtb' >"$rerun/store/adsp_dtbs.elf"
printf 'first-adsp' >"$rerun/adsp-only-store/qcadsp.mbn"
printf 'windows-adsp' >"$windows_store/qcadsp.mbn"
printf 'windows-dtb' >"$windows_store/adsp_dtbs.elf"

# shellcheck disable=SC2329 # The stubs are exported to the extractor.
(
  # One internal NTFS partition holding the fake Windows tree.
  lsblk() { printf 'lsblk\n' >>"$TEST_SCAN_LOG"; printf '/dev/nvme0n1p3 ntfs nvme\n'; }
  mount() { local device=${*: -2:1} mount_point=${*: -1}; cp -R "$TEST_WINDOWS/${device##*/}/." "$mount_point/"; }
  umount() { find "$1" -mindepth 1 -delete; }
  export -f lsblk mount umount
  export TEST_WINDOWS="$rerun/windows" TEST_SCAN_LOG="$rerun/scan.log"

  run_rerun() {
    QCOM_FW_DT_ROOT="$rerun_dt" \
      QCOM_FW_FIRMWARE_ROOT="$rerun/firmware" \
      QCOM_FW_ROOT="$rerun/root" \
      QCOM_FW_TEST_EUID=${QCOM_FW_TEST_EUID-0} \
      PATH="$test_bin:$PATH" \
      bash "$extractor" "$@"
  }
  reset_installed() { rm -rf "$rerun/firmware" "$rerun/root/var" "$TEST_SCAN_LOG"; mkdir -p "$rerun/firmware"; }
  installed() { cat "$rerun/firmware/updates/$1"; }

  stage="$rerun/stage"
  run_rerun --stage "$stage" -d "$rerun/empty-store"
  [[ -f $stage/manifest && ! -s $stage/manifest ]]
  run_rerun --stage "$stage" -d "$rerun/store"
  [[ $(<"$stage/$adsp") == store-adsp && $(<"$stage/$dtb") == store-dtb ]]
  [[ $(grep -c . "$stage/manifest") == 2 ]]
  output=$(run_rerun --stage "$stage")
  [[ $output == *"already staged"* ]]
  [[ ! -e $TEST_SCAN_LOG ]]
  echo "ok - a stage rerun adds files an earlier, empty stage lacked"

  partial="$rerun/partial-stage"
  run_rerun --stage "$partial" -d "$rerun/adsp-only-store"
  run_rerun --stage "$partial" -d "$rerun/store"
  [[ $(<"$partial/$adsp") == first-adsp && $(<"$partial/$dtb") == store-dtb ]]
  [[ $(grep -c "^$adsp " "$partial/manifest") == 1 && $(grep -c . "$partial/manifest") == 2 ]]
  echo "ok - a stage rerun keeps staged files and their manifest lines"

  # Only the test switch stands in for root, not the test path prefix.
  rm -f "$TEST_SCAN_LOG"
  if output=$(QCOM_FW_TEST_EUID=1000 run_rerun --stage "$rerun/user-stage" 2>&1); then
    echo "not ok - a first stage without root read the partitions" >&2
    exit 1
  fi
  [[ $output == *"must run as root to read the Windows partitions"* && ! -e $TEST_SCAN_LOG ]]
  if QCOM_FW_TEST_EUID=1000 run_rerun --install --no-rebuild -d "$rerun/store" >/dev/null 2>&1; then
    echo "not ok - an install without root went ahead" >&2
    exit 1
  fi
  echo "ok - reading the partitions and installing need root"

  # A rerun without root cannot read Windows, so it keeps the stage it has.
  user_partial="$rerun/user-partial"
  run_rerun --stage "$user_partial" -d "$rerun/adsp-only-store"
  output=$(QCOM_FW_TEST_EUID=1000 run_rerun --stage "$user_partial")
  [[ $output == *"already staged in $user_partial; run as root"* && ! -e $TEST_SCAN_LOG ]]
  [[ $(grep -c . "$user_partial/manifest") == 1 ]]
  echo "ok - a stage rerun without root keeps a partial stage and succeeds"

  # Neither a stage rerun nor an install reads or rewrites the stage manifest
  # once per firmware name. External commands naming it are counted; reads
  # with bash builtins are not.
  probe="$rerun/probe-stage"
  run_rerun --stage "$probe" -d "$rerun/adsp-only-store"
  (
    # shellcheck disable=SC2329 # The wrappers are exported to the extractor.
    manifest_access() {
      local tool=$1 arg
      shift
      for arg; do
        if [[ $arg == "$probe/manifest"* ]]; then
          printf '%s\n' "$tool" >>"$rerun/manifest.log"
          break
        fi
      done
      command "$tool" "$@"
    }
    awk() { manifest_access awk "$@"; }
    cat() { manifest_access cat "$@"; }
    cp() { manifest_access cp "$@"; }
    grep() { manifest_access grep "$@"; }
    mv() { manifest_access mv "$@"; }
    sed() { manifest_access sed "$@"; }
    export -f manifest_access awk cat cp grep mv sed
    export probe rerun

    run_rerun --stage "$probe" -d "$rerun/store"
    [[ $(<"$probe/$dtb") == store-dtb && $(command grep -c . "$rerun/manifest.log") -le 1 ]]
    rm "$rerun/manifest.log"
    reset_installed
    run_rerun --install --no-rebuild --stage-dir "$probe"
    [[ $(installed "$adsp") == first-adsp && $(installed "$dtb") == store-dtb ]]
    [[ ! -e $rerun/manifest.log || $(command grep -c . "$rerun/manifest.log") -le 1 ]]
  )
  echo "ok - no per-name stage manifest scans or rewrites"

  mkdir -p "$rerun/empty-stage"
  : >"$rerun/empty-stage/manifest"
  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$rerun/empty-stage"
  [[ $(installed "$adsp") == windows-adsp && $(installed "$dtb") == windows-dtb ]]
  echo "ok - an empty stage does not hide the Windows partition"

  dtb_stage="$rerun/dtb-stage"
  mkdir -p "$dtb_stage/${dtb%/*}"
  printf 'staged-dtb' >"$dtb_stage/$dtb"
  printf '%s %s %s\n' "$dtb" 0 test >"$dtb_stage/manifest"
  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$dtb_stage"
  [[ $(installed "$dtb") == staged-dtb && $(installed "$adsp") == windows-adsp ]]
  echo "ok - Windows supplies what a partial stage lacks, and the stage comes first"

  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$stage"
  [[ $(installed "$adsp") == store-adsp && $(installed "$dtb") == store-dtb ]]
  [[ ! -e $TEST_SCAN_LOG ]]
  echo "ok - a complete stage is used without mounting Windows"

  printf 'unlisted' >"$dtb_stage/$adsp"
  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$dtb_stage"
  [[ $(installed "$adsp") == windows-adsp ]]
  echo "ok - only files recorded in the stage manifest count as staged"

  # A manifest line whose file is gone does not count as staged either.
  rm "$dtb_stage/$dtb"
  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$dtb_stage"
  [[ $(installed "$dtb") == windows-dtb ]]
  printf 'staged-dtb' >"$dtb_stage/$dtb"
  echo "ok - a manifest line without its file does not count as staged"

  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$stage" -d "$rerun/adsp-only-store"
  [[ $(installed "$adsp") == first-adsp && ! -e $rerun/firmware/updates/$dtb ]]
  [[ ! -e $TEST_SCAN_LOG ]]
  echo "ok - -d replaces the stage and the Windows partitions"
)
