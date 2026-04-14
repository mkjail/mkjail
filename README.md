# mkjail

## About

`mkjail` can be used on `FreeBSD` to create new jails, keep them updated, and upgrade to a new release.

`mkjail` requires the use of `ZFS`. Each release is stored as a ZFS dataset, and jails are created as
ZFS clones of these datasets. This makes jail creation nearly instant and very space-efficient.

The `src` distribution set is kept as a child ZFS dataset so it can be mounted into jails during the
upgrade process without being included in jail deployments.

`mkjail` is not a jail manager. Jails are configured via `/etc/jail.conf` and started/stopped via
`service jail start foo`.

## ZFS Layout

```
${ZPOOL_MKJAIL_DB}/${MKJAILDATASET}/
└── ${VERSION}/              # Release filesystem (base, lib32, etc.)
    └── src/                 # Child dataset for src (mounted during upgrades)
```

Jails are created as clones:

```
${ZPOOL}/${JAILDATASET}/
└── ${JAILNAME}/             # Clone of ${VERSION}@clean
```

## Origins

This work was created by [Mark Felder](https://github.com/feld) who gave
Dan Langille the sourcecode.  Dan uploaded it first to [his private git server](https://git.langille.org/dvl/mkjail),
then to [his GitHub account](https://github.com/dlangille/mkjail).

Shortly thereafter, https://github.com/mkjail/mkjail was created.

# getrelease

When running getrelease, I advise not specifying the `-s` parameter. Just
let the `mkjail.conf` configuration file do its work.

Release tarballs are fetched, verified, and extracted into ZFS datasets.
A snapshot is taken of the release dataset for cloning jails.

# howto

This script assumes you're using ZFS. `mkjail` should be in the same
root dir as everything else you create below. (yeah, i know...)

1. clone this repo

2. make a flavour if you want

    <pre>
    # mkdir -p /var/db/mkjail/flavours/default/etc
    # vi /var/db/mkjail/flavours/default/etc/resolv.conf
    </pre>

3. fetch a release

    <pre>
    # ./src/bin/mkjail getrelease -v 14.2-RELEASE
    </pre>

4. make your jail. The -j is the name you want your jail to be.

    <pre>
    # ./src/bin/mkjail create -v 14.2-RELEASE -j testjail -f default
    Cloning zroot/mkjail/14.2-RELEASE@clean to zroot/jails/testjail...
    Copying in default flavor...

    Now put something like the following in /etc/jail.conf:

    exec.start = "/bin/sh /etc/rc";
    exec.stop = "/bin/sh /etc/rc.shutdown jail";
    exec.clean;
    mount.devfs;
    path = /zroot/jails/$name;

    testjail {
        host.hostname = "testjail";
        ip4.addr = 172.16.1.122;
        ip6.addr = 2602:100:4475:7e4e::2;
    }

    and then you can start the jail like so:

    # service jail start testjail
    </pre>

5. Put the recommendation into your `/etc/jail.conf`:

    <pre>
    sysrc jail_enable=YES
    </pre>

6. Then issue this command:

    <pre>
    service jail start testjail
    </pre>

Have fun.
