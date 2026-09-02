# mkjail

## About

`mkjail` can be used on `FreeBSD` to create new jails, keep them updated, and upgrade to a new release.

`mkjail` requires the use of `ZFS` will create each new jail in a separate filesystem.

`mkjail` is not a jail manager. Jails are configured via `/etc/jail.conf` and started/stopped via
`service jail start foo`.

## Origins

This work was created by [Mark Felder](https://github.com/feld) who gave
Dan Langille the sourcecode.  Dan uploaded it first to [his private git server](https://git.langille.org/dvl/mkjail),
then to [his GitHub account](https://github.com/dlangille/mkjail).

Shortly thereafter, https://github.com/mkjail/mkjail was created.

When pkgbase came to FreeBSD, Dan converted the code to use pkgbase, not
freebsd-update. zi went much farther with that and made the code
dual-purpose: both freebsd-update and pkgbase.

# getrelease

When running getrelease, I advise not specifying the `-s` parameter. Just
let the `mkjail.conf` configuration file do its work.

# howto

This script assumes you're using ZFS. `mkjail` should be in the same
root dir as everything else you create below. (yeah, i know...)

1. clone this repo

2. make a flavour if you want

    <pre>
    # mkdir -p /var/db/mkjail/flavours/default/etc
    # vi /var/db/mkjail/flavours/default/etc/resolv.conf
    </pre>

3. make your jail. The -j is the name you want your jail to be.

    <pre>
    # ./src/bin/mkjail create -v 10.3-RELEASE -j testjail -f default
    Creating zroot/jails/testjail...
    Extracting base into /zroot/jails/testjail...
    Extracting doc into /zroot/jails/testjail...
    Extracting games into /zroot/jails/testjail...
    Extracting lib32 into /zroot/jails/testjail...
    Copying in our configs...
    
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

4. Put the recommendation into your `/etc/jail.conf`:

    <pre>
    sysrc jail_enable=YES
    </pre>

6. Then issue this command:

    <pre>
    service jail start testjail
    </pre>

Have fun.

# pkgbase support

`mkjail` can manage jails whose base system was installed via
[pkgbase](https://wiki.freebsd.org/PkgBase) (base system distributed as pkg
packages) as an alternative to the legacy `freebsd-update` / release tarball
method. Both methods live in the same scripts; you choose per host or per
invocation.

Enable it one of two ways:

* Globally: set `PKGBASE="yes"` in `mkjail.conf` (optionally set
  `PKGBASE_REPO` if your base repo is not named `FreeBSD-base`).
* Per command: pass `-b` to `update`, `upgrade`, or `getrelease`.

What changes in pkgbase mode:

* `mkjail update -b -j foo` runs `pkg -j foo update -r FreeBSD-base` followed
  by `pkg -j foo upgrade -yr FreeBSD-base` instead of `freebsd-update`.
* `mkjail upgrade -b -j foo -v 15.1-RELEASE` still snapshots the jail first
  (and rolls back on failure), verifies the jail actually has a pkgbase base
  system, then upgrades the base packages with pkg using an ABI/OSVERSION
  derived from the target version (override with `PKGBASE_ABI` /
  `PKGBASE_OSVERSION` in the environment if needed). The installed-package
  refresh controlled by `-p` works the same as in legacy mode.
* `mkjail getrelease -b` is a no-op: release tarballs are not needed.
* `mkjail create` currently always builds new jails from release tarballs,
  regardless of the `PKGBASE` setting.

Legacy behaviour is unchanged when `PKGBASE` is unset/`no` and `-b` is not
given.
