package Funtoo::Report;

### Author : Joshua S. Day (haxmeister)
### purpose : functions for retrieving data on funtoo linux

use strict;
use warnings;
use Exporter;
use JSON;
our $VERSION = '1.2';

our @EXPORT_OK = qw(user_config
                    get_cpu_info
                    get_mem_info
                    get_kernel_info
                    get_boot_dir_info
                    get_version_info
                    get_world_info
                    get_profile_info
                    get_kit_info
                    add_uuid
					version
                    get_chassis_info
                    get_all_installed_pkg);

my $config_file = '/etc/report.conf';

###
### finds the config file in /etc/report.conf and loads it's contents
### into a hash and returns it
###
sub user_config {

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
    else {
        warn "\nCould not open file the configuration file at $config_file \n";
        print "Attempting to create one... \n";
        gen_config();
        
        exit;
    }
    return %hash;
}

###
### adds a uuid to /etc/report.conf and returns it as a string
###
sub add_uuid{

    # lets just get a random identifier from the system
    open(my $fh, '<', '/proc/sys/kernel/random/uuid') or die $!;
    my $UUID = <$fh>;
    chomp $UUID;
    close $fh;
    
    # open the config file and append the UUID properly into the file
    open( $fh, '>>', $config_file ) or die $!;
    print $fh "\n# A unique identifier for this reporting machine \n";
    print $fh "UUID:$UUID\n";
    close $fh;
    
    return $UUID;
}

###
### reporting version number
###
sub version{
    return $VERSION;
}


###
### fetching active profiles
### reconst output of epro show-json command
###
sub get_profile_info {
    
    # execute 'epro show-json' and capture it's output
    my $json_from_epro = `epro show-json`;
    my %profiles;
    my %sorted;
    
    # convert the output from json to a perl data structure
    my $data = decode_json($json_from_epro);
    %profiles = %$data;
    
    # we are going to reconstruct the epro output without the extra
    # 'shortname' keys, so that it is more easily used in elasticsearch
    foreach my $item ( keys(%profiles) ){
        foreach my $final ($profiles{$item}){
            foreach my $array_item (@{$final}){
                push @{$sorted{$item}}, $array_item->{'shortname'};
            }
        }
    } 
    return \%sorted;
}

###
### fetching active kits
### resorting to parsing output of ego
###
sub get_kit_info {

    # execute 'ego kit status' and capture it's output
    my @status_info = `ego kit status`;
    my %hash;
    
    # this output needs a lot of work to get the data into a hash
    for my $line (@status_info){
        chomp $line;
        
        # lets remove leading and trailing white space from the line
        $line =~ s/^\s+|\s+$//g;
        
        # done parsing lines if we hit the NOTE line
        if ( $line =~ /NOTE/){
            return \%hash;
        }
        
        # lets dodge that line with the underlined words in it
        if ( $line =~ /^\w/msx){
            
            # split the line on whitespace and grab the first 2 values
            # which are 'kit' and 'active branch'
            my ($key, $value) = split(' ',$line);
            
            # this will also remove the terminal color encoding
            # that is present but not normally visible
            # otherwise you see  \u001b[94m and other such nonsense
            $value =~ s/^\W\[\d.m//;
            $hash{$key} = $value;
        }
    }
    return \%hash;
}

###
### fetching lines from /proc/cpuinfo
###
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
                
                # lets split each line on the colon, left is the key
                # right is the value
                my ( $key, $value ) = split /\s*:\s*/msx, $row;
                
                # now we will just look for the values we want and 
                # add them to the hash
                if    ($key eq 'model name'){
                    $hash{$key} = $value;
                }
                elsif ( $key eq 'flags' ){
                    my @cpu_flags = split / /, $value;
                    $hash{$key} = \@cpu_flags;
                }
                elsif($key eq 'cpu MHz'){
                    $hash{$key} = $value * 1;
                }
                elsif($key eq 'processor'){
                    
                    # counting lines that are labeled 'processor' which
                    # should give us a number that users expect to see
                    # including logical and physical cores
                    $proc_count = $proc_count + 1;
                }
                else {next}
            }
        }
    }
    
    else { warn "Could not open file ' $cpu_file' $!"; }
    $hash{"processors"} = $proc_count;
    return \%hash;
}

###
### fetching a few lines from /proc/meminfo
###
sub get_mem_info {

    # pulling relevent info from /proc/meminfo
    my %hash;
    my $mem_file = '/proc/meminfo';
    my @mem_file_contents;
    if ( open( my $fh, '<:encoding(UTF-8)', $mem_file ) ) {
        @mem_file_contents = <$fh>;
        close $fh;
        foreach my $row (@mem_file_contents) {
            chomp $row;
            
            if ($row) {
                
                # splitting on the colon again
                my ( $key, $value ) = split /\s*:\s*/msx, $row;
                
                # look for all these values
                if (   ( $key eq 'MemTotal' )
                    or ( $key eq 'MemFree' )
                    or ( $key eq 'MemAvailable' )
                    or ( $key eq 'SwapTotal' )
                    or ( $key eq 'SwapFree' ) ){
                    
                    # capture just digit characters in the value
                    $value =~ /(\d+)/msx;
                    
                    # simple math to force perl to type this as a number
                    $hash{$key} = $1 * 1;
                }
            }
        }
    }
    else { warn "Could not open file ' $mem_file' $!"; }
    return \%hash;
}

###
### fetching kernel information from /proc/sys/kernel
###
sub get_kernel_info {

    my $directory = '/proc/sys/kernel';
    my %hash;
    my @dir_contents;

    # pulling relevant info from /proc/sys/kernel
    opendir( DIR, $directory ) or die $!;
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
            # lets open the file we found and get it's contents
            if ( open( my $fh, '<:encoding(UTF-8)', "$directory/$file" ) ) {
                
                # just want the first line (there shouldn't be anything else)
                my $row = <$fh>;
                close $fh;
                chomp $row;
                $hash{$file} = $row;
            }
            else { warn "could not open file '$file' $!"; }
        }
    }
    return \%hash;
}    #end sub

###
### finding kernel files in boot
###
sub get_boot_dir_info {
    my %hash;
    my $boot_dir = "/boot";
    my @kernel_list;

    # pulling list of kernels in /boot
    opendir( DIR, $boot_dir ) or die "cannot access $boot_dir ", $!;
    foreach my $file ( readdir(DIR) ) {
        next unless ( -f "$boot_dir/$file" );    #only want files
        chomp $file;
        
        # lets grab the names of any files that start with 
        # kernel, vmlinuz or bzImage
        if ( $file =~ m/^kernel|^vmlinuz|^bzImage/msx ) {
            push @kernel_list, $file;
        }
    }
    $hash{'available kernels'} = \@kernel_list;
    closedir(DIR);
    return \%hash;
}    #end sub

###
### fetching contents of /var/lib/portage/world
###
sub get_world_info {

    # reading in world file
    my @world_array;
    my %hash;
    my $world_file = '/var/lib/portage/world';
    if ( open( my $fh, '<:encoding(UTF-8)', $world_file ) ) {
        while ( my $row = <$fh> ) {
            chomp $row;
            if ($row) {
                push( @world_array, $row );
            }
        }
        close $fh;
    }
    else { warn "Could not open file $world_file $!"; }

    $hash{'world file'} = \@world_array;
    return \@world_array;
}    #end sub

###
### getting the full list of installed packages
###
sub get_all_installed_pkg{
    my %hash;
    my @results = `equery list -F='\$cpv' "*"`;
    for my $line (@results){
        chomp $line;
        $line =~ s/^=//s;
        push @{$hash{'pkgs'}},$line;
    }
    $hash{'pkg-count'} = scalar @results;
    return \%hash;
}


###
### fetching versions of key softwares
###
sub get_version_info {

    my %hash;
    my %ebuild_dirs = (
        'portage' => '/var/db/pkg/sys-apps',
        'ego'     => '/var/db/pkg/app-admin',
        'python'  => '/var/db/pkg/dev-lang',
        'gcc'     => '/var/db/pkg/sys-devel',
        'glibc'   => '/var/db/pkg/sys-libs'
    );

    ## retrieving portage version
    opendir( DIR, ( $ebuild_dirs{'portage'} ) )
        or die "could not open $ebuild_dirs{'portage'} ", $!;
    my @portage_dir = readdir(DIR);
    closedir(DIR);
    foreach my $folder (@portage_dir) {
        chomp $folder;
        if ( $folder =~ /^portage/msx ) {
            $folder =~ /^portage-(.*)/msx;
            $hash{'portage version'} = $1;
        }
    }

    ## retrieving ego version
    opendir( DIR, ( $ebuild_dirs{'ego'} ) )
        or die "could not open $ebuild_dirs{'ego'} ", $!;
    my @ego_dir = readdir(DIR);
    closedir(DIR);
    foreach my $folder (@ego_dir) {
        chomp $folder;
        if ( $folder =~ /^ego/msx ) {
            $folder =~ /^ego-(.*)/msx;
            $hash{'ego version'} = $1;
        }
    }

    # retrieving python versions
    my @python_versions;
    opendir( DIR, ( $ebuild_dirs{'python'} ) )
        or die "could not open $ebuild_dirs{'python'} ", $!;
    my @python_dir = readdir(DIR);
    closedir(DIR);
    foreach my $folder (@python_dir) {
        chomp $folder;
        if ( $folder =~ /^python.[^exec]/msx ) {
            $folder =~ /^python-(.*)/msx;
            push @python_versions, $1;
            $hash{'python versions'} = \@python_versions;
        }
    }

    # retrieving gcc versions
    my @gcc_versions;
    opendir( DIR, ( $ebuild_dirs{'gcc'} ) )
        or die "could not open $ebuild_dirs{'gcc'} ", $!;
    my @gcc_dir = readdir(DIR);
    closedir(DIR);
    foreach my $folder (@gcc_dir) {
        chomp $folder;
        if ( $folder =~ /^gcc.[^config]/msx ) {
            $folder =~ /^gcc-(.*)/msx;
            push @gcc_versions, $1;
            $hash{'gcc versions'} = \@gcc_versions;
        }
    }

    # retrieving glibc versions
    my @glibc_versions;
    opendir( DIR, ( $ebuild_dirs{'gcc'} ) )
        or die "could not open $ebuild_dirs{'gcc'} ", $!;
    my @glibc_dir = readdir(DIR);
    closedir(DIR);
    foreach my $folder (@glibc_dir) {
        chomp $folder;
        if ( $folder =~ /^glibc.[^config]/msx ) {
            $folder =~ /^glibc-(.*)/msx;
            push @glibc_versions, $1;
            $hash{'glibc versions'} = \@glibc_versions;
        }
    }
    return \%hash;
}

##
## fetch information about the system chassi
##
sub get_chassis_info{
    my %hash;
    my $folder = "/sys/class/dmi/id/";
    my @id_files = ('chassis_type', 
                    'chassis_vendor', 
                    'product_name');

    my @possible_id = ( 'N/A',
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
						'Stick PC');

    for my $file (@id_files){
        if (open( my $fh, '<', "$folder$file" )){
            my $content  = <$fh>;
            chomp $content;
            if ($file eq "chassis_type"){
                $hash{$file} = $possible_id[$content];
            }
            else{
                $hash{$file} = $content;
            }
            close $fh;
        }
        else{
            $hash{$file} = $possible_id[0];
        }
    }
    return \%hash;

}


##
## Generate a configuration file in /etc/report.conf
##
sub gen_config {
    my $conf_file = "/etc/report.conf";
    open( my $fh, '>', $conf_file ) or die "Could not create file $conf_file\n$!\n";
    
    print $fh '## Configuration for selecting and deselecting which data'."\n";
    print $fh '## is reported by the funtoo anonymous reporting tool'."\n\n";

    print $fh '## All options are defaulted to report, you can change an item'."\n";
    print $fh '## by altering the "y" and "n" to indicate either yes (y) report it'."\n";
    print $fh '## or no (n) do not report it.'."\n\n\n";

    print $fh '# To report cpu info which includes clock speed, model name,'."\n";
    print $fh '# and cpu cores'."\n";
    print $fh 'cpu-info:y'."\n\n";

    print $fh '# To report memory info which includes the amount of free memory,'."\n";
    print $fh '# the amount of memory available, total amount of swap space,'."\n";
    print $fh '# and the amount of free swap space'."\n";
    print $fh 'mem-info:y'."\n\n";

    print $fh '# To report kernel info including O.S. type, release and version'."\n";
    print $fh 'kernel-info:y'."\n\n";

    print $fh '# Allows the reporter to search your /boot directory and list'."\n";
    print $fh '# any kernels it finds'."\n";
    print $fh '# (limited to kernel names that start with "kernel" or "vmlinuz")'."\n";
    print $fh 'boot-dir-info:y'."\n\n";

    print $fh '# To report versions of key softwares on your system including'."\n";
    print $fh '# portage, ego, python, gcc, and glibc'."\n";
    print $fh 'version-info:y'."\n\n";

    print $fh '# To report the contents of /var/lib/portage/world'."\n";
    print $fh 'world-info:y'."\n\n";

    print $fh '# To report profiles information'."\n";
    print $fh '# the same as epro show-json'."\n";
    print $fh 'profile-info:y'."\n\n";

    print $fh '# To report kit versions as reported by ego'."\n";
    print $fh '# extracted from ego kit show'."\n";
    print $fh 'kit-info:y'."\n\n";
    
    print $fh '# To report system chassis type and model'."\n";
    print $fh 'chassis-info:y'."\n\n";
    
    print $fh '# To report all installed packages (takes a few secs)'."\n";
    print $fh 'installed-pkgs:y'."\n";
    close $fh;
    
    
    print "\nA config file has been generated at $conf_file \n";
    print "Please review this file for errors.\n";
}

1;
