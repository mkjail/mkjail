#!/bin/sh
set -u
trap _cleanup HUP INT QUIT KILL TERM ABRT

: ${ARCH=$(uname -m)}
sflag=0
vflag=0

_cleanup()
{
    echo ""
    echo "Error: could not fetch dists. Cleaning up."
    rm -rf /var/db/mkjail/releases/${ARCH}/${VERSION}
    exit 1
}

_manifest()
{
    for DIST in $(echo "${SETS}"); do
        DIST="${DIST}.txz"
        CK=`sha256 -q /var/db/mkjail/releases/${ARCH}/${VERSION}/${DIST}`
        awk -v checksum=$CK -v DIST=$DIST -v found=0 '{
            if (DIST == $1) {
                found = 1
                if (checksum == $2)
                    exit(0)
                else
                    exit(2)
            }
        } END {if (!found) exit(1);}' /var/db/mkjail/releases/${ARCH}/${VERSION}/MANIFEST

        if [ $? -eq 0 ]; then
            echo "${DIST}: sha256 verified"
        else
            echo "${DIST}: sha256 failed"
            exit 1
        fi
    done
}

_getrelease()
{
    # Ensure we always have src in the sets
    SETS=$(echo "${SETS}" src | awk -v RS="[ \n]+" '!n[$0]++')

    mkdir -p /var/db/mkjail/releases/${ARCH}/${VERSION}

    cd /var/db/mkjail/releases/${ARCH}/${VERSION}

    # If tarballs already exist locally, skip fetching
    if [ -f base.txz ]; then
        echo "Release tarballs for ${VERSION} already exist locally, skipping fetch."
    else
        echo "Fetching release manifest..."
        fetch https://download.freebsd.org/ftp/releases/${ARCH}/${VERSION}/MANIFEST || fetch http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/${ARCH}/${VERSION}/MANIFEST || _cleanup

        echo "Fetching release tarballs..."
        for i in $(echo "${SETS}"); do
           fetch https://download.freebsd.org/ftp/releases/${ARCH}/${VERSION}/${i}.txz || fetch http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/${ARCH}/${VERSION}/${i}.txz || _cleanup
        done

        _manifest || _cleanup
    fi

    # Migrate old layout (dataset contained only src) to new layout
    # (dataset contains full release, src is a child dataset)
    if zfs list -H -o name "${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${VERSION}" >/dev/null 2>&1; then
        if ! zfs list -H -o name "${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${VERSION}/src" >/dev/null 2>&1; then
            echo "Migrating old ZFS dataset layout for ${VERSION}..."
            zfs destroy -r -f "${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${VERSION}"
        fi
    fi

    # Create the ZFS dataset for this release
    echo "Creating ZFS dataset for ${VERSION}..."
    zfs create -p ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${VERSION}

    if [ "$(zfs get -H mountpoint ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET} | awk '{print $3}')" = "none" ]; then
        zfs set mountpoint=/mkjail ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}
    fi

    RELPATH="$(zfs get -H mountpoint ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET} | awk '{print $3}')/${VERSION}"

    # Extract all sets except src into the release filesystem
    for set in $(echo "${SETS}" | tr ' ' '\n' | grep -v '^src$'); do
        echo "Extracting ${set} into ${RELPATH}..."
        tar -xzpf /var/db/mkjail/releases/${ARCH}/${VERSION}/${set}.txz -C ${RELPATH}/
    done

    # Create src as a child ZFS dataset so it stays separate from jail deployments
    echo "Creating child dataset for src..."
    zfs create ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${VERSION}/src
    SRCPATH="${RELPATH}/src"

    echo "Extracting src into child dataset..."
    tar -xzpf /var/db/mkjail/releases/${ARCH}/${VERSION}/src.txz -C ${SRCPATH}/

    # Take a snapshot for cloning jails from
    echo "Taking snapshot for jail creation..."
    zfs snapshot ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${VERSION}@clean

    # Unmount datasets — they are only mounted temporarily during upgrades
    zfs unmount -f ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${VERSION}
    zfs set mountpoint=none ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${VERSION}

    echo "Release ${VERSION} is ready for jail creation."
}

show_help() {
cat <<HELP
usage: mkjail getrelease [-s "SETS"] [-v VERSION]

        -s Sets: "base doc games lib32"
        -v Version of jail (9.3-RELEASE, 10.1-RELEASE, etc)

mkjail.sh: 2019, feld@FreeBSD.org

HELP
exit 0
}

exit_opts_req() {
    echo "Both -s and -v must be specified." >&2
    echo ""
    show_help
    exit 1
}

# option parsing has to happen below the show_help
# shift to skip the first argument or getopts loses its mind
shift
while getopts "hs:v:" opt; do
    case ${opt} in
        h)  show_help
            ;;
        s)  sflag=1; SETS=${OPTARG}
            ;;
        v)  vflag=1; VERSION=${OPTARG}
            ;;
        *)  show_help
            ;;
    esac
done

shift $(($OPTIND - 1))

if [ ${vflag} -eq 0 ]; then
    exit_opts_req
fi

_getrelease
