#!/bin/sh
set -e
set -u
trap _cleanup HUP INT QUIT KILL TERM ABRT

aflag=0
jflag=0
vflag=0
pflag=0
PAGER=cat
SNAPNAME="mkjail-$(date '+%Y%m%d%H%M')"
TARGETVER=null
PKG_REFRESH="y"
: ${ARCH=$(uname -m)}

_set_version()
{
    local NEWJAILVER=$(${JAILROOT}/${JAILNAME}/bin/freebsd-version -u)
    zfs set mkjail:version="${NEWJAILVER}" "${ZPOOL}/${JAILDATASET}/${JAILNAME}"
}

_get_version()
{
    zfs get -Hp mkjail:version "${1}" | awk '{print $3}' | sed -E 's,-p[0-9]+,,'
}

_upgradejail()
{
    _validate
    _snapshot
    JAILVER=$(_get_version "${ZPOOL}/${JAILDATASET}/${JAILNAME}")
    echo "Upgrading ${JAILNAME} jail from ${JAILVER} to ${TARGETVER}..."
    echo ""

    # Temporarily mount the release dataset
    RELPATH="/tmp/mkjail-${TARGETVER}"
    mkdir -p "${RELPATH}"
    zfs set mountpoint="${RELPATH}" "${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${TARGETVER}"
    zfs mount "${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${TARGETVER}"

    # Temporarily mount the src child dataset
    SRCPATH="${RELPATH}/src"
    mkdir -p "${SRCPATH}"
    zfs set mountpoint="${SRCPATH}" "${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${TARGETVER}/src"
    zfs mount "${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${TARGETVER}/src"

    chflags -f noschg ${JAILROOT}/${JAILNAME}/var/empty
    chflags -f noschg ${JAILROOT}/${JAILNAME}/usr/src

    # Extract the target release over the existing jail, preserving /etc
    echo "Applying ${TARGETVER} release to jail..."
    tar -cf - -C ${RELPATH} --exclude=etc --exclude=src . | tar -xf - -C ${JAILROOT}/${JAILNAME}/ --clear-nochange-fflags || _cleanup

    # Mount src from the target release
    mkdir -p ${JAILROOT}/${JAILNAME}/usr/src && mount -t nullfs -oro ${SRCPATH}/usr/src ${JAILROOT}/${JAILNAME}/usr/src
    jexec ${JAILNAME} etcupdate resolve || _cleanup
    jexec ${JAILNAME} etcupdate -F || _cleanup

    if [ $PKG_REFRESH = 'y' ]; then
      # do the package upgrade
      jexec ${JAILNAME} /usr/local/sbin/pkg delete -fy pkg || _cleanup
      ASSUME_ALWAYS_YES=yes jexec ${JAILNAME} /usr/sbin/pkg bootstrap || _cleanup
      jexec ${JAILNAME} /bin/rm -f /var/db/pkg/*.meta || _cleanup
      jexec ${JAILNAME} /usr/local/sbin/pkg-static update || _cleanup
      jexec ${JAILNAME} /usr/local/sbin/pkg-static upgrade -fy || _cleanup
    fi

    yes | jexec ${JAILNAME} make -C /usr/src delete-old
    yes | jexec ${JAILNAME} make -C /usr/src delete-old-libs

    # Unmount src from the jail
    umount -f ${JAILROOT}/${JAILNAME}/usr/src

    # Unmount temp release datasets and set back to none
    zfs unmount -f "${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${TARGETVER}"
    zfs set mountpoint=none "${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${TARGETVER}"
    rmdir "${RELPATH}"

    PAGER=cat freebsd-update --not-running-from-cron -b ${JAILROOT}/${JAILNAME} -f ${JAILROOT}/${JAILNAME}/etc/freebsd-update.conf --currently-running ${TARGETVER} -F fetch install
    rm -rf ${JAILROOT}/${JAILNAME}/boot ${JAILROOT}/${JAILNAME}/src
    _set_version
}

_alljails()
{
    local JAILPATH
    for JAILNAME in $(jls -q name); do
      JAILPATH=$(jls -j ${JAILNAME} -q path)
      JAILVER=$(_get_version ${JAILPATH})
      if [ "${TARGETVER}" != "${JAILVER}" ] && [ "${JAILPATH}" != '/' ]; then
        _upgradejail
      fi
    done
}

_validate()
{
    # Check for valid parameters
    if [ "${TARGETVER}x" = "x" ]; then
      show_help
    fi

    # Ensure jail is actually running
    if ! jls -j ${JAILNAME} >/dev/null 2>&1 ; then
      echo "Error: jail ${JAILNAME} not running."
      exit 1
    fi

    # check PKG_REFRESH y or n
    if [ $PKG_REFRESH != 'y' ] && [ $PKG_REFRESH != 'n' ]; then
      echo "Error: pkgflag must be y or n."
      exit 1
    fi

    # Capture mkjail:version zfs property for rollback
    export MKJAILVER="$(zfs get -H mkjail:version "${ZPOOL}/${JAILDATASET}/${JAILNAME}" | awk '{print $3}')"

    # Check if we have the ZFS dataset for the target version we are upgrading to
    if ! zfs list -H -o name "${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${TARGETVER}/src" >/dev/null 2>&1; then
      _getrelease
    fi
}

_getrelease()
{
    echo "Missing required release dataset for ${TARGETVER}."
    echo "Please run 'mkjail getrelease' for the version you want to upgrade to."
    exit 1
}

_snapshot()
{
    zfs snapshot "${ZPOOL}/${JAILDATASET}/${JAILNAME}@${SNAPNAME}"
}

_rollback()
{
    umount -f ${JAILROOT}/${JAILNAME}/usr/src 2>/dev/null || true
    # Unmount temp release datasets if still mounted
    zfs unmount -f "${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${TARGETVER}" 2>/dev/null || true
    zfs set mountpoint=none "${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/${TARGETVER}" 2>/dev/null || true
    rmdir "/tmp/mkjail-${TARGETVER}"
    zfs rollback -r "${ZPOOL}/${JAILDATASET}/${JAILNAME}@${SNAPNAME}"
}

_rmsnap()
{
    zfs destroy -r "${ZPOOL}/${JAILDATASET}/${JAILNAME}@${SNAPNAME}"
}

_cleanup()
{
    echo ""
    echo "Upgrade cancelled: reverting changes and cleaning up."
    _rollback
    _rmsnap
    zfs set mkjail:version="${MKJAILVER}" "${ZPOOL}/${JAILDATASET}/${JAILNAME}"
    exit 1
}

show_help() {
cat <<HELP
usage: mkjail upgrade [-a] [-v TARGETVER] | [-j JAILNAME] [-v TARGETVER] [-p y/n]

        -a Upgrade all running jails
        -h Show help
        -j Jail name
        -p [y|n] whether or not to upgrade packages (y = default)
        -v FreeBSD version (e.g., 11.1-RELEASE)
        -p pkg flag, y or n - do you want to upgrade the packages - defaults to y - never specify n if changing major versions.

mkjail.sh: 2019, feld@FreeBSD.org

HELP
exit 0
}

# option parsing has to happen below the show_help
# shift to skip the first argument or getopts loses its mind
shift
while getopts "ahj:v:p:" opt; do
    case "${opt}" in
        a)  aflag=1
            ;;
        h)  show_help
            ;;
        j)  jflag=1; JAILNAME=${OPTARG}
            ;;
        v)  vflag=1; TARGETVER=${OPTARG}
            ;;
        p)  pflag=1; PKG_REFRESH=${OPTARG}
            ;;
        *)  show_help
            ;;
    esac
done

if [ ${vflag} -eq 0 ]; then
    show_help
fi

if [ ${aflag} -eq 1 ] && [ ${jflag} -eq 1 ]; then
    show_help
fi

if [ ${aflag} -eq 1 ]; then
    _alljails
fi

if [ ${jflag} -eq 1 ]; then
    _upgradejail
fi

[ $# -lt 1 ] && show_help
