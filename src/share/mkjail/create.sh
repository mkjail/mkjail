#!/bin/sh
set -e

: ${ARCH=$(uname -m)}

ip4int=$(route -4 get default | awk '/interface: / {print $2}')
ip6int=$(route -6 get default | awk '/interface: / {print $2}')
ip4guess=$(ifconfig ${ip4int} | awk '/inet / && !/127.0/ {print $2}' | head -n 1)
ip6guess=$(ifconfig ${ip6int} | awk '/inet6 / && !/(fe80| ::1)/ {print $2}' | head -n 1)

show_help() {
cat <<HELP
usage: mkjail create [-j JAILNAME] [-a ARCH] [-v VERSION] [-f FLAVOUR] [-s "SETS"]

        -a Architecture (i386, amd64, etc)
	-f Flavour (copy in files after creation)
	-h View this help
	-j Jail name
	-s Sets: "base lib32"
	-v Version of jail (9.3-RELEASE, 10.1-RELEASE, etc)

mkjail.sh: 2019, feld@FreeBSD.org

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
while getopts "a:f:hj:v:s:" opt; do
    case ${opt} in
        a)  ARCH=${OPTARG}
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

_build() {
# Make sure the release exists
if [ ! -d /var/db/mkjail/releases/${ARCH}/${VERSION} ]; then
    echo "Release ${VERSION} does not exist. Attempting to fetch..."
    ${SCRIPTPREFIX}/getrelease.sh FAKEARG -s "${SETS}" -v ${VERSION}
fi

# Make sure target flavor exists
if [ x"${fflag}" = x1 ] && [ ! -d /var/db/mkjail/flavours/${FLAVOUR} ]; then
    echo "Error: flavour ${FLAVOUR} does not exist. Please create it first."
    exit 1
fi

# Create the ZFS filesystem
echo "Creating ${ZPOOL}/jails/${JAILNAME}..."
zfs create -p -o mountpoint=/jails ${ZPOOL}/jails
zfs create -p ${ZPOOL}/jails/${JAILNAME}
zfs set mkjail:version=${VERSION} ${ZPOOL}/jails/${JAILNAME}

# Extract the files
for set in $(echo "${SETS}"); do
    echo "Extracting ${set} into ${JAILROOT}/${JAILNAME}..."
    tar -xf /var/db/mkjail/releases/${ARCH}/${VERSION}/$set.txz -C ${JAILROOT}/${JAILNAME} ;
done

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

${SCRIPTPREFIX}/update.sh update -j ${JAILNAME}
}

_docs() {
# Give instructions
cat <<DOCS

Now put something like the following in /etc/jail.conf:

exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown";
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

_build
_docs
