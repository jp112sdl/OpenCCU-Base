#!/bin/sh
# Baut das installierbare CCU-Addon-Paket rftrafficlogger-<version>.tar.gz
# (Installation ueber WebUI -> Systemsteuerung -> Zusatzsoftware)
set -e
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
OUT="rftrafficlogger-${VERSION}.tar.gz"
STAGE=$(mktemp -d)
trap 'rm -rf "${STAGE}"' EXIT

# Binaries/Libraries mit TrafficLogger aus dem Repo-Baum (werden vom
# update_script nach /bin bzw. /lib installiert, Original wird gesichert)
ARCH=x86_64-linux-gnu
BINDIR=../../bin/${ARCH}
LIBDIR=../../lib/${ARCH}
LIBS="libhsscomm.so libxmlparser.so libXmlRpc.so libUnifiedLanComm.so libLanDeviceUtils.so libelvutils.so"

# Paketlayout: update_script im Archiv-Root, Payload darunter
cp pkg/update_script "${STAGE}/"
mkdir -p "${STAGE}/rc.d"
cp pkg/rc.d/rftrafficlogger "${STAGE}/rc.d/"
mkdir -p "${STAGE}/rftrafficlogger/www"
cp VERSION "${STAGE}/rftrafficlogger/"
cp www/index.html www/api.cgi "${STAGE}/rftrafficlogger/www/"

mkdir -p "${STAGE}/rftrafficlogger/${ARCH}"
cp "${BINDIR}/multimacd" "${BINDIR}/rfd" "${STAGE}/rftrafficlogger/${ARCH}/"
for l in ${LIBS}; do
    cp "${LIBDIR}/${l}" "${STAGE}/rftrafficlogger/${ARCH}/"
done

chmod 755 "${STAGE}/update_script" "${STAGE}/rc.d/rftrafficlogger" \
          "${STAGE}/rftrafficlogger/www/api.cgi" \
          "${STAGE}/rftrafficlogger/${ARCH}"/*

tar -czf "${OUT}" -C "${STAGE}" \
    --owner=root --group=root --numeric-owner \
    update_script rc.d rftrafficlogger

echo "erstellt: $(pwd)/${OUT}"
tar -tzf "${OUT}"
