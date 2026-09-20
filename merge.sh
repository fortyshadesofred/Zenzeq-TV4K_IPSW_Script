#!/usr/bin/env bash
# merge.sh - Reconciles and merges Zenzeq-TV4K_IPSW_Script and verygenericname-TV4K_IPSW_Script
#
# Usage:
#   ./merge.sh [--dry-run] [--apply] [--target <zenzeq|upstream|both>] [--output-dir <path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

ZENZEQ_DIR="${ZENZEQ_DIR:-$PARENT_DIR/Zenzeq-TV4K_IPSW_Script}"
UPSTREAM_DIR="${UPSTREAM_DIR:-$PARENT_DIR/verygenericname-TV4K_IPSW_Script}"

DRY_RUN=0
APPLY=0
TARGET="both"
OUTPUT_DIR=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --dry-run             Preview actions without modifying any files (default)
  --apply               Execute the merge and update repository files
  --target <choice>     Target repository to update: 'zenzeq', 'upstream', or 'both' (default: both)
  --output-dir <dir>    Write merged files to a custom destination directory
  --zenzeq-dir <dir>    Path to Zenzeq repo (default: $ZENZEQ_DIR)
  --upstream-dir <dir>  Path to verygenericname repo (default: $UPSTREAM_DIR)
  -h, --help            Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            APPLY=0
            shift
            ;;
        --apply)
            APPLY=1
            DRY_RUN=0
            shift
            ;;
        --target)
            TARGET="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --zenzeq-dir)
            ZENZEQ_DIR="$2"
            shift 2
            ;;
        --upstream-dir)
            UPSTREAM_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

if [ "$APPLY" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    DRY_RUN=1
fi

echo "========================================================"
echo " TV4K_IPSW_Script Merge & Reconciliation Utility"
echo "========================================================"
echo "Zenzeq Repo:   $ZENZEQ_DIR"
echo "Upstream Repo: $UPSTREAM_DIR"
echo "Target:        $TARGET"
echo "Mode:          $([ "$APPLY" -eq 1 ] && echo "APPLY (modifying files)" || echo "DRY-RUN (preview only)")"
echo "========================================================"

# Validate directories
if [ ! -d "$ZENZEQ_DIR" ]; then
    echo "Error: Zenzeq directory not found at $ZENZEQ_DIR" >&2
    exit 1
fi

if [ ! -d "$UPSTREAM_DIR" ]; then
    echo "Error: Upstream directory not found at $UPSTREAM_DIR" >&2
    exit 1
fi

# Generate the merged makeipsw.sh content into a temporary file
TMP_MERGED="$(mktemp -t merged_makeipsw.XXXXXX.sh)"
trap 'rm -f "$TMP_MERGED"' EXIT

cat << 'MERGED_EOF' > "$TMP_MERGED"
#!/usr/bin/env bash
# This is a script to make an IPSW for the Apple TV 4K (AppleTV6,2).
# Reconciled and merged from verygenericname (upstream) & Zenzeq fork.

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./makeipsw.sh <path_or_url_to_ota> <path_or_url_to_tv4_ipsw>"
    exit 1
fi

set -e

progress() {
    local current=$1
    local total=$2

    local percent=$((100 * current / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))

    printf "\r["

    for ((i=0; i<filled; i++)); do
        printf "#"
    done

    for ((i=0; i<empty; i++)); do
        printf "-"
    done

    printf "] %3d%%" "$percent"
}

mkdir -p ipsws
sudo rm -rf work | true
sudo rm -f /tmp/BI0.plist | true
VOLUME_NAME=TV_RESTORE_OTA

# Handle remote OTA URL vs local file
ota_source="$1"
if [ ! -e "$1" ]; then
    rm -rf downloads | true
    mkdir -p downloads
    echo "Downloading OTA update..."
    cd downloads
    wget "$1"
    cd ..
    ota_source=$(ls downloads/* | head -n 1)
fi

# Check for incompatible tvOS 13.4.8 (safely after download or local resolution)
if [ -f "$ota_source" ]; then
    sum=$(shasum -a 256 "$ota_source" | cut -d' ' -f1)
    if [ "$sum" = "8725797b4ddfd93fc67023c93c1d9277f128e9731a9ac18618b9b2e812c027c1" ]; then
        echo "13.4.8 detected. The script is incompatible for this version. Please use firmwares between tvOS 14 - 17.6.1."
        exit 1
    fi
fi

# create work dir
mkdir -p work/ota work/ipsw

cd work/ota
echo "Unzipping OTA..."
if [ ! -e "$1" ]; then
    unzip ../../downloads/* | while IFS= read -r line; do
        case "$line" in
            *inflating:*|*extracting:*)
                printf "\rCurrently: %s\033[K" "${line#*: }"
                ;;
        esac
    done
    echo
else
    unzip "$1" | while IFS= read -r line; do
        case "$line" in
            *inflating:*|*extracting:*)
                printf "\rCurrently: %s\033[K" "${line#*: }"
                ;;
        esac
    done
    echo
fi

# Extract version early to configure tools and patch guards
ipsw_buildnumber=$(plutil -extract "ProductBuildVersion" raw -expect string -o - AssetData/boot/BuildManifest.plist)
ipsw_version=$(plutil -extract "ProductVersion" raw -expect string -o - AssetData/boot/BuildManifest.plist)
major_version=$(echo "$ipsw_version" | grep -oE '^[0-9]+')

if [ "$major_version" -lt 14 ]; then
    EXTRACT_TOOL="$(cd ../../Darwin && pwd)/yaa"
else
    EXTRACT_TOOL=/usr/bin/aa
fi

mkdir -p AssetData/rootfs
cd AssetData/rootfs

echo "Extracting payloads..."
find ../payloadv2 -name 'payload.[0-9][0-9][0-9]' -print0 | while IFS= read -r -d '' payload; do
    printf "\rCurrently: %s\033[K" "$(basename "$payload")"
    sudo "$EXTRACT_TOOL" extract -i "$payload" | while IFS= read -r line; do
        printf "\rCurrently: %s\033[K" "$line"
    done
done

printf "\rCurrently: fixup.manifest\033[K"
sudo "$EXTRACT_TOOL" extract -i ../payloadv2/fixup.manifest 2>/dev/null | while IFS= read -r line; do
    printf "\rCurrently: %s\033[K" "$line"
done || true

printf "\rCurrently: data_payload\033[K"
sudo "$EXTRACT_TOOL" extract -i ../payloadv2/data_payload | while IFS= read -r line; do
    printf "\rCurrently: %s\033[K" "$line"
done
echo

sudo chown -R 0:0 ../payload/replace/*

echo "Copying replacement files... This may take a while, please wait."
src="../payload/replace"
total=$(find "$src" -type f | wc -l | tr -d ' ')
current=0

if [ "$total" -gt 0 ]; then
    progress 0 100
    find "$src" -mindepth 1 -print | while read -r item; do
        rel="${item#$src/}"
        dest="./$rel"

        if [ -d "$item" ]; then
            sudo mkdir -p "$dest"
        else
            sudo mkdir -p "$(dirname "$dest")"
            sudo cp -a "$item" "$dest"
            current=$((current + 1))
            percent=$((100 * current / total))
            progress "$percent" 100
        fi
    done
    echo
else
    sudo cp -a ../payload/replace/* . 2>/dev/null || true
fi

echo "Copy complete."

cd ..
echo "Building DMG... This may take a while."

total=4
current=0

progress "$current" "$total"
echo

cp ../../../template.dmg output.dmg

hdiutil resize -size 15000m output.dmg >/dev/null
sudo hdiutil attach output.dmg -owners on >/dev/null
sudo mount -urw /Volumes/Template >/dev/null

current=$((current + 1))
progress "$current" "$total"
printf "\rCurrently: Copying root filesystem...\n"
sudo rsync -a rootfs/ /Volumes/Template/

current=$((current + 1))
progress "$current" "$total"
printf "\rCurrently: Renaming volume...\n"
sudo diskutil rename /Volumes/Template "$VOLUME_NAME" 2>&1 | while IFS= read -r line; do
    printf "\033[1A\r%-80s\n\rCurrently: %s\033[K" "$(progress "$current" "$total")" "$line"
done

current=$((current + 1))
progress "$current" "$total"
printf "\rCurrently: Finalizing DMG...\n"

hdiutil detach "/Volumes/$VOLUME_NAME" -force 2>&1 | while IFS= read -r line; do
    printf "\033[1A\r%-80s\n\rCurrently: %s\033[K" "$(progress "$current" "$total")" "$line"
done

hdiutil resize -sectors min output.dmg 2>&1 | while IFS= read -r line; do
    printf "\033[1A\r%-80s\n\rCurrently: %s\033[K" "$(progress "$current" "$total")" "$line"
done

hdiutil convert -format ULFO -o converted.dmg output.dmg 2>&1 | while IFS= read -r line; do
    printf "\033[1A\r%-80s\n\rCurrently: %s\033[K" "$(progress "$current" "$total")" "$line"
done

rm output.dmg 2>&1 | while IFS= read -r line; do
    printf "\033[1A\r%-80s\n\rCurrently: %s\033[K" "$(progress "$current" "$total")" "$line"
done

current=$((current + 1))
progress "$current" "$total"
printf "\rCurrently: Scanning image...\n"

asr imagescan --source converted.dmg 2>&1 | while IFS= read -r line; do
    printf "\033[1A\r%-80s\n\rCurrently: %s\033[K" "$(progress "$current" "$total")" "$line"
done

echo
echo "DMG build complete."

cd ../..

cd ipsw

echo "Copying IPSW assets, please wait..."

total=3
current=0

progress "$current" "$total"

cp -r ../ota/AssetData/boot/Firmware .
current=$((current + 1))
progress "$current" "$total"

cp ../ota/AssetData/boot/kernelcache.release.* .
current=$((current + 1))
progress "$current" "$total"

cp ../ota/AssetData/boot/BuildManifest.plist .
current=$((current + 1))
progress "$current" "$total"

echo
echo "Copy complete."

chmod u+w BuildManifest.plist # seemingly only needed on 18, odd
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:0:Info:RestoreBehavior Erase" BuildManifest.plist
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:0:Info:Variant Customer Erase Install (IPSW)" BuildManifest.plist
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:0:Manifest:RestoreRamDisk:Info:Path arm64SURamDisk.dmg" BuildManifest.plist
rm $(plutil -extract "BuildIdentities".0."Manifest"."RestoreTrustCache"."Info"."Path" raw -expect string -o - BuildManifest.plist) 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:0:Manifest:RestoreTrustCache:Info:Path Firmware/arm64SURamDisk.dmg.trustcache" BuildManifest.plist

/usr/libexec/PlistBuddy -x -c "Print :BuildIdentities:0" BuildManifest.plist > /tmp/BI0.plist
/usr/libexec/PlistBuddy -c "Add :BuildIdentities:1 dict" BuildManifest.plist
/usr/libexec/PlistBuddy -x -c "Merge /tmp/BI0.plist :BuildIdentities:1" BuildManifest.plist
sudo rm -f /tmp/BI0.plist

/usr/libexec/PlistBuddy -c "Set :BuildIdentities:1:Info:RestoreBehavior Update" BuildManifest.plist
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:1:Info:Variant Customer Upgrade Install (IPSW)" BuildManifest.plist
rm $(plutil -extract "BuildIdentities".1."Manifest"."RestoreTrustCache"."Info"."Path" raw -expect string -o - BuildManifest.plist) 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:1:Manifest:RestoreRamDisk:Info:Path arm64SURamDisk2.dmg" BuildManifest.plist
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:1:Manifest:RestoreTrustCache:Info:Path Firmware/arm64SURamDisk2.dmg.trustcache" BuildManifest.plist

ipsw_rootfs=$(plutil -extract "BuildIdentities".0."Manifest"."OS"."Info"."Path" raw -expect string -o - BuildManifest.plist)

mv ../ota/AssetData/converted.dmg "$ipsw_rootfs"
cd ..

if [ ! -e "$2" ]; then
    ../Darwin/pzb -g BuildManifest.plist "$2"
    tv4_restoreramdisk=$(plutil -extract "BuildIdentities".0."Manifest"."RestoreRamDisk"."Info"."Path" raw -expect string -o - BuildManifest.plist)
    tv4_updateramdisk=$(plutil -extract "BuildIdentities".1."Manifest"."RestoreRamDisk"."Info"."Path" raw -expect string -o - BuildManifest.plist)
    rm -f BuildManifest.plist
    ../Darwin/pzb -g "$tv4_restoreramdisk" "$2"
    ../Darwin/pzb -g "$tv4_updateramdisk" "$2"
    mv "$tv4_restoreramdisk" ipsw/arm64SURamDisk.dmg
    mv "$tv4_updateramdisk" ipsw/arm64SURamDisk2.dmg
    cd ipsw
else
    unzip "$2" BuildManifest.plist
    tv4_restoreramdisk=$(plutil -extract "BuildIdentities".0."Manifest"."RestoreRamDisk"."Info"."Path" raw -expect string -o - BuildManifest.plist)
    tv4_updateramdisk=$(plutil -extract "BuildIdentities".1."Manifest"."RestoreRamDisk"."Info"."Path" raw -expect string -o - BuildManifest.plist)
    rm -f BuildManifest.plist
    unzip "$2" "$tv4_restoreramdisk"
    unzip "$2" "$tv4_updateramdisk"
    mv "$tv4_restoreramdisk" ipsw/arm64SURamDisk.dmg
    mv "$tv4_updateramdisk" ipsw/arm64SURamDisk2.dmg
    cd ipsw
fi

# Patch the Restore/Update ramdisk
for identity in $(eval echo {0..$(expr $(plutil -extract BuildIdentities raw -expect array -o - BuildManifest.plist) - 1)}); do
    ipsw_restoreramdisk=$(plutil -extract "BuildIdentities".${identity}."Manifest"."RestoreRamDisk"."Info"."Path" raw -expect string -o - BuildManifest.plist)
    ipsw_restorebehavior=$(plutil -extract "BuildIdentities".${identity}."Info"."RestoreBehavior" raw -expect string -o - BuildManifest.plist)
    case $ipsw_restorebehavior in
        Erase)
            restored_suffix="_external"
            ;;
        Update)
            restored_suffix="_update"
            ;;
        *)
            >&2 echo "Unknown RestoreBehavior: ${ipsw_restorebehavior}"
            exit 1
            ;;
    esac

    if [ -f "${ipsw_restoreramdisk}.rdsk-done" ]; then continue; fi
    ../../Darwin/img4 -i "$ipsw_restoreramdisk" -o decrypted.dmg

    restoreramdisk_mount_path=$(hdiutil attach decrypted.dmg -owners on | awk 'END {print $NF}' | tr -d '\n')
    sudo mount -urw "$restoreramdisk_mount_path"
    sudo ../../Darwin/asr64_patcher "$restoreramdisk_mount_path"/usr/sbin/asr{,.patched}
    sudo mv "$restoreramdisk_mount_path"/usr/sbin/asr{.patched,}

    if [ "$major_version" -ge 15 ]; then
        sudo ../../Darwin/restored_external64_patcher "$restoreramdisk_mount_path"/usr/local/bin/restored${restored_suffix}{,.patched}
        sudo mv "$restoreramdisk_mount_path"/usr/local/bin/restored${restored_suffix}{.patched,}
        sudo ../../Darwin/ldid -s "$restoreramdisk_mount_path"/usr/local/bin/restored${restored_suffix} "$restoreramdisk_mount_path"/usr/sbin/asr
        sudo chmod 755 "$restoreramdisk_mount_path"/usr/local/bin/restored${restored_suffix} "$restoreramdisk_mount_path"/usr/sbin/asr
    else
        sudo ../../Darwin/ldid -s "$restoreramdisk_mount_path"/usr/sbin/asr
        sudo chmod 755 "$restoreramdisk_mount_path"/usr/sbin/asr
    fi

    ipsw_restoretrustcache=$(plutil -extract "BuildIdentities".${identity}."Manifest"."RestoreTrustCache"."Info"."Path" raw -expect string -o - BuildManifest.plist)
    ../../Darwin/trustcache create -v 1 "${ipsw_restoretrustcache}.dec" "$restoreramdisk_mount_path"
    hdiutil detach "${restoreramdisk_mount_path}" -force

    ../../Darwin/img4 -i decrypted.dmg -o "$ipsw_restoreramdisk" -A -T rdsk
    ../../Darwin/img4 -i "${ipsw_restoretrustcache}.dec" -o "${ipsw_restoretrustcache}" -A -T rtsc
    rm -f "${ipsw_restoretrustcache}.dec" decrypted.dmg
    touch "${ipsw_restoreramdisk}.rdsk-done"
done

rm -f *".rdsk-done"
sudo rm -rf ../ota # clear space, no longer needed

# make the ipsw
rm -f ../../ipsws/AppleTV6,2_"$ipsw_version"_"$ipsw_buildnumber"_Restore.ipsw | true
zip -r9 ../../ipsws/AppleTV6,2_"$ipsw_version"_"$ipsw_buildnumber"_Restore.ipsw . -x "*.DS_Store"
cd ../../
sudo rm -rf work | true

echo "Done! Your new ipsw is in ipsws/AppleTV6,2_${ipsw_version}_${ipsw_buildnumber}_Restore.ipsw"
MERGED_EOF

chmod +x "$TMP_MERGED"

# Validate bash syntax of generated file
bash -n "$TMP_MERGED"
echo "✓ Merged makeipsw.sh syntax check passed."

# Define binaries to sync into Darwin/
EXTRA_BINARIES=("yaa" "KPlooshFinder" "iBoot64Patcher" "kerneldiff")

apply_to_repo() {
    local target_dir="$1"
    local repo_name="$(basename "$target_dir")"
    echo ""
    echo "Processing target: $repo_name ($target_dir)..."

    # 1. Update makeipsw.sh
    if [ "$APPLY" -eq 1 ]; then
        if [ -f "$target_dir/makeipsw.sh" ]; then
            cp "$target_dir/makeipsw.sh" "$target_dir/makeipsw.sh.bak"
            echo "  Backed up makeipsw.sh -> makeipsw.sh.bak"
        fi
        cp "$TMP_MERGED" "$target_dir/makeipsw.sh"
        chmod +x "$target_dir/makeipsw.sh"
        echo "  Updated makeipsw.sh with merged version."
    else
        echo "  [DRY-RUN] Would update makeipsw.sh (backup to makeipsw.sh.bak)"
    fi

    # 2. Sync missing Darwin binaries from upstream if missing
    for bin in "${EXTRA_BINARIES[@]}"; do
        local src="$UPSTREAM_DIR/Darwin/$bin"
        local dst="$target_dir/Darwin/$bin"
        if [ -f "$src" ] && [ ! -f "$dst" ]; then
            if [ "$APPLY" -eq 1 ]; then
                cp -p "$src" "$dst"
                echo "  Synced Darwin/$bin from upstream."
            else
                echo "  [DRY-RUN] Would copy Darwin/$bin from upstream."
            fi
        fi
    done
}

if [ -n "$OUTPUT_DIR" ]; then
    echo "Writing merged assets to custom output directory: $OUTPUT_DIR"
    if [ "$APPLY" -eq 1 ]; then
        mkdir -p "$OUTPUT_DIR/Darwin"
        cp "$TMP_MERGED" "$OUTPUT_DIR/makeipsw.sh"
        chmod +x "$OUTPUT_DIR/makeipsw.sh"
        cp -p "$UPSTREAM_DIR/Darwin/"* "$OUTPUT_DIR/Darwin/"
        cp -p "$UPSTREAM_DIR/template.dmg" "$OUTPUT_DIR/"
        cp -p "$UPSTREAM_DIR/LICENSE" "$OUTPUT_DIR/"
        cp -p "$UPSTREAM_DIR/.gitignore" "$OUTPUT_DIR/"
        echo "  Successfully populated $OUTPUT_DIR"
    else
        echo "  [DRY-RUN] Would create and populate $OUTPUT_DIR"
    fi
else
    case "$TARGET" in
        zenzeq)
            apply_to_repo "$ZENZEQ_DIR"
            ;;
        upstream)
            apply_to_repo "$UPSTREAM_DIR"
            ;;
        both)
            apply_to_repo "$ZENZEQ_DIR"
            apply_to_repo "$UPSTREAM_DIR"
            ;;
        *)
            echo "Invalid target: $TARGET" >&2
            exit 1
            ;;
    esac
fi

echo ""
echo "Merge complete! $([ "$APPLY" -eq 1 ] && echo "Changes applied successfully." || echo "Dry-run finished. Run with --apply to apply.")"
