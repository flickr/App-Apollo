#
# App::Apollo::Status
#
# App::Apollo::Status has a list of valid return values a check
# can return to apollo.
#
# Copyright 2016 Yahoo INC.
# Check the LICENSE file for the COPYRIGHT/LICENSE
package App::Apollo::Status;

=head1 NAME

App::Apollo::Status - Defines the exit codes supported by Apollo and consul.

=head1 DESCRIPTION

If your Apollo scripts will be in Perl then you can use this module to easily return
the right exit code and as well to parse the environment variables that are passed
to each script.

=cut
use strict;
use warnings;
use Time::HiRes;
use Exporter 'import';
use vars qw(@EXPORT_OK @EXPORT);

@EXPORT_OK = qw(
        get_service_status
        get_snapshot_service_status
        get_percent_status
        get_total_status
        get_snapshot_percent_status
        get_snapshot_total_status
        get_since_status
        get_snapshot_since_status
        get_since_diff_status
        get_snapshot_since_diff_status
        needs_fast_healing);
# No @EXPORT please, or some methods will clash iwth others of Apollo

=head2 Exit code constants

=head3 HEALED

Equivalent to 0, used to indicate healing passed.

=head3 OK

Equivalent to 0, used to indicate a script finished with no problems.

=head3 WARN

Equivalent to 1, used to indicate a script finished in a warning state.

=head3 BAD

Equivalent to 2, used to indicate a script finished with errors.

=head3 OOR

Equivalent to 3, used to indicate a script detected the host to be out of rotation.

=head3 UNKNOWN

Equivalent to 1.

=head3 OK_HEAL_NOW

Equivalent to 100, used when a script (usually the main service) prefers healing to
be triggered immediately and keep the service in an OK/passing status.

=head3 WARN_HEAL_NOW

Similar to L<OK_HEAL_NOW> but leaves the main service in a WARN/warning status.

=head3 BAD_HEAL_NOW

Similar to L<OK_HEAL_NOW> but leaves the main service in a BAD/failing status.

=cut
use constant {
    HEALED          => 0,
    OK              => 0,
    WARN            => 1,
    BAD             => 2,
    OOR             => 3,
    UNKNOWN         => 1,
    OK_HEAL_NOW     => 100,
    WARN_HEAL_NOW   => 101,
    BAD_HEAL_NOW    => 102};


=head2 Methods

=head3 get_service_status($service)

Returns the status of a given service (based on the ENVIRONMENT variables).

Possible values: any, critical, passing or warning.

=cut
sub get_service_status {
    my ($service) = @_;

    my $service_name = $ENV{'APOLLO_SERVICE_NAME'};
    my $env_key;
    if ($service_name eq $service) {
        $env_key = 'APOLLO_SERVICE_STATUS_' . uc($service);
    } else {
        $env_key = 'APOLLO_SERVICE_STATUS_' . uc($service) . '-' . $service_name;
    }
    $env_key = uc($env_key);
    if (defined $ENV{$env_key}) {
        if ($ENV{$env_key} =~ /status=(any|critical|passing|warning)/) {
            return $1;
        }
    }
    return '';
}

=head3 get_snapshot_service_status($service)

Similar to L<get_service_status()> except that it look for the snapshot variables.

=cut
sub get_snapshot_service_status {
    my ($service) = @_;
    
    my $service_name = $ENV{'APOLLO_SERVICE_NAME'};
    my $env_key;
    if ($service_name eq $service) {
        $env_key = 'APOLLO_SNAPSHOT_SERVICE_STATUS_' . uc($service);
    } else {
        $env_key = 'APOLLO_SNAPSHOT_SERVICE_STATUS_' . uc($service) . '-' . $service_name;
    }
    $env_key = uc($env_key);
    if (defined $ENV{$env_key}) {
        if ($ENV{$env_key} =~ /status=(any|critical|passing|warning)/) {
            return $1;
        }
    }

}

=head3 get_percent_status($service, $status)

Returns the % of hosts that are under a given service and under a given status.

Will return 0 if none are.

=cut
sub get_percent_status {
    my ($service, $status) = @_;

    my $service_name = $ENV{'APOLLO_SERVICE_NAME'};
    my $env_key;
    if ($service_name eq $service) {
        $env_key = 'APOLLO_SERVICE_STATUS_' . uc($service);
    } else {
        $env_key = 'APOLLO_SERVICE_STATUS_' . uc($service) . '-' . $service_name;
    }
    $env_key = uc($env_key);
    if (defined $ENV{$env_key}) {
        my $key = $status . '_pct';
        if ($ENV{$env_key} =~ /$key=(\d+)/) {
            return $1;
        }
    }
    return 0;
}

=head3 get_total_status($service, $status)

Returns the total number of hosts (not %) under a given service/status.

=cut
sub get_total_status {
    my ($service, $status) = @_;
    
    my $service_name = $ENV{'APOLLO_SERVICE_NAME'};
    my $env_key;
    if ($service_name eq $service) {
        $env_key = 'APOLLO_SERVICE_STATUS_' . uc($service);
    } else {
        $env_key = 'APOLLO_SERVICE_STATUS_' . uc($service) . '-' . $service_name;
    }
    $env_key = uc($env_key);
    if (defined $ENV{$env_key}) {
        my $key = $status;
        if ($ENV{$env_key} =~ /$key=(\d+)/) {
            return $1;
        }
    }
}

=head3 get_snapshot_percent_status($service, $status)

Similar to L<get_percent_status()>, except that it look for the snapshot.

=cut
sub get_snapshot_percent_status {
    my ($service, $status) = @_;

    my $service_name = $ENV{'APOLLO_SERVICE_NAME'};
    my $env_key;
    if ($service_name eq $service) {
        $env_key = 'APOLLO_SNAPSHOT_SERVICE_STATUS_' . uc($service);
    } else {
        $env_key = 'APOLLO_SNAPSHOT_SERVICE_STATUS_' . uc($service) . '-' . $service_name;
    }
    $env_key = uc($env_key);
    if (defined $ENV{$env_key}) {
        my $key = $status . '_pct';
        if ($ENV{$env_key} =~ /$key=(\d+)/) {
            return $1;
        }
    }
    return 0;
}

=head3 get_snapshot_total_status($service, $status)

Returns the total number of hosts (not %) under a given service/status, only for snapshot.

=cut
sub get_snapshot_total_status {
    my ($service, $status) = @_;
    
    my $service_name = $ENV{'APOLLO_SERVICE_NAME'};
    my $env_key;
    if ($service_name eq $service) {
        $env_key = 'APOLLO_SNAPSHOT_SERVICE_STATUS_' . uc($service);
    } else {
        $env_key = 'APOLLO_SNAPSHOT_SERVICE_STATUS_' . uc($service) . '-' . $service_name;
    }
    $env_key = uc($env_key);
    if (defined $ENV{$env_key}) {
        my $key = $status;
        if ($ENV{$env_key} =~ /$key=(\d+)/) {
            return $1;
        }
    }
    return 0;
}

=head3 get_since_status($service)

Returns the timestamp of since when the service has been on the current status.

=cut
sub get_since_status {
    my ($service) = @_;

    my $service_name = $ENV{'APOLLO_SERVICE_NAME'};
    my $env_key;
    if ($service_name eq $service) {
        $env_key = 'APOLLO_SERVICE_STATUS_' . uc($service);
    } else {
        $env_key = 'APOLLO_SERVICE_STATUS_' . uc($service) . '-' . $service_name;
    }
    $env_key = uc($env_key);
    if (defined $ENV{$env_key}) {
        if ($ENV{$env_key} =~ /since=([0-9]*\.?[0-9]+)/) {
            return $1;
        }
    }
    return 0;
}

=head3 get_snapshot_since_status($service)

Similar to L<get_since_status()> except that it looks for the snapshot.

=cut
sub get_snapshot_since_status {
    my ($service) = @_;

    my $service_name = $ENV{'APOLLO_SERVICE_NAME'};
    my $env_key;
    if ($service_name eq $service) {
        $env_key = 'APOLLO_SNAPSHOT_SERVICE_STATUS_' . uc($service);
    } else {
        $env_key = 'APOLLO_SNAPSHOT_SERVICE_STATUS_' . uc($service) . '-' . $service_name;
    }
    $env_key = uc($env_key);
    if (defined $ENV{$env_key}) {
        if ($ENV{$env_key} =~ /since=([0-9]*\.?[0-9]+)/) {
            return $1;
        }
    }
    return 0;
}

=head3 get_since_diff_status($service)

Similar to L<get_since_status()>. Except that gets the diff of that timestamp VS current time

=cut
sub get_since_diff_status {
    my ($service) = @_;

    my $since = get_since_status($service);
    my $diff  = Time::HiRes::time - $since;
    return $diff;
}

=head3 get_snapshot_since_diff_status($service)

Similar to L<get_since_diff_status()>, except that it looks for the snapshot.

=cut
sub get_snapshot_since_diff_status {
    my ($service) = @_;

    my $since = get_snapshot_since_status($service);
    my $diff  = Time::HiRes::time - $since;
    return $diff;
}

=head3 needs_fast_healing()

Returns true if the host requires fast healing (such as the environment variable
APOLLO_FAST_HEALING is present).

=cut
sub needs_fast_healing {
    if (defined $ENV{'APOLLO_FAST_HEALING'}) {
        return 1;
    }
    return 0;
}


1;

