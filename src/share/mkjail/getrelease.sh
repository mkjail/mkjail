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
    # Ensure we always have src and lib32 in the sets
    SETS=$(echo "${SETS}" src lib32 | awk -v RS="[ \n]+" '!n[$0]++')

    mkdir -p /var/db/mkjail/releases/${ARCH}/${VERSION}

    cd /var/db/mkjail/releases/${ARCH}/${VERSION}

    echo "Fetching release manifest..."
    fetch https://download.freebsd.org/ftp/releases/${ARCH}/${VERSION}/MANIFEST || fetch http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/${ARCH}/${VERSION}/MANIFEST || _cleanup

    echo "Fetching release tarballs..."
    for i in $(echo "${SETS}"); do 
       fetch https://download.freebsd.org/ftp/releases/${ARCH}/${VERSION}/${i}.txz || fetch http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/${ARCH}/${VERSION}/${i}.txz || _cleanup
    done

    _manifest || _cleanup

    zfs create -p ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${VERSION}

    if [ "$(zfs get -H mountpoint ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET} | awk '{print $3}')" = "none" ]; then
        zfs set mountpoint=/mkjail ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}
    fi

    SRCPATH="$(zfs get -H mountpoint ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET} | awk '{print $3}')/${VERSION}"

    echo "Extracting src for use in jail upgrades..."
    tar -xzpf /var/db/mkjail/releases/${ARCH}/${VERSION}/src.txz -C ${SRCPATH}/
}

show_help() {
cat <<HELP
usage: mkjail getrelease [-s "SETS"] [-v VERSION]

        -s Sets: "base doc games lib32"
        -v Version of jail (9.3-RELEASE, 10.1-RELEASE, etc)

mkjail.sh: 2019, feld@FreeBSD.org

HELP
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
