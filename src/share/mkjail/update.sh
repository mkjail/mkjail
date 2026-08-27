#!/bin/sh
set -e
set -u

PAGER=cat

aflag=0
jflag=0

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
    zfs get -Hp mkjail:version "${ZPOOL}/${JAILDATASET}/${JAILNAME}" | awk '{print $3}' | sed -E 's,-p[0-9]+,,'
}

# Update the base system of ${JAILNAME} in place.
# Uses pkgbase when PKGBASE=yes, otherwise legacy freebsd-update.
_do_update()
{
    export UNAME_r=$(_get_version)
    if [ "${PKGBASE}" = "yes" ]; then
        # this ensures the local pkg repo is up to date
        PAGER=cat pkg -j ${JAILNAME} update -r ${PKGBASE_REPO}

        # this does the actual update, despite it being an 'upgrade'
        PAGER=cat pkg -j ${JAILNAME} upgrade -yr ${PKGBASE_REPO}
    else
        PAGER=cat freebsd-update --not-running-from-cron -b ${JAILROOT}/${JAILNAME} -f ${JAILROOT}/${JAILNAME}/etc/freebsd-update.conf -F fetch install
    fi
    _set_version
}

_alljails()
{
    echo "Updating all jails..."
    echo ""
    for JAILNAME in $(jls -q name); do
      JAILPATH=$(jls -j ${JAILNAME} -q path)
      if [ "${JAILPATH}" != '/' ]; then
        echo "Updating ${JAILNAME} jail..."
        echo ""
        _do_update
      fi
      echo ""
    done
    exit 0
}

_onejail()
{
    echo "Updating ${JAILNAME} jail..."
    echo ""
    _do_update
    exit 0
}

show_help() {
cat <<HELP
usage: mkjail update [-b] [-a] | [-b] [-j JAILNAME]

        -a Update all running jails
        -b Use pkgbase (pkg upgrade from the ${PKGBASE_REPO} repo)
           instead of freebsd-update. Can also be enabled globally
           with PKGBASE="yes" in mkjail.conf.
        -h Show help
        -j Jail name

mkjail.sh: 2019, feld@FreeBSD.org

HELP
exit 0
}

# option parsing has to happen below the show_help
# shift to skip the first argument or getopts loses its mind
shift
while getopts "abhj:" opt; do
    case "${opt}" in
        a)  aflag=1
            ;;
        b)  PKGBASE="yes"
            ;;
        h)  show_help
            ;;
        j)  jflag=1; export JAILNAME=${OPTARG}
            ;;
        *)  show_help
            ;;
    esac
done

shift $((OPTIND - 1))

if [ ${aflag} -eq 1 ] && [ ${jflag} -eq 1 ]; then
    show_help
fi

if [ ${aflag} -eq 1 ]; then
    _alljails
fi

if [ ${jflag} -eq 1 ]; then
    _onejail
fi

show_help
