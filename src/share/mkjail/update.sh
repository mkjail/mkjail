#!/bin/sh
set -e
set -u

PAGER=cat

_set_version()
{
    local NEWJAILVER=$(${JAILROOT}/${JAILNAME}/bin/freebsd-version -u)
    zfs set mkjail:version=${NEWJAILVER} ${ZPOOL}${JAILROOT}/${JAILNAME}
}

_get_version()
{
    zfs get -Hp mkjail:version ${JAILROOT}/${JAILNAME} | awk '{print $3}' | sed -E 's,-p[0-9]+,,'
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
        export UNAME_r=$(_get_version)
        PAGER=cat freebsd-update -b ${JAILROOT}/${JAILNAME} -f ${JAILROOT}/${JAILNAME}/etc/freebsd-update.conf -F fetch install
        _set_version
      fi
      echo ""
    done
    exit 0
}

_onejail()
{
    echo "Updating ${JAILNAME} jail..."
    echo ""
    export UNAME_r=$(_get_version)
    PAGER=cat freebsd-update -b ${JAILROOT}/${JAILNAME} -f ${JAILROOT}/${JAILNAME}/etc/freebsd-update.conf -F fetch install
    _set_version
    exit 0
}

show_help() {
cat <<HELP
usage: mkjail update [-a] | [-j JAILNAME]

        -a Update all running jails
        -h Show help
        -j Jail name

mkjail.sh: 2019, feld@FreeBSD.org

HELP
exit 0
}

# option parsing has to happen below the show_help
# shift to skip the first argument or getopts loses its mind
shift
while getopts "ahj:" opt; do
    case "${opt}" in
        a)  _alljails
            ;;
        h)  show_help
            ;;
        j)  export JAILNAME=${OPTARG}
            _onejail
            ;;
        *)  show_help
            ;;
    esac
done

shift $((OPTIND - 1))

show_help
