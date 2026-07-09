#!/bin/sh
# Baut das installierbare CCU-Addon-Paket asksinanalyzer-<version>.tar.gz
# (Installation ueber WebUI -> Systemsteuerung -> Zusatzsoftware)
set -e
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
OUT="asksinanalyzer-${VERSION}.tar.gz"
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
cp pkg/rc.d/asksinanalyzer "${STAGE}/rc.d/"
mkdir -p "${STAGE}/asksinanalyzer/www"
cp VERSION "${STAGE}/asksinanalyzer/"
cp www/index.html www/api.cgi "${STAGE}/asksinanalyzer/www/"

mkdir -p "${STAGE}/asksinanalyzer/${ARCH}"
cp "${BINDIR}/multimacd" "${BINDIR}/rfd" "${STAGE}/asksinanalyzer/${ARCH}/"
for l in ${LIBS}; do
    cp "${LIBDIR}/${l}" "${STAGE}/asksinanalyzer/${ARCH}/"
done

chmod 755 "${STAGE}/update_script" "${STAGE}/rc.d/asksinanalyzer" \
          "${STAGE}/asksinanalyzer/www/api.cgi" \
          "${STAGE}/asksinanalyzer/${ARCH}"/*

tar -czf "${OUT}" -C "${STAGE}" \
    --owner=root --group=root --numeric-owner \
    update_script rc.d asksinanalyzer

echo "erstellt: $(pwd)/${OUT}"
tar -tzf "${OUT}"
