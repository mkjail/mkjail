#!/bin/sh
set -e

. "$SCRIPTPREFIX/lib.sh"

: ${ARCH=$(uname -m)}

ip4int=$(route -4 get default >/dev/null 2>&1 | awk '/interface: / {print $2}')
ip6int=$(route -6 get default >/dev/null 2>&1 | awk '/interface: / {print $2}')
ip4guess=$(ifconfig ${ip4int} | awk '/inet / && !/127.0/ {print $2}' | head -n 1)
ip6guess=$(ifconfig ${ip6int} | awk '/inet6 / && !/(fe80| ::1)/ {print $2}' | head -n 1)

show_help() {
cat <<HELP
usage: mkjail create [-b | -B] [-j JAILNAME] [-a ARCH] [-v VERSION] [-f FLAVOUR] [-s "SETS"]

        -a Architecture (i386, amd64, etc)
	-b Install the base system with pkgbase (bsdinstall pkgbase),
	   as PKGBASE="yes" in mkjail.conf does. Needs FreeBSD 15.0 or later.
	-B Install the base system from release tarballs, overriding
	   PKGBASE="yes" in mkjail.conf. Use this for releases before 15.0.
	-f Flavour (copy in files after creation)
	-h View this help
	-j Jail name
	-s Sets: "base lib32"
	-v Version of jail (9.3-RELEASE, 10.1-RELEASE, etc)

mkjail.sh: 2019, feld@FreeBSD.org
           2026, dvl@FreeBSD.org
           2026, zi@FreeBSD.org

HELP
}

exit_opts_req() {
    echo "Both -j and -v must be specified." >&2
    echo ""
    show_help
    exit 1
}


# option parsing has to happen below the show_help
# shift to skip the first argument or getopts loses its mind
shift
while getopts "a:bBf:hj:v:s:" opt; do
    case ${opt} in
        a)  ARCH=${OPTARG}
            ;;
        b)  PKGBASE="yes"
            ;;
        B)  PKGBASE="no"
            ;;
        f)  fflag=1; FLAVOUR=${OPTARG}
            ;;
        h)
            show_help
            exit 0
            ;;
        j)  jflag=1; JAILNAME=${OPTARG}
            ;;
        s)  sflag=1; SETS=${OPTARG}
            ;;
        v)  vflag=1; VERSION=${OPTARG}
            ;;
    esac
done

shift $(($OPTIND - 1))

if [ -z $jflag ]
then
    exit_opts_req
fi

if [ -z $vflag ]
then
    exit_opts_req
fi

_init() {
    # From mkjail.conf
    #   ZPOOL
    #   JAILDATASET
    #   JAILROOT

    create_zfs_dataset "$ZPOOL/$JAILDATASET" "$JAILROOT"
}

# The dataset this run creates. If the base install fails after the
# dataset exists, _report_leftover says so: it is left in place, and a
# new attempt with the same jail name stops at "dataset already exists"
# until it is removed.
DATASET="${ZPOOL}/${JAILDATASET}/${JAILNAME}"
created=0
installed=0

_report_leftover() {
    if [ "${created}" = 1 ] && [ "${installed}" != 1 ]; then
        cat >&2 <<LEFTOVER

The base system install failed, but ${DATASET} was already
created and still exists. Remove it before trying again:

    zfs destroy -r ${DATASET}
LEFTOVER
    fi
}
trap _report_leftover EXIT

# Major and minor version of the jail, e.g. 14.4-RELEASE gives 14 and 4.
MAJOR=${VERSION%%[.-]*}
case "${VERSION}" in
    *.*) MINOR=${VERSION#*.} ; MINOR=${MINOR%%-*} ;;
    *)   MINOR=0 ;;
esac

# bsdinstall pkgbase installs the FreeBSD-set-minimal-jail package and
# its friends. Those set packages first appear in the 15.0 repositories,
# and the host only trusts the pkgbase signing key of its own major
# release, so a pkgbase install of anything older than 15 cannot work.
# Checked before anything is created.
if [ "${PKGBASE}" = "yes" ] && [ "${MAJOR}" -lt 15 ] 2>/dev/null; then
    cat >&2 <<TOO_OLD
Error: ${VERSION} cannot be installed with pkgbase (PKGBASE="yes").
pkgbase jails need FreeBSD 15.0 or later: older base repositories have
no FreeBSD-set-* packages for bsdinstall to install.

Create this jail from release tarballs instead:

    mkjail create -B -j ${JAILNAME} -a ${ARCH} -v ${VERSION}

That jail is updated with freebsd-update, so run mkjail update and
upgrade on it with PKGBASE="no" (without -b).
TOO_OLD
    exit 1
fi

_build() {
# Make sure the release exists for non-pkgbase installs
if [ ${PKGBASE} != "yes" ] && [ ! -d /var/db/mkjail/releases/${ARCH}/${VERSION} ]; then
    echo "Release ${VERSION} does not exist. Attempting to fetch..."
    ${SCRIPTPREFIX}/getrelease.sh FAKEARG -s "${SETS}" -v ${VERSION}
fi

# Make sure target flavor exists
if [ x"${fflag}" = x1 ] && [ ! -d /var/db/mkjail/flavours/${FLAVOUR} ]; then
    echo "Error: flavour ${FLAVOUR} does not exist. Please create it first."
    exit 1
fi

# Create the ZFS filesystem
echo "Creating ${DATASET}..."
zfs create "${DATASET}"
created=1
zfs set mkjail:version="${VERSION}" "${DATASET}"

if [ "${PKGBASE}" = "yes" ]; then
    # this needs the oABI stuff - see upgrade.sh:_upgrade_base_pkgbase() for details
    # XXX this code is duplicated in upgrade.sh
    : ${ABI:="FreeBSD:${MAJOR}:${ARCH}"}
    : ${OSVERSION:="$(( MAJOR * 100000 + MINOR * 1000 ))"}
    BSDINSTALL_CHROOT="${JAILROOT}/${JAILNAME}"
    export ABI OSVERSION BSDINSTALL_CHROOT

    # Keep bsdinstall's output: when it fails, that is the only place
    # the reason (repository, signature, missing package) shows up.
    if ! (yes no | bsdinstall pkgbase --jail --non-interactive); then
        echo "Error: bsdinstall pkgbase failed for ${ABI} (see above)." >&2
        exit 1
    fi
else
    # Extract the files
    for set in $(echo "${SETS}"); do
        echo "Extracting ${set} into ${JAILROOT}/${JAILNAME}..."
        tar -xf /var/db/mkjail/releases/${ARCH}/${VERSION}/$set.txz -C ${JAILROOT}/${JAILNAME} ;
    done

fi
installed=1

# Always use default flavor if it exists
if [ -d /var/db/mkjail/flavours/default ] ; then
    echo "Copying in default flavor..."
    cp -a /var/db/mkjail/flavours/default/ ${JAILROOT}/${JAILNAME}
fi

if [ x"${fflag}" = x1 ] && [ "${FLAVOUR}" != "default" ]; then
    # copy in additional flavor dirs and files
    echo "Copying in ${FLAVOUR} flavor..."
    cp -a /var/db/mkjail/flavours/${FLAVOUR}/ ${JAILROOT}/${JAILNAME}
fi

# jail has to be running to pkgbase upgrade it
# but it is not running yet
if [ "${PKGBASE}" != "yes" ]; then
    ${SCRIPTPREFIX}/update.sh update -j ${JAILNAME}
fi
}

_docs() {
# Give instructions
cat <<DOCS

Now put something like the following in /etc/jail.conf:

exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown jail";
exec.clean;
mount.devfs;
path = ${JAILROOT}/\$name;
securelevel = 2;

${JAILNAME} {
    host.hostname = "${JAILNAME}";
    ip4.addr = ${ip4guess};
    ip6.addr = ${ip6guess};
    persist;
}

and then you can start the jail like so:

# service jail start ${JAILNAME}

DOCS
}

_init
_build
_docs
