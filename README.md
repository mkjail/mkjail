# mkjail

## Origins

This work was created by [Mark Felder](https://github.com/feld) who gave
Dan Langille the sourcecode.  Dan uploaded it first to [his private git server](https://git.langille.org/dvl/mkjail),
then to [his GitHub account](https://github.com/dlangille/mkjail).

Shortly thereafter, https://github.com/mkjail/mkjail was created.

# Back to your regularly scheduled program


This needs a bit of work yet but I have plans to extend it to make jail
creation easy without bloating up features. Fat jails, not ezjail style
jails. And it should permit upgrading them too, as well as fectching dists.

I'll clean it up soon. I promise.

# howto

This script assumes you're using ZFS. mkjai should be in the same
root dir as everything else you create below. (yeah, i know...)

1. clone this repo

2. make a flavour if you want

    <pre>
    # mkdir -p /var/db/mkjail/flavours/default/etc
    # vi /var/db/mkjail/flavours/default/etc/resolv.conf
    </pre>

3. make your jail. The -j is the name you want your jail to be.

    <pre>
    # ./src/bin/mkjai create -v 10.3-RELEASE -j testjail -f default
    Creating zroot/jails/testjail...
    Extracting base into /zroot/jails/testjail...
    Extracting doc into /zroot/jails/testjail...
    Extracting games into /zroot/jails/testjail...
    Extracting lib32 into /zroot/jails/testjail...
    Copying in our configs...
    
    Now put something like the following in /etc/jail.conf:
    
    exec.start = "/bin/sh /etc/rc";
    exec.stop = "/bin/sh /etc/rc.shutdown";
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

4. Put the recommendation into your /etc/jail.conf

5. sysrc jail_enable=YES

6. service jail start testjail

Have fun.
