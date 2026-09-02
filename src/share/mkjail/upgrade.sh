#!/bin/sh
set -e
set -u
trap _cleanup HUP INT QUIT KILL TERM ABRT

aflag=0
jflag=0
vflag=0
pflag=0
PAGER=cat
SNAPNAME="mkjail-$(date '+%Y-%m-%d-%H:%M:%S')"
TARGETVER=null
PKG_REFRESH="y"
: ${ARCH=$(uname -m)}

# PKGBASE / PKGBASE_REPO are exported by bin/mkjail from mkjail.conf.
# Fall back to sane defaults so this script also works standalone.
: ${PKGBASE:="no"}
: ${PKGBASE_REPO:="FreeBSD-base"}

_set_version()
{
    local NEWJAILVER=$(${JAILROOT}/${JAILNAME}/bin/freebsd-version -u)
    zfs set mkjail:version="${NEWJAILVER}" "${ZPOOL}/${JAILDATASET}/${JAILNAME}"
}

_get_version()
{
    zfs get -Hp mkjail:version "${1}" | awk '{print $3}' | sed -E 's,-p[0-9]+,,'
}

# Upgrade base via release tarballs + etcupdate + freebsd-update (legacy).
_upgrade_base_legacy()
{
    tar --clear-nochange-fflags --exclude=etc -xzpf /var/db/mkjail/releases/${ARCH}/${TARGETVER}/base.txz -C ${JAILROOT}/${JAILNAME}/ || _cleanup
    if [ -d ${JAILROOT}/${JAILNAME}/usr/lib32 ] ; then
        tar --clear-nochange-fflags --exclude=etc -xzpf /var/db/mkjail/releases/${ARCH}/${TARGETVER}/lib32.txz -C ${JAILROOT}/${JAILNAME}/ || _cleanup
    fi
    mkdir -p ${JAILROOT}/${JAILNAME}/usr/src && mount -t nullfs -oro ${SRCPATH}/usr/src ${JAILROOT}/${JAILNAME}/usr/src
    jexec ${JAILNAME} etcupdate resolve || _cleanup
    jexec ${JAILNAME} etcupdate -F || _cleanup
}

# Finish the legacy upgrade after the package refresh.
_finish_legacy()
{
    yes | jexec ${JAILNAME} make -C /usr/src delete-old
    yes | jexec ${JAILNAME} make -C /usr/src delete-old-libs

    umount -f ${JAILROOT}/${JAILNAME}/usr/src
    PAGER=cat freebsd-update --not-running-from-cron -b ${JAILROOT}/${JAILNAME} -f ${JAILROOT}/${JAILNAME}/etc/freebsd-update.conf --currently-running ${TARGETVER} -F fetch install
    rm -rf ${JAILROOT}/${JAILNAME}/boot ${JAILROOT}/${JAILNAME}/src
}

# Upgrade base via pkgbase.
# pkg on the host is pointed at the target ABI/OSVERSION so it will pull
# the new release's base packages into the jail. These are derived from
# TARGETVER (e.g. 15.1-RELEASE -> ABI FreeBSD:15:<proc>, OSVERSION 1501000)
# but can be overridden with PKGBASE_ABI / PKGBASE_OSVERSION.
_upgrade_base_pkgbase()
{
    local MAJOR MINOR
    MAJOR=${TARGETVER%%[.-]*}
    case "${TARGETVER}" in
        *.*) MINOR=${TARGETVER#*.} ; MINOR=${MINOR%%-*} ;;
        *)   MINOR=0 ;;
    esac
    : ${PKGBASE_ABI:="FreeBSD:${MAJOR}:$(uname -p)"}
    : ${PKGBASE_OSVERSION:="$(( MAJOR * 100000 + MINOR * 1000 ))"}

    echo "Updating the repo..."
    pkg -j ${JAILNAME} update -r ${PKGBASE_REPO} || _cleanup

    echo "Updating the base packages..."
    pkg -j ${JAILNAME} -oABI=${PKGBASE_ABI} -oOSVERSION=${PKGBASE_OSVERSION} upgrade -yr ${PKGBASE_REPO} || _cleanup
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

    if [ "${PKGBASE}" = "yes" ]; then
        _upgrade_base_pkgbase
    else
        _upgrade_base_legacy
    fi

    if [ $PKG_REFRESH = 'y' ]; then
      # do the package upgrade
      jexec ${JAILNAME} /usr/local/sbin/pkg delete -fy pkg || _cleanup
      ASSUME_ALWAYS_YES=yes jexec ${JAILNAME} /usr/sbin/pkg bootstrap || _cleanup
      jexec ${JAILNAME} /bin/rm -f /var/db/pkg/*.meta || _cleanup
      jexec ${JAILNAME} /usr/local/sbin/pkg-static update || _cleanup
      jexec ${JAILNAME} /usr/local/sbin/pkg-static upgrade -fy || _cleanup
    fi

    if [ "${PKGBASE}" != "yes" ]; then
        _finish_legacy
    fi

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

    if [ "${PKGBASE}" = "yes" ]; then
        # Make sure the jail's base is actually managed by pkgbase
        echo "checking jail '${JAILNAME}' has pkgbase"
        if pkg -j ${JAILNAME} which /usr/bin/uname >/dev/null 2>&1
        then
            echo "The jail '${JAILNAME}' looks to be a pkgbase jail. Proceeding."
        else
            echo "The jail '${JAILNAME}' may not be a pkgbase jail. Check the output of 'pkg -j ${JAILNAME} which /usr/bin/uname'"
            exit 1
        fi
    else
        # Check if we have the sets for the target version we are upgrading to
        [ -f /var/db/mkjail/releases/${ARCH}/${TARGETVER}/base.txz ] || _getrelease
        [ -f /var/db/mkjail/releases/${ARCH}/${TARGETVER}/lib32.txz ] || _getrelease
        [ -f /var/db/mkjail/releases/${ARCH}/${TARGETVER}/src.txz ] || _getrelease
        [ -d ${SRCPATH} ] || _getrelease
    fi
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
    if [ "${PKGBASE}" != "yes" ]; then
        umount -f ${JAILROOT}/${JAILNAME}/usr/src
    fi
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
usage: mkjail upgrade [-b] [-a] [-v TARGETVER] | [-b] [-j JAILNAME] [-v TARGETVER] [-p y/n]

        -a Upgrade all running jails
        -b Use pkgbase (pkg upgrade from the ${PKGBASE_REPO} repo) instead of
           release tarballs + freebsd-update. Can also be enabled globally
           with PKGBASE="yes" in mkjail.conf. The jail must already be a
           pkgbase jail.
        -h Show help
        -j Jail name
        -p [y|n] whether or not to upgrade packages (y = default)
        -v FreeBSD version (e.g., 11.1-RELEASE)
        -p pkg flag, y or n - do you want to upgrade the packages - defaults to y - never specify n if changing major versions.

mkjail.sh: 2019, feld@FreeBSD.org
           2026, dvl@FreeBSD.org
           2026, zi@FreeBSD.org

HELP
exit 0
}

# option parsing has to happen below the show_help
# shift to skip the first argument or getopts loses its mind
shift
while getopts "abhj:v:p:" opt; do
    case "${opt}" in
        a)  aflag=1
            ;;
        b)  PKGBASE="yes"
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
    if [ "${PKGBASE}" != "yes" ]; then
        SRCPATH="$(zfs get -H mountpoint ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET} | awk '{print $3}')/${TARGETVER}"
    fi
    _alljails
fi

if [ ${jflag} -eq 1 ]; then
    if [ "${PKGBASE}" != "yes" ]; then
        SRCPATH="$(zfs get -H mountpoint ${ZPOOL_MKJAIL_DB}/${MKJAILDATASET} | awk '{print $3}')/${TARGETVER}"
    fi
    _upgradejail
    exit 0
fi

# No -a or -j given
show_help
