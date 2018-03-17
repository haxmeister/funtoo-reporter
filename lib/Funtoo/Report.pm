package Funtoo::Report;

### Authors : Joshua S. Day (haxmeister), Tom Ryder, ShadowM00n
### purpose : functions for retrieving and sending data on funtoo linux

use 5.014;
use strict;
use warnings;
use Carp;                          #core
use English qw(-no_match_vars);    #core
use HTTP::Tiny;                    #core
use JSON;                          #cpan
use List::Util qw(any);            #core
use POSIX qw(ceil);                #core
use Term::ANSIColor;               #core

our $VERSION = '1.4';

### getting some initialization done:
my $config_file = '/etc/funtoo-report.conf';
my @errors;                        # for any errors that don't cause a die

##
## generates report, creates user agent, and sends to elastic search
##
sub send_report {
    my $rep     = shift;
    my $es_conf = shift;
    my $debug   = shift;

    # if we weren't told whether to show debugging output, don't
    $debug //= 0;

    # constructing the url we will report too
    my $url = "$es_conf->{'node'}/$es_conf->{'index'}/$es_conf->{'type'}";

    # generate a json object that we can use to convert to json
    my $json = JSON->new->allow_nonref;

    # load the report options for the http post
    my %header = ( "Content-Type" => "application/json" );
    my %options = (
        'content' => $json->pretty->encode($rep),
        'headers' => \%header
    );

    # create a new HTTP object
    my $agent = sprintf '%s/%s', __PACKAGE__, $VERSION;
    my $http = HTTP::Tiny->new( agent => $agent );

    # send report and capture the response from ES
    my $response = $http->request( 'POST', $url, \%options );

    # if debugging, dump the entire response content
    if ($debug) {
        print {*STDERR} "$response->{content}\n";
    }

    # error out helpfully on failed submission
    $response->{success}
        or do {
        push_error(
            "Failed submission: $response->{status} $response->{reason}");
        croak;
        };

    # warn if the response code wasn't 201 (Created)
    $response->{status} == 201
        or push_error(
        'Successful submission, but status was not the expected \'201 Created\''
        );

    # print location redirection if there was one, warn if not
    if ( defined $response->{headers}{location} ) {
        print "your report can be seen at: "
            . $es_conf->{'node'}
            . $response->{'headers'}{'location'} . "\n";
    }
    else {
        push_error('Expected location for created resource');
    }
}

##
## finds the config file in /etc/funtoo-report.conf and loads its contents
## into a hash and returns it
#
sub user_config {
    my $args = shift;
    my %hash;

    if ( open( my $fh, '<:encoding(UTF-8)', $config_file ) ) {
        my @lines = <$fh>;
        close $fh;
        foreach my $line (@lines) {
            chomp $line;

            # skip lines that start with '#'
            if ( $line =~ /^\#/msx ) {
                next;
            }

            # split the line on the colon
            # left side becomes a key, right side a value
            elsif ($line) {
                my ( $key, $value ) = split /\s*:\s*/msx, $line;
                $hash{$key} = $value;
            }

            # skip the empty lines also
            else {
                next;
            }
        }
    }
    elsif ( $args and ( $args eq 'new' ) ) {

        # if we arrived here due to config-update() and there isn't
        # a config file then we return a UUID without editing the file
        $hash{'UUID'} = 'none';
        return;
    }
    else {
        # if we arrived here from the command line and there is no
        # config file then tell the user what to do
        print color( 'red', 'bold' );
        print "\nWarning!";
        print color('reset');
        print "\nCould not open the configuration file at $config_file \n";
        print
            "To generate a new configuration file use 'funtoo-report config-update' \n\n";
        exit;
    }

    return %hash;
}

## retrieves UUID from the config file if present and then
## prompts user as it generates settings for a new config file
## ensures all new possibilities are in the config file from previous
## versions, etc.
#
sub config_update {

    # check for existing config
    my %old_config = user_config('new');
    my %new_config;

    # see if we picked up a current UUID from the old config
    if ( $old_config{'UUID'} ) {

        #since it's there we will add it to the new config file
        $new_config{'UUID'} = $old_config{'UUID'};
    }
    else {

        # since there is no previous UUID we will go get a new one
        $new_config{'UUID'} = add_uuid('new');
    }

    # let's ask the user about each report setting

    $new_config{'kernel-info'}
        = get_y_or_n('Report information about your active kernel?');

    $new_config{'boot-dir-info'}
        = get_y_or_n('Report available kernels in /boot ?');

    $new_config{'version-info'}
        = get_y_or_n('Report versions of key system softwares?');

    $new_config{'installed-pkgs'}
        = get_y_or_n('Report all packages installed on the system?');

    $new_config{'world-info'}
        = get_y_or_n('Report the contents of your world file?');

    $new_config{'profile-info'}
        = get_y_or_n('Report the output of "epro show-json"?');

    $new_config{'kit-info'}
        = get_y_or_n('Report the output of "ego kit show"?');

    $new_config{'hardware-info'}
        = get_y_or_n('Report information about your hardware and drivers?');

    # let's create or replace /etc/funtoo-report.conf
    print "Creating or replacing /etc/funtoo-report.conf\n";
    open( my $fh, '>:encoding(UTF-8)', $config_file )
        or croak "Could not open $config_file: $ERRNO\n";
    foreach my $key ( keys %new_config ) {
        print $fh "$key" . ":" . "$new_config{$key}\n";
    }
    close $fh;

}

##
## adds a uuid to /etc/funtoo-report.conf and/or returns it as a string
##
sub add_uuid {

    my $arg = shift;

    # lets just get a random identifier from the system or die trying
    open( my $fh, '<', '/proc/sys/kernel/random/uuid' )
        or croak
        "Cannot open /proc/sys/kernel/random/uuid to generate a UUID: $ERRNO\n";
    my $UUID = <$fh>;
    chomp $UUID;
    close $fh;

    # if we recieved the 'new' argument then we just want to return
    # the UUID without modifying the file. i.e. we came here from the
    # config-update function
    if ( $arg and ( $arg eq 'new' ) ) {
        return $UUID;
    }
    else {

        # since we got here because a UUID isn't present in the config
        # open the config file and append the UUID properly into the file
        open( $fh, '>>', $config_file )
            or croak "Unable to append to $config_file: $ERRNO\n";
        print $fh "\n# A unique identifier for this reporting machine \n";
        print $fh "UUID:$UUID\n";
        close $fh;
    }
    return $UUID;
}

##
## reporting version number
##
sub version {
    return $VERSION;
}

##
## reporting errors
##
sub errors {
    return \@errors;
}

## returns a long date string for the report body or
## returns a string that is like 'funtoo-year.week' that is
## suitable for elasticsearch historical data management
##
## with special date formatting by request
sub report_time {
    my $format  = shift;
    my %formats = (

        # ISO8601 date and time with UTC timezone suffix "Z"
        # e.g. 2018-03-09T22:37:09Z
        long => sub {
            my @t    = @_;
            my $year = $t[5] + 1900;
            my $mon  = $t[4] + 1;
            my $day  = $t[3];
            my $hour = $t[2];
            my $min  = $t[1];
            my $sec  = $t[0];
            return sprintf '%04u-%02u-%02uT%02u:%02u:%02uZ',
                $year, $mon, $day, $hour, $min, $sec;
        },

        # year and week number in UTC with static "funtoo" prefix
        # e.g. funtoo-2018.49
        short => sub {
            my @t    = @_;
            my $year = $t[5] + 1900;
            my $week = ceil( ( $t[7] + 1 ) / 7 );
            return sprintf 'funtoo-%04u.%02u', $year, $week;
        },

    );
    exists $formats{$format}
        or do { push_error('Unable to determine the time'); return };
    return $formats{$format}->(gmtime);
}

##
## returns a hash ref with various hardware info that was
## derived from lspci -kmmvvv and other functions
##
sub get_hardware_info {
    my %hash;

    my %lspci = ( 'PCI-Device' => get_lspci() );

    for my $device ( keys %{ $lspci{'PCI-Device'} } ) {

        # fetching sound info from data structure
        if ( $lspci{'PCI-Device'}{$device}{'Class'} =~ /Audio|audio/msx ) {
            $hash{'audio'}{$device} = \%{ $lspci{'PCI-Device'}{$device} };

        }

        # fetching video cards
        if ( $lspci{'PCI-Device'}{$device}{'Class'} =~ /VGA|vga/msx ) {
            $hash{'video'}{$device} = \%{ $lspci{'PCI-Device'}{$device} };
        }
    }

    # fetching networking devices
    $hash{'networking'} = get_net_info();

    # fetching block devices
    $hash{'filesystem'} = get_filesystem_info();

    # fetching cpu info
    $hash{'cpu'} = get_cpu_info();

    # fetching memory info
    $hash{'memory'} = get_mem_info();

    # fetching chassis info
    $hash{'chassis'} = get_chassis_info();

    return \%hash;
}

##
## returns a hash ref containing networking device info
## by ShadowM00n
## this function goes directly to the source instead
## of making calls to external tools
##
sub get_net_info {

    my $interface_dir = '/sys/class/net';
    my $pci_ids       = '/usr/share/misc/pci.ids';
    my $usb_ids       = '/usr/share/misc/usb.ids';
    my %hash;
    my @interfaces;
    opendir my $dh, $interface_dir
        or
        do { push_error("Unable to open dir $interface_dir: $ERRNO"); return };
    while ( my $file = readdir $dh ) {

        if ( $file !~ /^[.]{1,2}$|^lo$/xms ) {
            push @interfaces, $file;
        }
    }
    closedir $dh;

### @interfaces

    for my $device (@interfaces) {
        my ( $vendor_id, $device_id, $id_file );

        # Create dummy entries for virtual devices and move on
        if ( !-d "$interface_dir/$device/device/driver/module" ) {
            $hash{$device}{'vendor'} = 'Virtual';
            $hash{$device}{'device'} = 'Virtual device';
            $hash{$device}{'driver'} = 'Virtual driver';
            next;
        }

        # Othewise, determine the driver via the path name
        my $driver = (
            split /[\/]/xms,
            readlink "$interface_dir/$device/device/driver/module"
        )[-1];
        ### $driver

        # Get the vendor ID (PCI)
        my $vendor_id_file = "/sys/class/net/$device/device/vendor";
        if ( -e $vendor_id_file ) {
            $id_file = $pci_ids;
            open my $fh, '<', $vendor_id_file
                or do {
                push_error("Unable to open file $vendor_id_file: $ERRNO");
                next;
                };
            $vendor_id = <$fh>;
            close $fh;
            chomp $vendor_id;
            $vendor_id =~ s/^0x//xms;

            # Get the device ID (PCI)
            my $device_id_file = "/sys/class/net/$device/device/device";
            open $fh, '<', $device_id_file
                or do {
                push_error("Unable to open file $device_id_file: $ERRNO");
                next;
                };
            $device_id = <$fh>;
            close $fh;
            chomp $device_id;
            $device_id =~ s/^0x//xms;

        }

        # Or get the vendor and device ID (USB)
        else {
            $vendor_id_file = "/sys/class/net/$device/device/uevent";
            $id_file        = $usb_ids;
            open my $fh, '<', $vendor_id_file
                or do {
                push_error("Unable to open file $vendor_id_file: $ERRNO");
                next;
                };
            while (<$fh>) {
                if (/^PRODUCT=(.*)[\/](.*)[\/].*/xms) {
                    $vendor_id = sprintf '%04s', $1;
                    $device_id = sprintf '%04s', $2;
                    last;
                }
            }
            close $fh;
        }

        # Look up the proper device name from the id file
        my ( $vendor_name, $device_name );

        ## no critic [RequireBriefOpen]
        open my $fh, '<', $id_file
            or do { push_error("Unable to open file $id_file $ERRNO"); next };

     # Devices can share device IDs but not "underneath" a vendor ID, so we'll
     # want to get the first result under the vendor
        my $seen = 0;

        while (<$fh>) {

            if (/^$vendor_id[ ]{2}(.*)/xms) {
                $vendor_name = $1;
                chomp $vendor_name;
                $seen = 1;
            }
            if ( $seen == 1 && /^[\t]{1}$device_id[ ]{2}(.*)/xms ) {
                $device_name = $1;
                chomp $device_name;
                last;
            }
        }
        close $fh;
        $hash{$device}{'vendor'} = $vendor_name;
        $hash{$device}{'device'} = $device_name;
        $hash{$device}{'driver'} = $driver;
    }
    return \%hash;
}

##
## fetching lsblk output
##
sub get_filesystem_info {
    my $hash;
    if ( my $json_from_lsblk
        = `lsblk --bytes --json -o NAME,FSTYPE,SIZE,MOUNTPOINT,PARTTYPE,RM,HOTPLUG,TRAN`
        )
    {
        $hash = decode_json($json_from_lsblk);

        # iterate through the block device tree, fixing it up a little so
        # ElasticSearch can handle it; it doesn't like lists of objects, so we
        # convert those to objects indexed by device name
        my @stack = ( \$hash->{blockdevices} );
        while ( my $list = pop @stack ) {

            # start hash to replace the list
            my %rep;

            # iterate through the list
            for my $dev ( @{ ${$list} } ) {

                # coerce device's size to a number
                $dev->{size} += 0;

                # put this device into the replacement hashref by name
                $rep{ $dev->{name} } = $dev;

             # if this device has a list of children, push a reference to that
             # list onto the stack for the next round
                if ( defined $dev->{children} ) {
                    push @stack, \$dev->{children};
                }
            }

            # run replacement
            ${$list} = \%rep;
        }
    }
    else {
        push_error(
            "Unable to retrieve output from lsblk --bytes --json -o NAME,FSTYPE,SIZE,MOUNTPOINT,PARTTYPE,RM,HOTPLUG,TRAN: $ERRNO"
        );
        return;
    }
    return $hash;
}

##
## fetching lines from /proc/cpuinfo
##
sub get_cpu_info {

    my $cpu_file = '/proc/cpuinfo';
    my %hash;
    my @cpu_file_contents;
    my $proc_count = 0;
    if ( open( my $fh, '<:encoding(UTF-8)', $cpu_file ) ) {
        @cpu_file_contents = <$fh>;
        close $fh;

        foreach my $row (@cpu_file_contents) {
            chomp $row;
            if ($row) {

                # let's split each line on the colon, left is the key
                # right is the value
                my ( $key, $value ) = split /\s*:\s*/msx, $row;

                # now we will just look for the values we want and
                # add them to the hash
                if ( $key eq 'model name' ) {
                    $hash{$key} = $value;
                }
                elsif ( $key eq 'flags' ) {
                    my @cpu_flags = split / /, $value;
                    $hash{$key} = \@cpu_flags;
                }
                elsif ( $key eq 'cpu MHz' ) {
                    $hash{$key} = $value * 1;
                }
                elsif ( $key eq 'processor' ) {

                    # counting lines that are labeled 'processor' which
                    # should give us a number that users expect to see
                    # including logical and physical cores
                    $proc_count = $proc_count + 1;
                }
                else {next}
            }
        }
    }

    else {
        push_error("Could not open file $cpu_file: $ERRNO");
        return;
    }
    $hash{"processors"} = $proc_count;
    return \%hash;
}

##
## fetching a few lines from /proc/meminfo
##
sub get_mem_info {

    # pulling relevant info from /proc/meminfo
    my %hash = (
        MemTotal     => undef,
        MemFree      => undef,
        MemAvailable => undef,
        SwapTotal    => undef,
        SwapFree     => undef,
    );
    my $mem_file = '/proc/meminfo';
    my @mem_file_contents;
    if ( open( my $fh, '<:encoding(UTF-8)', $mem_file ) ) {
        @mem_file_contents = <$fh>;
        close $fh;

        foreach my $row (@mem_file_contents) {

            # get the key and the first numeric value
            my ( $key, $value ) = $row =~ m/ (\S+) : \s* (\d+) /msx
                or next;

            # if there's a hash bucket waiting for this value, add it
            exists $hash{$key} or next;
            $hash{$key} = int $value;
        }
    }
    else {
        push_error("Could not open file $mem_file: $ERRNO");
        return;
    }
    return \%hash;
}

##
## fetch information about the system chassis
##
sub get_chassis_info {
    my %hash;
    my $folder = "/sys/class/dmi/id/";
    my @id_files = ( 'chassis_type', 'chassis_vendor', 'product_name' );

    my @possible_id = (
        'N/A',
        'Other',
        'Unknown',
        'Desktop',
        'Low Profile Desktop',
        'Pizza Box',
        'Mini Tower',
        'Tower',
        'Portable',
        'Laptop',
        'Notebook',
        'Hand Held',
        'Docking Station',
        'All in One',
        'Sub Notebook',
        'Space-Saving',
        'Lunch Box',
        'Main Server Chassis',
        'Expansion Chassis',
        'SubChassis',
        'Bus Expansion Chassis',
        'Peripheral Chassis',
        'RAID Chassis',
        'Rack Mount Chassis',
        'Sealed-Case PC',
        'Multi-system Chassis',
        'Compact PCI',
        'Advanced TCA',
        'Blade',
        'Blade Enclosure',
        'Tablet',
        'Convertible',
        'Detachable',
        'IoT Gateway',
        'Embedded PC',
        'Mini PC',
        'Stick PC'
    );

    for my $file (@id_files) {
        if ( open( my $fh, '<', "$folder$file" ) ) {
            my $content = <$fh>;
            chomp $content;
            if ( $file eq "chassis_type" ) {
                $hash{$file} = $possible_id[$content];
            }
            else {
                $hash{$file} = $content;
            }
            close $fh;
        }
        else {
            push_error("Unable to open $folder$file: $ERRNO");
            $hash{$file} = $possible_id[0];
        }
    }
    return \%hash;

}

##
## fetching active profiles
## reconstruct output of epro show-json command
##
sub get_profile_info {

    # execute 'epro show-json' and capture its output
    if ( my $json_from_epro = `epro show-json` ) {
        my %profiles;
        my %sorted;

        # convert the output from json to a perl data structure
        my $data = decode_json($json_from_epro);
        %profiles = %$data;

        # we are going to reconstruct the epro output without the extra
        # 'shortname' keys, so that it is more easily used in elasticsearch
        foreach my $item ( keys(%profiles) ) {
            foreach my $final ( $profiles{$item} ) {
                foreach my $array_item ( @{$final} ) {
                    push @{ $sorted{$item} }, $array_item->{'shortname'};
                }
            }
        }
        return \%sorted;
    }
    else {
        push_error("Unable to retrieve epro show-json output: $ERRNO");
        return;
    }
}

##
## fetching active kits
## applies /etc/ego.conf contents to the data structure
## at /var/git/meta-repo/metadata/kit-info.json and returns a structure
## that shows only the "active" kit
##
sub get_kit_info {

    my $meta_file = "/var/git/meta-repo/metadata/kit-info.json";
    my $meta_data;
    my $ego_conf = "/etc/ego.conf";
    my %hash;

    # decode and store meta file datastructure into $meta_data
    if ( open( my $fh, '<:encoding(UTF-8)', $meta_file ) ) {
        my @lines = <$fh>;
        close $fh;
        my $data = join( '', @lines );
        $meta_data = decode_json($data);

        # let's define our hash keys from the array found in this file
        foreach my $key ( @{ $meta_data->{"kit_order"} } ) {
            $hash{$key} = "undef";
        }
    }
    else {
        push_error("Cannot open file $meta_file: $ERRNO");
        return;
    }

    # extract valid lines from ego.conf
    if ( open( my $fh, '<:encoding(UTF-8)', $ego_conf ) ) {
        my @lines = <$fh>;
        close $fh;
        foreach my $line (@lines) {
            chomp $line;
            if ( $line =~ /^\w/msx ) {
                my ( $kit, $value ) = split( /\s*=\s*/msx, $line );
                chomp $kit;
                chomp $value;

                # if the kit has been named in the meta data structure
                # we will plug that value into it
                if ( exists $hash{$kit} ) {
                    $hash{$kit} = $value;
                }
            }
        }
    }
    else {
        push_error("Cannot open file $ego_conf: $ERRNO");
        return;
    }

    # now let's finish filling out our hash with default settings
    # anywhere it is undef
    foreach my $key ( keys %hash ) {
        if ( $hash{$key} eq "undef" ) {
            $hash{$key} = $meta_data->{kit_settings}{$key}{default};
        }
    }
    return \%hash;
}

##
## fetching kernel information from /proc/sys/kernel
##
sub get_kernel_info {

    my $directory = '/proc/sys/kernel';
    my %hash;
    my @dir_contents;

    # pulling relevant info from /proc/sys/kernel
    if ( opendir( DIR, $directory ) ) {
        @dir_contents = readdir(DIR);
        closedir(DIR);

        # let's search the directory tree and find the files we want
        foreach my $file (@dir_contents) {
            next unless ( -f "$directory/$file" );    #only want files

            # could be easy to add another file here
            if (   ( $file eq 'ostype' )
                or ( $file eq 'osrelease' )
                or ( $file eq 'version' ) )
            {
                # let's open the file we found and get its contents
                if ( open( my $fh, '<:encoding(UTF-8)', "$directory/$file" ) )
                {

                 # just want the first line (there shouldn't be anything else)
                    my $row = <$fh>;
                    close $fh;
                    chomp $row;
                    $hash{$file} = $row;
                }
                else {
                    push_error("Could not open file $file: $ERRNO");
                    return;
                }
            }
        }
    }
    else {
        push_error("Could not open directory $directory: $ERRNO");
        return;
    }
    return \%hash;
}

##
## finding kernel files in boot
##
sub get_boot_dir_info {
    my %hash;
    my $boot_dir = "/boot";
    my @kernel_list;

    # pulling list of kernels in /boot
    if ( opendir( DIR, $boot_dir ) ) {
        foreach my $file ( readdir(DIR) ) {
            next unless ( -f "$boot_dir/$file" );    #only want files
            chomp $file;

            # let's grab the names of any files that start with
            # kernel, vmlinuz or bzImage
            if ( $file =~ m/^kernel|^vmlinuz|^bzImage/msx ) {
                push @kernel_list, $file;
            }
        }
    }
    else {
        push_error("Cannot open directory $boot_dir, $ERRNO");
        return \%hash;
    }
    $hash{'available kernels'} = \@kernel_list;
    closedir(DIR);
    return \%hash;
}

##
## fetching contents of /var/lib/portage/world
##
sub get_world_info {

    my @world_array;
    my %hash;
    my $world_file = '/var/lib/portage/world';
    my $parent     = ( caller 1 )[3];
    open my $fh, '<', $world_file
        or do { push_error("Unable to open dir $world_file: $ERRNO"); };
    while (<$fh>) {
        chomp;
        push @world_array, $_;
    }
    close $fh;

    # If being called from get_all_installed_pkg(), return the list of
    # packages, otherwise create the hashes
    if ( defined $parent && $parent =~ /get_all_installed_pkg/xms ) {
        return @world_array;
    }
    return \@world_array;
}

##
## getting the full list of installed packages
##
sub get_all_installed_pkg {
    my %hash;
    my @all;
    my @world;
    my $db_dir     = '/var/db/pkg';
    my $world_file = '/var/lib/portage/world';
    my $parent     = ( caller 1 )[3];

    # Get a list of the world packages
    @world = get_world_info();

    # Get a list of all the packages, skipping those half-merged
    opendir my $dh, $db_dir
        or do { push_error("Unable to open dir $db_dir: $ERRNO"); return };
    while ( my $cat = readdir $dh ) {
        if ( -d "$db_dir/$cat" && $cat !~ /^[.]{1,2}$/xms ) {
            opendir my $dh2,       "$db_dir/$cat"
                or opendir my $dh, $db_dir
                or do { push_error("Unable to open dir $cat: $ERRNO"); next };
            while ( my $pkg = readdir $dh2 ) {
                next if $pkg =~ m/ \A -MERGING- /msx;
                if ( -d "$db_dir/$cat/$pkg" && $pkg !~ /^[.]{1,2}$/xms ) {
                    push @all, "$cat/$pkg";
                }
            }
        }
    }

# If being called from get_version_info(), return the list of packages, otherwise continue
    if ( defined $parent && $parent =~ /get_version_info/xms ) {
        return @all;
    }

    # Create the miscellaneous hash. Do so using List::Util's "any" since grep
    # doesn't short-circuit after a successful match.
    for my $line (@all) {
        push @{ $hash{'pkgs'} }, $line;
    }
    $hash{'pkg-count'} = scalar @all;
    return \%hash;
}

##
## fetching versions of key softwares
##
sub get_version_info {

    my @all = get_all_installed_pkg();
    my %hash;

   # specify which ebuilds to look at; use a "version" of "undef" for a single
   # version value, and a hashref "[]" for a list of version values
    my %ebuilds = (
        portage => {
            kit     => 'sys-apps',
            version => undef,
            section => 'portage version',
        },
        ego => {
            kit     => 'app-admin',
            version => undef,
            section => 'ego version',
        },
        python => {
            kit     => 'dev-lang',
            version => [],
            section => 'python versions',
        },
        gcc => {
            kit     => 'sys-devel',
            version => [],
            section => 'gcc versions',
        },
        glibc => {
            kit     => 'sys-libs',
            version => [],
            section => 'glibc versions',
        },
    );

    # iterate through the ebuilds hash to fill out the result hash

    for my $name ( keys %ebuilds ) {
        my $ebuild = $ebuilds{$name};

        # define a pattern for getting the version number of the ebuild from
        # its directory name
        my $pat = qr{
            \Q$ebuild->{kit}/$name\E  # quoted ebuild name
            -          # hyphen
            (\d.*)     # string beginning with digit
        }msx;

        foreach my $entry (@all) {

            # skip anything that doesn't match the version pattern
            my ($version) = $entry =~ $pat or next;

            # if the hash wants an array, push the version onto it and keep
            # iterating
            if ( ref $ebuild->{version} eq 'ARRAY' ) {
                push @{ $ebuild->{version} }, $version;
            }

            # otherwise, just set the value to the version and end the loop
            else {
                $ebuild->{version} = $version;
                last;
            }
        }

        # tie in this section of the final report
        $hash{ $ebuild->{section} } = $ebuild->{version};
    }
    ### %hash
    return \%hash;
}

##
## parsing output from lspci -kmmvvv and putting it in a useable data
## structure for use elswhere
##
sub get_lspci {
    my %hash;
    if ( my $lspci_output = `lspci -kmmvvv` ) {
        my @hardware_list;
        my @hw_item_section = split( /^\n/msx, $lspci_output );

        my %item;
        for (@hw_item_section) {
            chomp;    # $hw_item;
            my @hw_item_lines = split(/\n/msx);

            for (@hw_item_lines) {
                chomp;
                s/\[\]|\{\}/[ ]/msx;
                my ( $key, $value ) = split(':\s');
                chomp $key;
                chomp $value;
                $item{$key} = $value;
            }

            foreach my $key_item ( keys %item ) {
                unless ( $key_item eq 'Slot' ) {
                    $hash{ $item{'Slot'} }{$key_item} = $item{$key_item};
                }
            }
        }
    }
    else {
        push_error("Could not retrieve output from lspci -kmmvvv: $ERRNO");
        return;
    }
    return \%hash;
}

###########################################
############ misc functions ###############

## accepts a string that is the question
## returns y or n or continues to prompt user
## until they answer correctly
sub get_y_or_n {
    my $arg = shift;

    my $answer = q( );
    while ( $answer !~ /^y(?:es)?$|^no?$|^$/ixms ) {

        # ask the question, with "yes" as the implied default
        print "$arg yes or no? [y]\n";
        $answer = readline *STDIN;
    }

    if ( $answer =~ /^y(?:es)?$|^$/ixms ) {
        return 'y';
    }
    elsif ( $answer =~ /^no?$/ixms ) {
        return 'n';
    }
}

## Accepts reportable errors, puts them
## into a hash, and prints the error to
## *STDERR
sub push_error {
    my $error_message = shift;
    my $parent        = ( caller 1 )[3];
    my $line          = ( caller 0 )[2];
    print {*STDERR} "$parent: $error_message at line $line\n";
    push @errors, "$parent: $error_message at line $line";
    return;
}

1;
