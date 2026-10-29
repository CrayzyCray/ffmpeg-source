#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'USAGE'
Usage:
  build-ffmpeg-android.sh --source-dir PATH [options]

Options:
  --source-dir PATH         Clean FFmpeg source directory to copy into the build workspace.
  --ndk PATH                Android NDK path (default: $ANDROID_NDK_HOME).
  --api LEVEL               Android API level (default: 24).
  --abi ABI                 Android ABI (default: arm64-v8a).
  --work-dir PATH           Build workspace (default: fast WSL native disk if on /mnt/, or ./work).
  --output PATH             Installation output (default: ./output).
  --symbols-file PATH       File containing symbols called by libcamera-engine.so (strips unused functions).
  --jobs N                  Parallel make jobs (default: nproc).
  -h, --help                Show this help.

The script copies the source into the workspace and never modifies
an input source directory or performs Git checkout/reset operations.
USAGE
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR=${SOURCE_DIR:-}
NDK=${ANDROID_NDK_HOME:-}
API_LEVEL=24
ABI=arm64-v8a
WORK_DIR=${WORK_DIR:-}
OUTPUT_DIR="$SCRIPT_DIR/output"
SYMBOLS_FILE=${SYMBOLS_FILE:-}
JOBS=$(nproc)

while (($#)); do
    case "$1" in
        --source-dir)
            SOURCE_DIR=$2
            shift 2
            ;;
        --ndk)
            NDK=$2
            shift 2
            ;;
        --api)
            API_LEVEL=$2
            shift 2
            ;;
        --abi)
            ABI=$2
            shift 2
            ;;
        --work-dir)
            WORK_DIR=$2
            shift 2
            ;;
        --output)
            OUTPUT_DIR=$2
            shift 2
            ;;
        --symbols-file)
            SYMBOLS_FILE=$2
            shift 2
            ;;
        --jobs)
            JOBS=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

case "$ABI" in
    arm64-v8a)
        ARCH=aarch64
        TARGET_TRIPLE=aarch64-linux-android
        ;;
    *)
        fail "Only arm64-v8a is supported by this script"
        ;;
esac

[[ -n "$SOURCE_DIR" ]] || fail "Specify --source-dir"
[[ -n "$NDK" ]] || fail "Specify --ndk or set ANDROID_NDK_HOME"
[[ -d "$NDK" ]] || fail "NDK directory does not exist: $NDK"
[[ "$API_LEVEL" =~ ^[0-9]+$ ]] || fail "API level must be an integer"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "jobs must be a positive integer"

if [[ -z "$WORK_DIR" ]]; then
    if [[ "$SCRIPT_DIR" =~ ^/mnt/ ]]; then
        WORK_DIR="${HOME}/.cache/ffmpeg-android-build/work"
    else
        WORK_DIR="$SCRIPT_DIR/work"
    fi
fi

if [[ -n "$SYMBOLS_FILE" ]]; then
    [[ -f "$SYMBOLS_FILE" ]] || fail "Specified --symbols-file not found: $SYMBOLS_FILE"
    SYMBOLS_FILE=$(cd "$(dirname "$SYMBOLS_FILE")" && pwd)/$(basename "$SYMBOLS_FILE")
fi

HOST_TAG=linux-x86_64
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
BIN="$TOOLCHAIN/bin"
SYSROOT="$TOOLCHAIN/sysroot"

CC_NAME="${TARGET_TRIPLE}${API_LEVEL}-clang"
CXX_NAME="${TARGET_TRIPLE}${API_LEVEL}-clang++"
AR_NAME="llvm-ar"
NM_NAME="llvm-nm"
RANLIB_NAME="llvm-ranlib"
STRIP_NAME="llvm-strip"
READELF_NAME="llvm-readelf"

CC="$BIN/$CC_NAME"
CXX="$BIN/$CXX_NAME"
AR="$BIN/$AR_NAME"
NM="$BIN/$NM_NAME"
RANLIB="$BIN/$RANLIB_NAME"
STRIP="$BIN/$STRIP_NAME"
READELF="$BIN/$READELF_NAME"
MAKE=$(command -v make || true)

for required in "$CC" "$CXX" "$AR" "$NM" "$RANLIB" "$STRIP" "$READELF"; do
    [[ -x "$required" ]] || fail "Required tool is missing or not executable: $required"
done
[[ -n "$MAKE" && -x "$MAKE" ]] || fail "make is not installed"
[[ -f "$SYSROOT/usr/include/vulkan/vulkan.h" ]] || fail "Vulkan headers not found in NDK sysroot: $SYSROOT/usr/include/vulkan/vulkan.h"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
WORK_DIR=$(cd "$WORK_DIR" && pwd)
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
BUILD_SOURCE="$WORK_DIR/source"
BUILD_DIR="$WORK_DIR/build"
LOG_FILE="$WORK_DIR/build.log"
rm -rf "$BUILD_SOURCE" "$BUILD_DIR"
mkdir -p "$BUILD_SOURCE" "$BUILD_DIR" "$BUILD_DIR/empty-pkg-config"

[[ -d "$SOURCE_DIR" ]] || fail "Source directory does not exist: $SOURCE_DIR"
SOURCE_DIR=$(cd "$SOURCE_DIR" && pwd)
cp -a "$SOURCE_DIR"/. "$BUILD_SOURCE"/

[[ -f "$BUILD_SOURCE/configure" ]] || fail "Source does not contain FFmpeg configure: $BUILD_SOURCE"

exec > >(tee "$LOG_FILE") 2>&1

echo "FFmpeg Android build"
echo "source: $BUILD_SOURCE"
echo "ndk: $NDK"
echo "abi: $ABI"
echo "api: $API_LEVEL"
echo "work-dir: $WORK_DIR"
echo "output: $OUTPUT_DIR"
echo "symbols-file: ${SYMBOLS_FILE:-none (full export)}"
echo "jobs: $JOBS"

cd "$BUILD_SOURCE"

# Add toolchain bin to PATH so configure can find tools by name without embedding
# local machine or user directory paths into FFMPEG_CONFIGURATION / avcodec_configuration()
export PATH="$BIN:$PATH"

PKG_CONFIG_LIBDIR="$BUILD_DIR/empty-pkg-config" \
./configure \
    --prefix=/ \
    --enable-cross-compile \
    --target-os=android \
    --arch="$ARCH" \
    --cc="$CC_NAME" \
    --cxx="$CXX_NAME" \
    --ar="$AR_NAME" \
    --nm="$NM_NAME" \
    --ranlib="$RANLIB_NAME" \
    --strip="$STRIP_NAME" \
    --extra-cflags="-O3 -fPIC -ffunction-sections -fdata-sections" \
    --extra-ldflags="-Wl,-z,max-page-size=16384 -Wl,--gc-sections -Wl,--icf=all -Wl,-Bsymbolic-functions -Wl,--undefined-version" \
    --enable-shared \
    --disable-static \
    --disable-programs \
    --disable-everything \
    --disable-doc \
    --disable-debug \
    --disable-avdevice \
    --disable-swresample \
    --disable-swscale \
    --disable-avfilter \
    --enable-bsf=extract_extradata \
    --enable-parser=hevc \
    --enable-parser=apv \
    --enable-protocol=file \
    --enable-demuxer=hevc \
    --enable-muxer=mov \
    --enable-encoder=prores_aw \
    --enable-vulkan \
    --enable-encoder=prores_ks_vulkan \
    --enable-encoder=pcm_f32le \
    --pkg-config=false \
    --enable-lto \
    --enable-hardcoded-tables

# Assert that no local user or workspace paths leaked into the embedded build configuration
if grep -qE "(${HOME:-/home/}|/mnt/c/Users|${WORK_DIR}|${NDK})" "$BUILD_SOURCE/config.h"; then
    fail "FFmpeg config.h leaked local paths into build configuration"
fi

make clean
make -j"$JOBS"

if [[ -n "$SYMBOLS_FILE" ]]; then
    echo "Applying symbol stripping based on $SYMBOLS_FILE..."

    CLEAN_SYMBOLS="$WORK_DIR/symbols_clean.txt"
    sed -e 's/#.*//' -e 's/@.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$SYMBOLS_FILE" \
        | grep -v '^$' \
        | sort -u > "$CLEAN_SYMBOLS"

    echo "Pruning libraries to retain $(wc -l < "$CLEAN_SYMBOLS") requested symbols..."

    AVFORMAT_VER_NUM=$(grep 'libavformat_VERSION_MAJOR=' libavformat/libavformat.version | cut -d= -f2)
    AVCODEC_VER_NUM=$(grep 'libavcodec_VERSION_MAJOR=' libavcodec/libavcodec.version | cut -d= -f2)
    AVUTIL_VER_NUM=$(grep 'libavutil_VERSION_MAJOR=' libavutil/libavutil.version | cut -d= -f2)

    # Defined symbols exported in unstripped pass 1
    "$READELF" --dyn-symbols libavformat/libavformat.so | grep -E ' (FUNC|OBJECT|NOTYPE) .* GLOBAL DEFAULT +[0-9]' | awk '{print $8}' | sed 's/@.*//' | grep -v '^$' | sort -u > "$WORK_DIR/avformat_all_defined.txt"
    "$READELF" --dyn-symbols libavcodec/libavcodec.so | grep -E ' (FUNC|OBJECT|NOTYPE) .* GLOBAL DEFAULT +[0-9]' | awk '{print $8}' | sed 's/@.*//' | grep -v '^$' | sort -u > "$WORK_DIR/avcodec_all_defined.txt"
    "$READELF" --dyn-symbols libavutil/libavutil.so | grep -E ' (FUNC|OBJECT|NOTYPE) .* GLOBAL DEFAULT +[0-9]' | awk '{print $8}' | sed 's/@.*//' | grep -v '^$' | sort -u > "$WORK_DIR/avutil_all_defined.txt"

    # Step 1: Prune libavformat
    echo "LIBAVFORMAT_${AVFORMAT_VER_NUM} {" > libavformat/libavformat.ver
    echo "    global:" >> libavformat/libavformat.ver
    comm -12 "$CLEAN_SYMBOLS" "$WORK_DIR/avformat_all_defined.txt" | while read -r sym; do
        echo "        $sym;" >> libavformat/libavformat.ver
    done
    echo "    local:" >> libavformat/libavformat.ver
    echo "        *;" >> libavformat/libavformat.ver
    echo "};" >> libavformat/libavformat.ver

    rm -f libavformat/libavformat.so*
    make libavformat/libavformat.so SHFLAGS="-shared -Wl,-soname,libavformat.so -Wl,-Bsymbolic -Wl,--undefined-version -Wl,--version-script,libavformat/libavformat.ver"

    # Step 2: Prune libavcodec (requested symbols + dependencies from pruned libavformat)
    "$READELF" --dyn-symbols libavformat/libavformat.so | grep ' UND ' | awk '{print $8}' | sed 's/@.*//' | grep -v '^$' > "$WORK_DIR/avformat_und.txt"
    cat "$CLEAN_SYMBOLS" "$WORK_DIR/avformat_und.txt" | sort -u > "$WORK_DIR/codec_candidates.txt"

    echo "LIBAVCODEC_${AVCODEC_VER_NUM} {" > libavcodec/libavcodec.ver
    echo "    global:" >> libavcodec/libavcodec.ver
    comm -12 "$WORK_DIR/codec_candidates.txt" "$WORK_DIR/avcodec_all_defined.txt" | while read -r sym; do
        echo "        $sym;" >> libavcodec/libavcodec.ver
    done
    echo "    local:" >> libavcodec/libavcodec.ver
    echo "        *;" >> libavcodec/libavcodec.ver
    echo "};" >> libavcodec/libavcodec.ver

    rm -f libavcodec/libavcodec.so*
    make libavcodec/libavcodec.so SHFLAGS="-shared -Wl,-soname,libavcodec.so -Wl,-Bsymbolic -Wl,--undefined-version -Wl,--version-script,libavcodec/libavcodec.ver"

    # Step 3: Prune libavutil (requested symbols + dependencies from pruned libavformat and libavcodec)
    "$READELF" --dyn-symbols libavcodec/libavcodec.so | grep ' UND ' | awk '{print $8}' | sed 's/@.*//' | grep -v '^$' > "$WORK_DIR/avcodec_und.txt"
    cat "$CLEAN_SYMBOLS" "$WORK_DIR/avformat_und.txt" "$WORK_DIR/avcodec_und.txt" | sort -u > "$WORK_DIR/util_candidates.txt"

    echo "LIBAVUTIL_${AVUTIL_VER_NUM} {" > libavutil/libavutil.ver
    echo "    global:" >> libavutil/libavutil.ver
    comm -12 "$WORK_DIR/util_candidates.txt" "$WORK_DIR/avutil_all_defined.txt" | while read -r sym; do
        echo "        $sym;" >> libavutil/libavutil.ver
    done
    echo "    local:" >> libavutil/libavutil.ver
    echo "        *;" >> libavutil/libavutil.ver
    echo "};" >> libavutil/libavutil.ver

    rm -f libavutil/libavutil.so*
    make libavutil/libavutil.so SHFLAGS="-shared -Wl,-soname,libavutil.so -Wl,-Bsymbolic -Wl,--undefined-version -Wl,--version-script,libavutil/libavutil.ver"

    # Relink dependents against the pruned libavutil
    rm -f libavcodec/libavcodec.so* libavformat/libavformat.so*
    make libavcodec/libavcodec.so SHFLAGS="-shared -Wl,-soname,libavcodec.so -Wl,-Bsymbolic -Wl,--undefined-version -Wl,--version-script,libavcodec/libavcodec.ver"
    make libavformat/libavformat.so SHFLAGS="-shared -Wl,-soname,libavformat.so -Wl,-Bsymbolic -Wl,--undefined-version -Wl,--version-script,libavformat/libavformat.ver"

    # Verify symbol resolution
    echo "Verifying symbol resolution..."
    missing=0
    while read -r sym; do
        found=0
        for lib in libavformat/libavformat.so libavcodec/libavcodec.so libavutil/libavutil.so; do
            if "$READELF" --dyn-symbols "$lib" | grep -E ' (FUNC|OBJECT|NOTYPE) .* GLOBAL DEFAULT +[0-9]' | awk '{print $8}' | sed 's/@.*//' | grep -qx "$sym"; then
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            echo "ERROR: Requested symbol not found in any stripped library: $sym" >&2
            missing=$((missing + 1))
        fi
    done < "$CLEAN_SYMBOLS"

    for lib in libavformat/libavformat.so libavcodec/libavcodec.so; do
        for sym in $("$READELF" --dyn-symbols "$lib" | grep ' UND ' | awk '{print $8}' | sed 's/@.*//'); do
            found=0
            for dep in libavcodec/libavcodec.so libavutil/libavutil.so; do
                if "$READELF" --dyn-symbols "$dep" | grep -E ' (FUNC|OBJECT|NOTYPE) .* GLOBAL DEFAULT +[0-9]' | awk '{print $8}' | sed 's/@.*//' | grep -qx "$sym"; then
                    found=1
                    break
                fi
            done
            if [[ $found -eq 0 && "$sym" =~ ^(av|avio|sws|swr) ]]; then
                echo "ERROR: Unresolved FFmpeg dependency in $lib: $sym" >&2
                missing=$((missing + 1))
            fi
        done
    done

    [[ $missing -eq 0 ]] || fail "Symbol verification failed with $missing missing symbol(s)"
    echo "Symbol verification passed: all requested and internal symbols resolved cleanly."
fi

make install DESTDIR="$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/share"

shopt -s nullglob
libraries=("$OUTPUT_DIR"/lib/*.so)
((${#libraries[@]} > 0)) || fail "No shared libraries were installed in $OUTPUT_DIR/lib"
for library in "${libraries[@]}"; do
    echo "Stripping $library"
    "$STRIP" "$library"
    echo "Checking $library for TEXTREL"
    "$READELF" --dynamic "$library" | grep -q TEXTREL && fail "TEXTREL found in $library"
done

cat > "$WORK_DIR/build-metadata.txt" <<META
source_directory=$BUILD_SOURCE
ndk=$NDK
abi=$ABI
api_level=$API_LEVEL
output=$OUTPUT_DIR
symbols_file=${SYMBOLS_FILE:-none}
stripped=$([[ -n "$SYMBOLS_FILE" ]] && echo "yes" || echo "no")
configure_log=$BUILD_SOURCE/ffbuild/config.log
script=$SCRIPT_DIR/build-ffmpeg-android.sh
META

echo "Build complete"
echo "Libraries: $OUTPUT_DIR/lib"
echo "Headers: $OUTPUT_DIR/include"
echo "Log: $LOG_FILE"
