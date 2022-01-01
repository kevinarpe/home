#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# The return value of a pipeline is the status of
# the last command to exit with a non-zero status,
# or zero if no command exited with a non-zero status
set -o pipefail
# Print commands and their arguments as they are executed.
# set -x

# Ref: https://stackoverflow.com/questions/50879845/how-to-assign-the-array-to-another-variable-in-bash
G_ORIG_ARGS=("$@")

# Holds output from command: mktemp
# Ex: 'upgrade-jdk.bash.XXXXXXXXXX'
g_tmp_file_path=''

__exit_handler()
{
    local exit_code=$?

    if [ -f "$g_tmp_file_path" ]
    then
        # Intentional: Do not allow 'rm' to kill our script during exit handler.
        set +e
        echo_and_run_cmd \
            rm --force --verbose "$g_tmp_file_path"
        set -e
    fi

    if [ 0 = $exit_code ]
    then
        local prefix='INFO '
    else
        local prefix='ERROR'
    fi
    printf -- '\n%s: %s @ %s: Exit with status code [%d]: %s %s\n\n' \
              "$prefix"                                              \
              "$(whoami)"                                            \
              "$(hostname --fqdn)"                                   \
              $exit_code                                             \
              "$0"                                                   \
              "${G_ORIG_ARGS[*]}"
}

trap __exit_handler EXIT

main()
{
    check_args "$@"

    local install_parent_dir_path="$1" ; shift

    # Ex: '8' or '11' or '17'
    local jdk_version="$1" ; shift

    echo_and_run_cmd \
        cd "$install_parent_dir_path"

    echo_cmd \
        basename "$0"

    local this_script_file_name
    # Ex: 'get-openjdk.bash'
    this_script_file_name="$(basename "$0")"
    printf -- '%s\n' "$this_script_file_name"

    echo_cmd \
        mktemp "$this_script_file_name".XXXXXXXXXX

    # Ex: 'get-openjdk.bash.XXXXXXXXXX'
    g_tmp_file_path="$(mktemp "$this_script_file_name".XXXXXXXXXX)"
    printf -- '%s\n' "$g_tmp_file_path"

    local url='https://api.adoptium.net/v3/binary/latest/'"$jdk_version"'/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk'

    echo_cmd \
        curl --location --head "$url"

    # This can be slow, so we want to use tee to show real-time output.
    curl --location --head "$url" \
        | tee "$g_tmp_file_path"

    local http_headers="$(cat "$g_tmp_file_path")"

    echo_cmd \
        ... '|' grep --perl-regexp --ignore-case '^content-disposition:\s*attachment\s*;\s*filename='

    local content_dispo
    # Ex: 'content-disposition: attachment; filename=OpenJDK8U-jdk_x64_linux_hotspot_8u312b07.tar.gz'
    content_dispo="$(
        printf -- '%s' "$http_headers" \
        | grep --perl-regexp --ignore-case '^content-disposition:\s*attachment\s*;\s*filename='
    )"
    printf -- '%s\n' "$content_dispo"

    echo_cmd \
        ... '|' perl -p -e 's/^content-disposition:\s*attachment\s*;\s*filename=(.*)\r/$1/'

    local tar_file_name
    # Ex: 'content-disposition: attachment; filename=OpenJDK8U-jdk_x64_linux_hotspot_8u312b07.tar.gz' -> 'OpenJDK8U-jdk_x64_linux_hotspot_8u312b07.tar.gz'
    tar_file_name="$(
        printf -- '%s' "$content_dispo" \
        | perl -p -e 's/^content-disposition:\s*attachment\s*;\s*filename=(.*)\r$/$1/'
    )"
    printf -- '%s\n' "$tar_file_name"

    if [ ! -f "$tar_file_name" ]
    then
        # Ref: https://stackoverflow.com/a/2701808/257299
        # These args: --remote-header-name --remote-name
        # ... will force curl to download using content-disposition filename from HTTP headers,
        # ... e.g., 'OpenJDK8U-jdk_x64_linux_hotspot_8u312b07.tar.gz'
        echo_and_run_cmd \
            curl  --location --remote-header-name --remote-name "$url"
    fi

    echo_and_run_cmd \
        ls -l "$tar_file_name"

    echo_cmd \
        tar -tf "$tar_file_name" '|' head -n 1

    local tar_parent_dir_rel_path
    # Intentional: Ignore annoying SIGPIPE (141) that appears *ONLY* when this pipeline is run from a "$(...)" sub-shell.  Horrible.
    # Probably gzip complains with SIGPIPE when head exits early because our archive is .tar.gz!
    # Ref: https://stackoverflow.com/questions/769564/error-code-141-with-tar
    set +e

    # Ex: 'jdk8u312-b07/'
    tar_parent_dir_rel_path="$(tar -tf "$tar_file_name" | head -n 1)"

    # Order of $? capture and set -e is important!
    local exit_status=$?
    set -e

    # Captain Obvious says: Only exit if not EXIT_SUCCESS or SIGPIPE.
    if [ 0 != $exit_status ] && [ 141 != $exit_status ]
    then
        exit $exit_status
    fi

    # Symbolic links for directory names have weird behaviour with trailing forward slash ('/') -- remove it.
    # Ref: https://codeyarns.com/tech/2016-10-10-trailing-slash-in-symbolic-link.html

    # Ref: https://stackoverflow.com/a/9018877/257299
    # Ex: 'jdk8u312-b07/' -> 'jdk8u312-b07'
    tar_parent_dir_rel_path="${tar_parent_dir_rel_path%/}"

    printf -- '%s\n' "$tar_parent_dir_rel_path"

    if [ -d "$tar_parent_dir_rel_path" ]
    then
        printf -- '\nTAR parent dir already exists (do not untar again!): %s\n' "$tar_parent_dir_rel_path"
    else
        echo_and_run_cmd \
            tar -xf "$tar_file_name"
    fi

    echo_and_run_cmd \
        ls -ld "$tar_parent_dir_rel_path"

    # Ex: "jdk-8"
    local symlink_name="jdk-$jdk_version"
    if [ -L "$symlink_name" ]
    then
        echo_cmd \
            readlink "$symlink_name"

        local symlink_target
        symlink_target="$(readlink "$symlink_name")"
        printf -- '%s\n' "$symlink_target"

        if [ "$symlink_target" != "$symlink_name" ]
        then
            echo_and_run_cmd \
                rm --force --verbose "$symlink_name"
        fi
    fi

    echo_and_run_cmd \
        ln --symbolic --verbose "$tar_parent_dir_rel_path" "$symlink_name"

    echo_and_run_cmd \
        ls -l "$symlink_name"

    echo_and_run_cmd \
        cd -
}

check_args()
{
    if [ 2 != $# ]
    then
        printf -- 'ERROR: Missing required arguments or too many arguments\n'
        printf -- '\n'
        printf -- 'Usage: %s INSTALL_PARENT_DIR JDK_VERSION\n' "$0"
        printf -- 'From https://adoptium.net/, find latest JDK minor version, download, untar, and update symlink, e.g., jdk-8\n'
        printf -- '\n'
        printf -- '\n'
        printf -- 'Required Arguments:\n'
        printf -- '    INSTALL_PARENT_DIR: parent path for installation\n'
        printf -- '        Example: $HOME/dev or $HOME/saveme\n'
        printf -- '\n'
        printf -- '    JDK_VERSION: whole/major JDK version number\n'
        printf -- '        Example: 8 or 11 or 17\n'
        printf -- '\n'
        printf -- 'Optional Arguments:\n'
        printf -- '    (none)\n'
        printf -- '\n'
        printf -- 'Example:\n'
        printf -- '    %s $HOME/dev 8\n' "$0"
        printf -- '\n'
        printf -- '    URL = https://api.adoptium.net/v3/binary/latest/8/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk\n'
        printf -- '    ... downloads file: $HOME/dev/OpenJDK8U-jdk_x64_linux_hotspot_8u312b07.tar.gz\n'
        printf -- '    ... untars to directory: $HOME/dev/jdk8u312-b07\n'
        printf -- '    ... creates symbolic link: $HOME/dev/jdk-8 -> jdk8u312-b07\n'
        printf -- '\n'
        exit 1
    fi
}

echo_cmd()
{
    echo
    echo '$' "$@"
}

echo_and_run_cmd()
{
    echo_cmd "$@"
    "$@"
}

main "$@"

