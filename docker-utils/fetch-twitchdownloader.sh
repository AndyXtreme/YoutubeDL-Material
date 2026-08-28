#!/bin/sh

# THANK YOU TALULAH (https://github.com/nottalulah) for your help in figuring this out
# and also optimizing some code with this commit.
# xoxo :D

# TARGET_MACHINE lets the Dockerfile fetch for another architecture than the one
# this script runs on, so multi-arch builds don't need QEMU here.
MACHINE="${TARGET_MACHINE:-$(uname -m)}"

case $MACHINE in
  x86_64)
    ARCH=Linux-x64;;
  aarch64)
    ARCH=LinuxArm64;;
  armhf)
    ARCH=LinuxArm;;
  armv7)
    ARCH=LinuxArm;;
  armv7l)
    ARCH=LinuxArm;;
  *)
    echo "Unsupported architecture: $MACHINE"
    exit 1
esac

echo "(INFO) Architecture detected: $ARCH"
echo "(1/5) READY - Install unzip"
apt-get update && apt-get -y install unzip curl jq libicu70
VERSION=$(curl --silent "https://api.github.com/repos/lay295/TwitchDownloader/releases" | jq -r --arg arch "$ARCH" '[.[] | select(.assets | length > 0) | select(.assets[].name | contains("CLI") and contains($arch))] | max_by(.published_at) | .tag_name')
if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
    echo "Could not determine a TwitchDownloader release for $ARCH (GitHub API rate limit?)"
    exit 1
fi
echo "(2/5) DOWNLOAD - Acquire twitchdownloader $VERSION"
# -f + --retry-all-errors: emulated arm64 builds regularly hit transient TLS
# resets (curl 35), which the default retry list ignores; without -f an error
# page would be unzipped as if it were the archive.
curl -f -o twitchdownloader.zip \
    --connect-timeout 10 \
    --max-time 180 \
    --retry 5 \
    --retry-delay 2 \
    --retry-all-errors \
    -L "https://github.com/lay295/TwitchDownloader/releases/download/$VERSION/TwitchDownloaderCLI-$VERSION-$ARCH.zip"
unzip twitchdownloader.zip
chmod +x TwitchDownloaderCLI
if [ "$MACHINE" = "$(uname -m)" ]; then
    echo "(3/5) Smoke test"
    ./TwitchDownloaderCLI --help
else
    echo "(3/5) Smoke test skipped — binary is for $MACHINE, this is $(uname -m)"
fi
cp ./TwitchDownloaderCLI /usr/local/bin/TwitchDownloaderCLI
