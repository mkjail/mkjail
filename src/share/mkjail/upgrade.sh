#!/bin/sh
set -e
set -u
trap _cleanup HUP INT QUIT KILL TERM ABRT

aflag=0
jflag=0
vflag=0
PAGER=cat
SNAPNAME="mkjail-$(date '+%Y%m%d%H%M')"
TARGETVER=null
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
    chflags -f noschg ${JAILROOT}/${JAILNAME}/var/empty
    chflags -f noschg ${JAILROOT}/${JAILNAME}/usr/src
    tar --clear-nochange-fflags --exclude=etc -xzpf /var/db/mkjail/releases/${ARCH}/${TARGETVER}/base.txz -C ${JAILROOT}/${JAILNAME}/ || _cleanup
    if [ -d ${JAILROOT}/${JAILNAME}/usr/lib32 ] ; then
        tar --clear-nochange-fflags --exclude=etc -xzpf /var/db/mkjail/releases/${ARCH}/${TARGETVER}/lib32.txz -C ${JAILROOT}/${JAILNAME}/ || _cleanup
    fi
    mkdir -p ${JAILROOT}/${JAILNAME}/usr/src && mount -t nullfs -oro ${SRCPATH}/usr/src ${JAILROOT}/${JAILNAME}/usr/src
    jexec ${JAILNAME} etcupdate resolve || _cleanup
    jexec ${JAILNAME} etcupdate -F || _cleanup
    jexec ${JAILNAME} /usr/local/sbin/pkg delete -fy pkg || _cleanup
    ASSUME_ALWAYS_YES=yes jexec ${JAILNAME} /usr/sbin/pkg bootstrap || _cleanup
    jexec ${JAILNAME} /bin/rm -f /var/db/pkg/*.meta || _cleanup
    jexec ${JAILNAME} /usr/local/sbin/pkg-static update || _cleanup
    jexec ${JAILNAME} /usr/local/sbin/pkg-static upgrade -fy || _cleanup
    yes | jexec ${JAILNAME} make -C /usr/src delete-old
    yes | jexec ${JAILNAME} make -C /usr/src delete-old-libs
    umount -f ${JAILROOT}/${JAILNAME}/usr/src
    PAGER=cat freebsd-update -b ${JAILROOT}/${JAILNAME} -f ${JAILROOT}/${JAILNAME}/etc/freebsd-update.conf --currently-running ${TARGETVER} -F fetch install
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

    # Capture mkjail:version zfs property for rollback
    export MKJAILVER="$(zfs get -H mkjail:version "${ZPOOL}/${JAILDATASET}/${JAILNAME}" | awk '{print $3}')"

    # Check if we have the sets for the target version we are upgrading to
    [ -f /var/db/mkjail/releases/${ARCH}/${TARGETVER}/base.txz ] || _getrelease
    [ -f /var/db/mkjail/releases/${ARCH}/${TARGETVER}/lib32.txz ] || _getrelease
    [ -f /var/db/mkjail/releases/${ARCH}/${TARGETVER}/src.txz ] || _getrelease
    [ -d ${SRCPATH} ] || _getrelease
}

_getrelease()
{
    echo "Missing required sets for ${TARGETVER}."
    echo "Please run 'mkjail getrelease' for the version you want to upgrade to."
    exit 1
}

_snapshot()
{
    zfs snapshot "${ZPOOL}/${JAILDATASET}/${JAILNAME}@${SNAPNAME}"
}

_rollback()
{
    umount -f ${JAILROOT}/${JAILNAME}/usr/src
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
usage: mkjail upgrade [-a] [-v TARGETVER] | [-j JAILNAME] [-v TARGETVER]

        -a Upgrade all running jails
        -h Show help
        -j Jail name
        -v FreeBSD version (e.g., 11.1-RELEASE)

mkjail.sh: 2019, feld@FreeBSD.org

HELP
exit 0
}

# option parsing has to happen below the show_help
# shift to skip the first argument or getopts loses its mind
shift
while getopts "ahj:v:" opt; do
    case "${opt}" in
        a)  aflag=1
            ;;
        h)  show_help
            ;;
        j)  jflag=1; JAILNAME=${OPTARG}
            ;;
        v)  vflag=1; TARGETVER=${OPTARG}
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
    SRCPATH="$(zfs get -H mountpoint ${ZPOOL}/${MKJAILDATASET} | awk '{print $3}')/${TARGETVER}"
    _alljails
fi

if [ ${jflag} -eq 1 ]; then
    SRCPATH="$(zfs get -H mountpoint ${ZPOOL}/${MKJAILDATASET} | awk '{print $3}')/${TARGETVER}"
    _upgradejail
fi

[ $# -lt 1 ] && show_help
