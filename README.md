# FFmpeg source

The application uses unmodified **FFmpeg 9.0.2** under the
[GNU Lesser General Public License, version 2.1 or later](COPYING.LGPLv2.1).

This repository provides the complete corresponding FFmpeg source archive,
the license text, and the build script used for the application's
FFmpeg shared libraries.

## Source

- Upstream project: <https://ffmpeg.org/>
- Release: FFmpeg 9.0.2
- Unmodified source: [`ffmpeg-git.zip`](ffmpeg-git.zip)
- License text: [`COPYING.LGPLv2.1`](COPYING.LGPLv2.1)
- Local FFmpeg changes: none

## Rebuilding

The script builds FFmpeg as separate shared libraries for the Android target (`arm64-v8a`)
used by the application.

Install the Android SDK/NDK, Vulkan SDK, extract the source archive, and run the build script:

```sh
# Unpack the source archive
unzip ffmpeg-git.zip -d .

# Build for Android (arm64-v8a, API 24+)
export ANDROID_NDK_HOME=/path/to/android-ndk
./build-ffmpeg-android.sh \
    --source-dir ./ffmpeg-git \
    --ndk "$ANDROID_NDK_HOME" \
    --symbols-file ./symbols.txt
```

To build without symbol stripping (exporting all symbols), omit `--symbols-file ./symbols.txt`.

Build products are in `output/`.

## Linking and Relinking

The application links to these FFmpeg libraries dynamically and includes them as
separate files in the distributed application package.

An interface-compatible FFmpeg build produced by these scripts can replace the
corresponding packaged FFmpeg shared libraries. Mobile application packages
must be signed again after any such replacement.

FFmpeg is a trademark.
This project is not affiliated with or endorsed by the FFmpeg project.
