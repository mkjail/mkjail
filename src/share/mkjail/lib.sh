# /usr/include/sysexits.h
EX_OK=0         # successful termination
EX_ERROR=1      # unsuccessful termination
EX_USAGE=64     # command line usage error
EX_CANTCREAT=73 # can't create (user) output file
EX_CONFIG=78    # configuration error


create_zfs_dataset() {
    # Create a ZFS dataset if it does not exist
    local dataset_name=$1
    local mount_point=$2

    if ! zfs list -H -o name "$dataset_name" >/dev/null; then
        echo "Creating dataset $dataset_name"
        zfs create -p -o mountpoint="$mount_point" "$dataset_name"
        local ret=$?
        if [ "$ret" -ne 0 ]; then
            echo "Unable to create dataset $dataset_name" >&2
            exit $EX_CANTCREAT
        fi
    fi
}

check_zfs_dataset_config() {
    # Check a ZFS dataset exists and it' mount point is correct
    local dataset_name=$1
    local cfg_mount_point=$2
    local config_file=$3

    local ds_mount_point=$(
        zfs get -H -o value mountpoint "$dataset_name" 2>/dev/null || \
            echo "NOT_EXIST"
    )
    case "$ds_mount_point" in
        "NOT_EXIST"|"$cfg_mount_point")
            # OK, if it doesn't exist it will be created later
            ;;

        "none")
            echo "ZFS dataset $dataset_name has no mount point set" >&2
            exit $EX_CONFIG
            ;;

        *)
            echo "Mount point for ZFS dataset $dataset_name does not match " \
                "$cfg_mount_point, check your configuration in $config_file." >&2
            exit $EX_CONFIG
            ;;
    esac
}
