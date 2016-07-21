#
# App::Apollo
#
# Copyright 2016 Yahoo INC.
# Check the LICENSE file for the COPYRIGHT/LICENSE
package App::Apollo;

=head1 NAME

App::Apollo - Self-healing engine

=head1 ABSTRACT

App::Apollo provides a mechanism to self heal hosts by using consul.

=head1 DESCRIPTION

Apollo is a tool originally written at Flickr that will I<auto-heal> hosts
by taking them out of rotation (cooling them) and then fixing them before
putting them back. It reduces the response time (TTR) when a host or cluster
goes wrong Flickr tool and needs attention from a NOC/SRE leaving the SREs
with more time to focus on important things.

Apollo uses L<consul|https://www.consul.io> for knowing the state of hosts
in a given cluster (for example a WWW cluster). Once it knows the state of
hosts it will decide to:

=over 4

=item *

Take the host OOR (based on a set of checks/scripts that you can define).

=item *

Heal the host (eg, restart a process).

=item *

Put the host back in rotation.

=item *

Maybe don't do anything if there are too many hosts in a bad state.

=item *

.. or if the cluster is in a broken state and you are able to identify
it by a script then it can repair the entire cluster.

=back

For taking hosts OOR, Apollo will create a text file that you can tie to your HTTP
healthcheck or (by default) by failing the host via consul so you can use consul-template
to generate your configuration files when a host or cluster go bad.

=cut
use strict;
use warnings;
use Moose;
use AnyEvent;
use IPC::Cmd qw(run_forked);
use LWP::UserAgent;
use URI;
use Net::DNS;
use MIME::Base64;
use JSON;
use YAML::Syck;
use Time::HiRes qw(time usleep);
use File::Basename;
use File::Slurp;
use List::Compare;
use Data::Dumper;
# Apollo libraries
use App::Apollo::Status;
use App::Apollo::Tools::Logger;

# Our version
our $VERSION = '1.01';

=head1 CODE

Now, time to read the code (documentation)!.

=head2 Attributes

Most of the attributes can defined via the L<config_file> file.

Read the attribute documentation to find how does Apollo gets the values.

=head3 config_file

Apollo's configuration file.

Default: I</etc/apollo/config.yaml>

=cut
has 'config_file' => (
    is  => 'rw',
    isa => 'Str',
    default => '/etc/apollo/config.yaml');

=head3 track_directory

Directory of where we will keep track of previous runs (handy for when
a check requires retries).

Default: I</var/apollo/checks>.

Config file that the value can be provided: L<config_file>.

=cut
has 'track_directory' => (
    is  => 'rw',
    isa => 'Str',
    default => '/var/apollo/checks');

=head3 report_file

File of where to write a report. This is super handy if you want to tie
your /etc/issue or /etc/motd to a report so that when users SSH, the first
thing that they will see is a report of it.

Please note that to do this you will need to write a shell script that shows
(cats) the output of this report file.

Default: I</var/apollo/report.txt>

Config file that the value can be provided: L<config_file>.

=cut
has 'report_file' => (
    is  => 'rw',
    isa => 'Str',
    default => '/var/apollo/report.txt');

=head3 pid_file

Where to keep the PID file of Apollo.

Default: I</var/apollo/run/apollo.pid>.

=cut
has 'pid_file' => (
    is  => 'rw',
    isa => 'Str',
    default => '/var/apollo/run/apollo.pid');

=head3 consul_endpoint

Consul endpoint (aka how to query the consul agent via HTTP).

Default: I<http://localhost:8500>

Config file that the value can be provided: L<config_file>.

=cut
has 'consul_endpoint' => (
    is  => 'rw',
    isa => 'Str',
    default => 'http://localhost:8500');

=head3 service_name

Cluster/service/hostgroup name (eg, www).

If this attribute is not found (or set) then Apollo will fail to
start.

Config file that the value can be provided: L<config_file>.

=cut
has 'service_name' => (
    is  => 'rw',
    isa => 'Str');

=head3 service_cmd

Service healthcheck command. It is optional, otherwise the host will always
appear as part of the service (unless consul/host dies..).

A common use of this command is to check if the host is really OOR, check
additional services, HTTP errors, etc and then take a decision if the host should
go OOR.

Config file that the value can be provided: L<config_file>.

=cut
has 'service_cmd' => (
    is  => 'rw',
    isa => 'Str');

=head3 service_frequency

How often should L<service_cmd|service_cmd> be executed? It defaults to 30 (seconds).

Default: 30 (seconds)

Config file that the value can be provided: L<config_file>.

=cut
has 'service_frequency' => (
    is  => 'rw',
    isa => 'Int',
    default => 30);

=head3 keep_critical_secs

Once the main service goes into critical state (BAD) then we will keep the service
with that state for N seconds.

Default: 90 (seconds)

Config file that the value can be provided: L<config_file>.

=cut
has 'keep_critical_secs' => (
    is  => 'rw',
    isa => 'Int',
    default => 90);

=head3 keep_warning_secs

Once the main service goes into warning state (WARN) then we will keep the service
with that state for N seconds (you will rarely need this).

Default: 0 (seconds)

Config file that the value can be provided: L<config_file>.

=cut
has 'keep_warning_secs' => (
    is  => 'rw',
    isa => 'Int',
    default => 0);

=head3 critical_snapshot

Takes a snapshot of all environment variables that were passed to the main service
check before it turned into critical/BAD.

You will rarely need to access this, it is more internal to L<App::Apollo>.

=cut
has 'critical_snapshot' => (
    is  => 'ro',
    isa => 'HashRef');

=head3 warning_snapshot

Takes a snapshot of all environment variabbles that were passed to the main service
check before it turned into warning/WARN.

You will rarely need to access this, it is more internal to L<App::Apollo>.

=cut
has 'warning_snapshot' => (
    is  => 'ro',
    isa => 'HashRef');

=head3 tags_list

A CSV of tags to use for this host. This is optional.

Config file that the value can be provided: L<config_file>.

=cut
has 'tags_list' => (
    is  => 'rw',
    isa => 'Str');

=head3 tags

An array of tags (built from tags_list).

=cut
has 'tags' => (
    is  => 'ro',
    isa => 'ArrayRef');

=head3 threshold_down

Threshold of servers that can be DOWN. Can be a number or a percent (use %)
for this.

If the value is not set then it will be taking as many hosts OOR as it wants.

Config file that the value can be provided: L<config_file>.

=cut
has 'threshold_down' => (
    is  => 'rw',
    isa => 'Str');

=head3 colo

Colo (aka datacenter) ID. Should be the same you use on your consul agent
configuration.

Config file that the value can be provided: L<config_file>.

If the colo is not set then Apollo will fail to start.

=cut
has 'colo' => (
    is => 'rw',
    isa => 'Str');

=head3 hostname

Shorted version (non-FQDN) of hostname (`hostname`).

Config file that the value can be provided: L<config_file>.

If the hostname is not set then Apollo will fail to start.

=cut
has 'hostname' => (
    is => 'ro',
    isa => 'Str');

=head3 port

Optional. The TCP port hosting the main application on this host.

=cut
has 'port' => (
    is => 'rw',
    isa => 'Int');

=head3 heal_on_status

Will only run C<heal_cmd> when the status of the current host is in a given state.

Defaults to any.

=cut
has 'heal_on_status' => (
    is  => 'rw',
    isa => 'Str',
    default => 'any');

=head3 heal_cmd

This is the *healing* command that will check the host itself and can later tell
Apollo to take the host OOR or not. The healing command *can* take the host OOR
but it is suggested that Apollo does it. The exit codes can be:

=over 4

=item *

0: Host is fine, do not take the host OOR.

=item *

1: Host is bad, please take it OOR.

=item *

3: Host is bad but do NOT take it OOR.

=back

Please note that Apollo will verify that the command exist before executing it. Also
the command wont be executed if the the thresholds are set.

=cut
has 'heal_cmd' => (
    is  => 'rw',
    isa => 'Str',
    default => '/bin/true');

=head3 heal_frequency

How often should we run the heal command?

=cut
has 'heal_frequency' => (
    is  => 'rw',
    isa => 'Int',
    default => 30);

=head3 heal_dryrun

If set to false then the heal command will actually be executed.

Defaults to true (dryrun, aka don't run it).

=cut
has 'heal_dryrun' => (
    is  => 'rw',
    isa => 'Bool',
    default => 1);

=head3 allow_full_outage

We usually don't let a service go out (full outage), however on specific cases
we might want to allow this. Like for example if we only have one single host.

Config file that the value can be provided: L<config_file>.

=cut
has 'allow_full_outage' => (
    is => 'rw',
    isa => 'Bool',
    default => 0);

=head3 penalty

Each TTL will have an additional penalty. This is to give enough room for things to
fail or deal with clock issues.

=cut
has 'penalty' => (
    is  => 'ro',
    isa => 'Int',
    default => 90);

=head3 debug

Turn on/off debug information.

=cut
has 'debug' => (
    is  =>  'rw',
    isa => 'Bool',
    default => 0);

=head2 Methods

=head3 build_consul_service_config()

Generates and returns the consul service config.

=cut
sub build_consul_service_config {
    my ($self) = @_;

    my $service_def = {
        'name'      => $self->{'service_name'}};
    # Do we have a port?
    $service_def->{'port'} = int($self->{'port'}) if $self->{'port'};
    # Do we have a specific healthcheck?
    if ($self->{'service_cmd'}) {
        # We will tell consul to wait for us with service_frequency + a penalty
        # so we can cover any tiny slow running script
        my $ttl = $self->{'service_frequency'} + $self->{'penalty'};
        $service_def->{'check'} = {
            'id'        => $self->{'service_name'} . '-check',
            'script'    => $self->{'service_cmd'},
            'real_ttl'  => $self->{'service_frequency'},
            'ttl'       => $ttl . 's'};
    }
    if ($self->{'tags'}) {
        $service_def->{'tags'} = $self->{'tags'};
    }
    $service_def = {
        'service' => $service_def};
    return encode_json($service_def);
}

=head3 build_consul_extra_service_config()

Returns an array for each extra service we want to use.

=cut
sub build_consul_extra_service_config {
    my ($self) = @_;

    my @services;
    # Any additional ones?
    if ($self->{'extra_service'}) {
        foreach my $es (keys %{$self->{'extra_service'}}) {
            # Skip if the extra service has the same name as the default one
            next if ($es eq $self->{'service_name'});
            # We will tell consul to wait for us with service_frequency + a penalty
            # so we can cover any tiny slow running script
            my $ttl = $self->{'service_frequency'} + $self->{'penalty'};
            my $service_def = {
                    'service'   => {
                        'name'  => $es . '-' . $self->{'service_name'},
                        'check' => {
                            'id'        => $es,
                            'script'    => $self->{'extra_service'}->{$es}->{'healthcheck'},
                            'real_ttl'  => $self->{'extra_service'}->{$es}->{'frequency'},
                            'retries'  	=> $self->{'extra_service'}->{$es}->{'retries'} || 1,
                            'ttl'       => $ttl . 's',
                         }
                     }
            };
            push(@services, {
                    'name'  => $es,
                    'def'   => $service_def,
                    'json'  => encode_json($service_def)});
        }
    }
    return @services;
}

=head3 run_timers()

Starts executing the health-checks by setting up timers for each one of them.

The timers are set this way:

=over 4

=item *

The checks will run at the frequency that they are set (60 seconds by default) but
there will be a random wait between 10 and 190ms. This wait is used so that the checks
run I<around> the same time but not precisely at the I<same> time, that way if you are
in the middle of an outage not all the services will fail at once.

=item *

The healing process (check L<heal_cmd>) will be set to run (or check if anything needs
to be healed) at the frequency it was set (L<heal_frequency>). The healing process has
no random wait.

=back

=cut
sub run {
    my ($self) = @_;

    $self->check_pid();
    
    # Clean the track directory
    if (-d $self->{'track_directory'}) {
        system("rm -rf $self->{'track_directory'}/*");
    }

    log_info("Starting apollo...");
    # Get a list of all the services we need
    my @all_services     = $self->get_all_services();

    my @timers = ();
    foreach my $service (@all_services) {
        # Give 10 seconds to create all the timers
        my $retries = $service->{'retries'} || 1;
        push(@timers, AnyEvent->timer(
                    after       => 10,
                    interval    => $service->{'frequency'},
                    cb          => sub {
                    if ($self->{'running_checks'}->{$service->{'id'}}) {
                        log_error("[service:$service->{'id'}] is already running, not running twice");
                        return;
                    }
                    my $now = Time::HiRes::time;
                    # Show the diff time, mostly for debugging
                    if ($self->{'previous_run'}->{$service->{'id'}}) {
                        my $diff = $now-$self->{'previous_run'}->{$service->{'id'}};
                        $diff = sprintf('%.*fms', 3, $diff);
                        log_info("[service:$service->{'id'}] Last time it ran was $diff secs ago");
                    }
                    $self->{'running_checks'}->{$service->{'id'}} = 1;
                    # Ok, sleep a little bit
                    usleep($service->{'mssleep'});
                    $self->call_script($service->{'id'}, $retries, $service->{'script'});
                    $self->{'running_checks'}->{$service->{'id'}} = undef;
                    $self->{'previous_run'}->{$service->{'id'}} = Time::HiRes::time;
                    }));
    }

    # And the healing one..
    push(@timers, AnyEvent->timer(
                after       => 0.1, # First time, run this after 0.1 seconds that the application started
                interval    => $self->{'heal_frequency'},
                cb          => sub {
                    if ($self->{'running_healing'}) {
                        log_error("[healing] Already trying to heal, not healing twice");
                        return;
                    }
                    $self->{'running_healing'} = 1;
                    my $rc = $self->heal_host();
                    $self->generate_heal_report($rc, \@all_services);
                    $self->{'running_healing'} = undef;
                }));
    # Start the main event loop
    my $cv = AnyEvent->condvar;
    $cv->recv;
}

=head3 can_change_status($service, $new_status)

Checks if the status of a service (usually the main service, L<service_name>) can
change status, for example, if it can go from OK to BAD.

Returns an array:

=over 4

=item *

(true, undef): If status can be changed.

=item *

(false, $new_status): If status can't be changed, but return the status to use then.

=back

This is done by checking if the status (C<$status>) is changing from what we have at
this time on consul. If the status is changing then we verify if we should actually
change it, the way we decide this is by checking the L<keep_critical_secs> and
L<keep_warning_secs>:

=over 4

=item *

If C<$new_status> is L<App::Apollo::Status::OOR> (aka you know by hand that the
host should be out of rotation), then it returns (2, undef).

=item *

If the current status was not updated by apollo (aka it was taken out of rotation
via normal ways or another method unknown to Apollo), then it returns (2, undef).

=item *

If the new status is L<App::Apollo::Status::BAD> but the existing status is the
same then there is no reason to change (we return (2, undef)). The reason of this
is because when Apollo marks a host as L<App::Apollo::Status::BAD> it also sets
a timestamp of when it went bad (read L<get_node_services>), if you ended up
changing the status with the same value and with different timestamp then
you will end up losing tracking of since when the status went BAD. If a change is
allowed then (1, undef) is returned.

=item *

Similar as above but now assuming you are setting the value to L<App::Apollo::Status::WARN>.
If the status is NOT changing then (2, undef) is returned, otherwise (1, undef) is returned.

=item *

Finally, if by any change the status is really changing (current status is different
than the new status) then Apollo will check if the status is changing from
L<App::Apollo::Status::BAD>/L<App::Apollo::Status::WARN> to L<App::Apollo::Status::OK>
and if that is the case then it will check the timestamp of when the
L<App::Apollo::Status::BAD>/L<App::Apollo::Status::WARN> status was set:

=over 6

=item *

If L<keep_critical_secs> is set and the status (L<App::Apollo::Status::BAD>) has been
longer than this time then we will allow the status to be changed by returning (1, undef),
however if the host has been in that state shorter than L<keep_critical_secs> then the
change of status will not be allowed and hence we will return (1, $overwritten_status) where
C<$overwritten_status> is the status that we should use.

=item *

Similar case applies when the new status will be L<App::Apollo::Status::WARN> and
L<keep_warning_secs> is set.

=back

=back

=cut
sub can_change_status {
    my ($self, $service, $new_status) = @_;

    # Ok, get current status
    my ($current_status,
       $current_status_code,
       $current_by_apollo,
       $current_since) = $self->get_service_status($service);
    
    # It is an OOR status, we should be Ok with it.
    if ($new_status == App::Apollo::Status::OOR) {
        return (2, undef);
    }

    # If the previous status was NOT set by apollo then we are also ok with new
    # status
    unless ($current_by_apollo) {
        return (2, undef);
    }

    # Ok, is the status from warn/bad to OK? We accept things goign to a fail
    # state.
    if ($new_status == App::Apollo::Status::BAD) {
        if ($new_status == $current_status_code) {
            return (2, undef);
        } else {
            return (1, undef);
        }
    }
    if ($new_status == App::Apollo::Status::WARN) {
        if ($new_status == $current_status_code) {
            return (2, undef);
        } else {
            return (1, undef);
        }
    }

    # Ok, so this is moving from BAD to OK?
    if ($new_status == App::Apollo::Status::OK and
        $current_status_code == App::Apollo::Status::BAD) {
        # We suppose to even care?
        unless ($self->{'keep_critical_secs'}) {
            return (1, undef);
        }
        # Are we supposed to wait a few seconds before we switch to OK?
        if ($current_since) {
            my $diff = int(time)-int($current_since);
            # Ok, we been on this status for a while, we should be OK with the
            # change
            if ($diff > $self->{'keep_critical_secs'}) {
                return (1, undef);
            } else {
                # Ok, we should keep with this status
                log_info("[service:$service] Keeping the old status (BAD) rather than " .
                        "changing to OK because it needs more time to stay on that status (BAD). It needs " .
                        "$self->{'keep_critical_secs'} seconds in total and only passed $diff seconds");
                return (0, $current_status_code);
            }
        }
        # Bah, allow change
        return (1, undef);
    }
    
    # Ok, then maybe we ar emoving from WARN to OK?
    if ($new_status == App::Apollo::Status::OK and
        $current_status_code == App::Apollo::Status::WARN) {
        # We suppose to even care?
        unless ($self->{'keep_warning_secs'}) {
            return (1, undef);
        }
        # Are we supposed to wait a few seconds before we switch to OK?
        if ($current_since) {
            my $diff = int(time)-int($current_since);
            # Ok, we been on this status for a while, we should be OK with the
            # change
            if ($diff > $self->{'keep_warning_secs'}) {
                return (1, undef);
            } else {
                # Ok, we should keep with this status
                log_info("[service:$service] is keeping the old status (WARN) rather than " .
                        "changing to OK because it needs more time to stay on that status (WARN). It needs " .
                        "$self->{'keep_warning_secs'} seconds in total and only passed $diff seconds");
                return (0, $current_status_code);
            }
        }
        # Bah, allow change
        return (1, undef);
    }
    # Bah, allow change
    return (1, undef);
}

=head3 call_script($id, $retries, $script_path)

Calls (executes) the given script (C<$script_path>) via L<IPC::Cmd> C<run_forked()> and
checks for the exit code.

The check ID that was registered in consul is passed as first parameter (C<$id>).

Additionally, each script can I<fail> multiple times before turning it to be a real
failure. Because of this we keep a track of how many consecutive failures a script had.
By default all scripts can only fail once.

The scripts must return exit codes:

=over 4

=item *

L<App::Apollo::Status::OK>: When the script identifies a check of status should PASS.

=item *

L<App::Apollo::Status::WARN>: When the script identifies a check of status should be WARN.

=item *

L<App::Apollo::Status::BAD>: When the script identifies a check of status should be BAD.

=item *

L<App::Apollo::Status::OOR>: When your script finds that the host should be out of rotation.

=item *

L<App::Apollo::Status::OK_HEAL_NOW>: When the script identifies a check of status should PASS
but somehow it identifies a potential bug/issue and prefers to quickly trigger a healing rather
than waiting for the script to fail.

=item *

L<App::Apollo::Status::BAD_HEAL_NOW>: When the script identifies a check of status is BAD but
rather than waiting for more checks to fail (or more time to pass) it prefers to quickly trigger
a healing.

=item *

L<App::Apollo::Status::WARN_HEAL_NOW>: When the script identifies a check of status is in WARNING
but i tis considered safer to just trigger a healing once the script finishes.

=back

If for some reason the exit code is different than any of the above exit codes then the check is
considered bad (L<App::Apollo::Status::BAD>.

=cut
sub call_script {
    my ($self, $check, $retries, $script_path) = @_;

    my $return = $self->run_cmd($script_path, $check);
    my $url = "/v1/agent/check/fail/service:$check";
    my @tracking = ();
    my $is_failed = 0;
    my $final_status = '';
    my $final_status_code;
    my $by_apollo = 1;
    my @status_decisions = ();
    my $fast_healing = 0;
    if (defined $return) {
        # Wait, the user can be giving us a "service is OK but heal now"
        # "service is bad but heal now", those exit code happen when we
        # know the status of the cluster is very bad and want to go quickly and
        # heal it but tell apollo that we are OK. Handy for cases when we know 100% of
        # hosts are in bad shape but taking a % of them would be bad so we just go ahead
        # and heal
        if ($return == App::Apollo::Status::OK_HEAL_NOW) {
            $return = App::Apollo::Status::OK;
            $fast_healing = 1;
            log_info("[service:$check] Fast healing: Was OK but healing now");
        } elsif ($return == App::Apollo::Status::WARN_HEAL_NOW) {
            $return = App::Apollo::Status::WARN;
            $fast_healing = 1;
            log_info("[service:$check] Fast healing: Was WARN but healing now");
        } elsif ($return == App::Apollo::Status::BAD_HEAL_NOW) {
            $return = App::Apollo::Status::BAD;
            $fast_healing = 1;
            log_info("[service:$check] Fast healing: Was BAD but healing now");
        }
        push(@status_decisions, $return);
        # What check was this, and are we suppose to take it OOR?
        if ($check eq $self->{'service_name'}) {
            my ($can_change, $new_status) = $self->can_change_status(
                    $self->{'service_name'}, $return);
            # Following can_change_status codes:
            #  - 0  => Status will change but is a rollback.
            #  - 1  => Status will change and is not a rollback
            #  - 2  => Status will not change and is not a rollack or we don't know
            if ($can_change == 0) {
                log_info("[service:$check] Keeping the previous status");
                $return = $new_status;
            }
            if ($return != App::Apollo::Status::OOR &&
                $return != App::Apollo::Status::OK) {
                # Get environment variables again and take a snapshot of them.
                if ($self->can_host_go_down()) {
                    $self->take_env_snapshot() if ($can_change == 1);
                } else {
                    log_info("[service:$check] Script failed and we have too many failed nodes.. holding off");
                    log_info("[service:$check] Marking the check as OK for now even if it failed");
                    $return = App::Apollo::Status::OK;
                    push(@status_decisions, $return);
                }
            }
        }

        if ($return == App::Apollo::Status::BAD) {
            $url = "/v1/agent/check/fail/service:$check";
            @tracking = $self->track_check($check, $return);
            $is_failed = 1;
            $final_status = 'fail';
            $final_status_code = App::Apollo::Status::BAD;
        } elsif ($return == App::Apollo::Status::OOR) {
            # Apollo can end up taking the node out of service/rotation if
            # it was a task given by the user (such as a ystatus stop vip)
            $url = "/v1/agent/check/fail/service:$check";
            $is_failed = 1;
            $final_status = 'fail';
            $by_apollo = 0;
            $final_status_code = App::Apollo::Status::BAD;
        } elsif ($return == App::Apollo::Status::WARN) {
            $url = "/v1/agent/check/warn/service:$check";
            @tracking = $self->track_check($check, $return);
            $final_status = 'warn';
            $final_status_code = App::Apollo::Status::WARN;
        } elsif ($return == App::Apollo::Status::OK) {
            $url = "/v1/agent/check/pass/service:$check";
            @tracking = $self->track_check($check, $return);
            $final_status = 'pass';
            $final_status_code = App::Apollo::Status::OK;
        } else {
            $url = "/v1/agent/check/fail/service:$check";
            @tracking = $self->track_check($check, App::Apollo::Status::BAD);
            $is_failed = 1;
            $final_status = 'fail';
            $final_status_code = App::Apollo::Status::BAD;
        }
    }
    # Hold a second.. we want to track the retries? aka how many retries we are
    # giving to this script/check to fail before we turn the check as bad
    if ($is_failed and $by_apollo) {
        if ($retries > 1) {
            # Ok.. so we should check how many failures we have in here
            my $total_consecutive_fails = 0;
            foreach my $t (@tracking) {
                last if ($t->{'code'} != App::Apollo::Status::BAD);
                $total_consecutive_fails++;
            }
            # So, we still have room for more failures? :D
            if ($total_consecutive_fails >= $retries) { # No .. :(
                # Ok, this is really bad. but we already knew about it!
                log_info("[service:$check] Passed the number of retries it had to fail (" .
                        "$total_consecutive_fails >= $retries)");
            } else {
                # Ok, then.. tell consul that this is a warning, but track it as a
                # BAD (which we already did via track_check)
                $url = "/v1/agent/check/warn/service:$check";
                log_info("[service:$check] Still has more room/retries to fail (retries are $retries), " .
                        "only failing for last $total_consecutive_fails runs. Marking it as " .
                        "a WARN");
                $is_failed = 0;
                $final_status = 'warn';
                push(@status_decisions, App::Apollo::Status::WARN);
                $final_status_code = App::Apollo::Status::WARN;
            }
        }
    }

    # Ok, build the decision *legend*
    my $decision_legend = '';
    foreach my $status_decision (@status_decisions) {
        if ($status_decision == App::Apollo::Status::OK) {
            $decision_legend .= 'OK -> ';
        } elsif ($status_decision == App::Apollo::Status::BAD) {
            $decision_legend .= 'BAD -> ';
        } elsif ($status_decision == App::Apollo::Status::WARN) {
            $decision_legend .= 'WARN -> ';
        } elsif ($status_decision == App::Apollo::Status::OOR) {
            $decision_legend .= 'BAD -> ';
        }
    }
    $decision_legend =~ s/ -> $//g;

    # Check the current status to log if we are changing it
    my ($current_status,
	$current_status_code,
	$current_by_apollo,
	$current_since) = $self->get_service_status($check);
    my $status_change_str = 'set';
    if (defined $current_status_code) {
        $status_change_str = 'changing' if ($current_status_code != $final_status_code);
        if ($status_change_str eq 'changing') {
            if ($current_status eq 'passing') {
                $status_change_str .= ' (FROM PASS)';
            } elsif ($current_status eq 'critical') {
                $status_change_str .= ' (FROM FAIL)';
            } elsif ($current_status eq 'warning') {
                $status_change_str.= ' (FROM WARN)';
            }
        }
    }

    my $note = '';
    $note .= '[by:apollo] ' if $by_apollo;
    # Waaaaaait one second. Should we change the time?, actually, should we even report the change?
    if ($status_change_str =~ 'changing') {
        $note .= 'Last change was on ' . time;
    } else {
        if ($current_since) {
            $note .= 'Last change was on ' . $current_since;
        } else {
            $note .= 'Last change was on ' . time;
        }
    }
    
    if ($check eq $self->{'service_name'}) {
        # Get a list of all services in critical state
        my @node_services = $self->get_node_services();
        my $critical_csv  = '';
        if (@node_services) {
            foreach my $node_service (@node_services) {
                next unless $node_service->{'name'};
                next unless ($node_service->{'status'} eq 'critical');
                $critical_csv .= $node_service->{'name'} . ',';
            }
        }
        if ($critical_csv and $is_failed) {
            $critical_csv =~ s/,$//g;
            $critical_csv = '(critical services: ' . $critical_csv . ')';
        } else {
            $critical_csv = '';
        }

        # Ok, create a flag file that shows the host is BAD
        if ($is_failed) {
            # Only create if file does not exist
            write_file($self->{'bad_file'}, time) unless (-f $self->{'bad_file'});
        } else {
            # Ok, not failed, we should nuke the file
            unlink($self->{'bad_file'}) if (-f $self->{'bad_file'});
        }

        log_info("[service:$check] Main check $check is $status_change_str to " . uc($final_status) .
                " (DECISION $decision_legend) - $critical_csv $note");
    } else {
        log_info("[service:$check] Sub check $check is $status_change_str to " . uc($final_status) .
                " (DECISION $decision_legend) - $note");
    }

    my $uri = URI->new($self->{'consul_endpoint'} . $url);
    $uri->query_form(
                note => $note);

    my $response = $self->{'ua'}->get($uri);
    if ($response->is_success) {
        log_debug("[service:$check] Called $url and got: " . $response->status_line);
    } else {
        log_error("[service:$check] Called $url and seems I failed with: " . $response->decoded_content);
    }
    # Should we heal now?
    $self->heal_host(1) if $fast_healing;
}

=head3 track_check($check, $return_code)

Adds the given check (C<$check>) with the return code (C<$return_code>) to a
text file so later on we can know how many retries are left.

It only keeps tracking of the last 10 runs and the tracking is stored in
L<track_directory> under a text file with the same name of the check.

It returns an array with the new tracking. Each item of the array is a hash
with two keys: timestamp and code.

=cut
sub track_check {
    my ($self, $check, $return_code) = @_;

    my $track_file = $self->{'track_directory'} . '/' . $check;
    # Max it to last 10.
    my @track = ();
    if (-f $track_file) {
        open(TRACK_H, $track_file);
        while(<TRACK_H>) {
            chomp;
            my ($timestamp, $code) = split(/:/, $_);
            push(@track, {
                    'timestamp'     => $timestamp,
                    'code'          => $code});
        }
        close(TRACK_H);
    }
    # More than 10? Remove the one at the bottom, we keep track by having
    # the most recent entry at the top, for example:
    #  - new
    #  - previous
    #  - old
    #  - old
    my $total = scalar @track;
    pop(@track) if ($total > 9);
    # Ok, add the new one
    unshift(@track, {
            'timestamp'     => time,
            'code'          => $return_code});

    # and re-store
    my $tmp_track = $track_file . '.tmp';
    open(TRACK_H, '> ' . $tmp_track);
    foreach my $t (@track) {
        print TRACK_H $t->{'timestamp'} . ':' . $t->{'code'} . "\n";
    }
    close(TRACK_H);
    log_debug("Attempting to copy $tmp_track $track_file");
    system("cp -f $tmp_track $track_file");
    unlink($tmp_track);
    
    # Ok, check the track and find when was the status updated
    return @track;
}

=head3 heal_host($fast_healing)

It executes (forks) the healing command. This command can be executed by the frequency
(aka it is time to try to heal or check if the host needs healing) or if the exit code
of a script is requiring some immediate healing.

If C<$fast_healing> is passed and is true then healing will happen regardless of the
service status.

Please note that healing would only happen if the main service (L<service_name>) has
been updated by Apollo.

Apollo will create a set of environment variables that will be set before the healing
command is executed. The environment variables provide the current status of all services
and as well a snapshot of how things were before the main service (L<service_name>) 
failed or required fast healing. Take a look at L<set_env()> to know the naming and
format of those environment variables.

It returns undef if no healing was needed (or was not possible) or the exit code of
L<heal_cmd>.

=cut
sub heal_host {
    my ($self, $fast_healing) = @_;

    # Do we even need to run?
    if ($self->{'heal_dryrun'}) {
        log_info("[healing] Healing is set to dry-run, not trying to heal");
        return;
    }
    # Ignore the first run
    unless ($self->{'already_ran'}) {
        log_info("[healing] Skipping the first run");
        $self->{'already_ran'} = 1;
        return;
    }

    log_info("[healing] Checking if we need to heal this host");
    my ($service_health_status) = $self->get_service_nodes($self->{'service_name'});
    my $record                  = $self->{'service_name'} . '.service.' . $self->{'colo'} . '.consul';

    # Ok, is the main service bad and is it bad because Apollo failed it?
    my $bad_by_apollo = 0;
    # Ok, look for the services under this host
    my ($current_status,
            $current_status_code,
            $current_by_apollo,
            $current_since) = $self->get_service_status($self->{'service_name'});
    if ($current_by_apollo) {
        log_info("[healing][service:$self->{'service_name'}] Service is $current_status and was updated by apollo actions");
        $bad_by_apollo = 1;
    } else {
        log_info("[healing][service:$self->{'service_name'}] Service is $current_status but was not updated by apollo, skipping " .
                "healing");
        return;
    }
    unless ($bad_by_apollo) {
        log_error("[healing][service:$self->{'service_name'}] Failed to find the service $self->{'service_name'} on this host");
        return;
    }

    # Ok, what is our status? Only do if we are NOT fast healing
    if ($fast_healing) {
        log_info("[healing][service:$self->{'service_name'}] Doing fast healing regardless of status (but currently $current_status)");
    } else {
        if ($self->{'heal_on_status'}) {
            if ($self->{'heal_on_status'} eq 'any') {
                log_info("[healing][service:$self->{'service_name'}] Set to do healing on ANY status (currently $current_status)");
            } else {
                if ($current_status eq $self->{'heal_on_status'}) {
                    log_info("[healing][service:$self->{'service_name'}] Status of $self->{'service_name'} is $current_status, " .
                            "proceeding with healing");
                } else {
                    log_warn("[healing][service:$self->{'service_name'}] Status of $self->{'service_name'} is $current_status, " .
                            "skipping healing because does not match heal_on_status: $self->{'heal_on_status'}");
                    return;
                }
            }
        }
    }

    # The healthcheck exists?
    my ($heal_cmd_path) = ($self->{'heal_cmd'} =~ /^(\S+)/);
    unless ($heal_cmd_path) {
        log_error("[healing] Was not able to find the path of the heal command ($self->{'heal_cmd'})");
        return;
    }
    unless (-x $heal_cmd_path) {
        log_error("[healing] The heal command does not seem to exist, looked for: $heal_cmd_path");
        return;
    }

    $self->set_env();
    # Ok, generate the snapshot env
    if ($self->{'snapshot_env'}) {
        foreach my $key (keys %{$self->{'snapshot_env'}}) {
            $ENV{$key} = $self->{'snapshot_env'}->{$key};
        }
    }
    $ENV{'APOLLO_FAST_HEALING'} = 1 if $fast_healing;

    write_file($self->{'healing_active_status_file'}, time) if $self->{'healing_active_status_file'};
    DumpFile($self->{'healing_last_heal_file'}, {
            'time'      => time,
            'fast'      => $fast_healing,
            'status'    => 'starting'}) if $self->{'healing_last_heal_file'};

    my $heal_ok   = 0;
    my $exit_code = $self->run_cmd($self->{'heal_cmd'}, 'apollo:healing');
    if ($exit_code == App::Apollo::Status::HEALED) {
        log_info("[healing] Host has been healed or healing is in progress");
        $heal_ok = 1;
    } else {
        log_info("[healing] Heal command finished, but I don't know if we healed anything");
        $heal_ok = undef;
    }
    if ($self->{'healing_active_status_file'}) {
        unlink($self->{'healing_active_status_file'}) if (-f $self->{'healing_active_status_file'});
    }
    DumpFile($self->{'healing_last_heal_file'}, {
            'time'      => time,
            'fast'      => $fast_healing,
            'status'    => $heal_ok ? 'ok' : 'failed'}) if $self->{'healing_last_heal_file'};
    return $heal_ok;
}

=head3 set_env()

Each time that Apollo executes a script, a new set of environment variable variables will be
set. These environment variables have the status of each service and as well some consul information
that might be useful with each script.

The environment variables will be:

=over 4

=item *

APOLLO_RECORD: Has the consul DNS name of the main service.

=item *

APOLLO_DATACENTER: Name of the datacenter of where the service is located

=item *

APOLLO_SERVICE_NAME: The name of the main service (L<service_name>).

=item *

APOLLO_SERVICE_STATUS_$SERVICE: Has information about the given service, for example if
your main service (L<service_name>) is I<foo> then a environment variable will be
I<APOLLO_SERVICE_STATUS_FOO>. If you have a subservice called I<bar> then another
environment variable will be I<APOLLO_SERVICE_STATUS_FOO-BAR> (yes, with a dash). The of
each of these keys will be different but an example will be:
I<status=passing,since=1464650263.53995,passing=167,passing_pct=100,any=167,any_pct=100>, where:

=over 6

=item *

B<status>: Has the status of the given service. Please note that the status is the status that
I<consul> uses.

=item *

B<since>: Has the timestamp and ms of since when the given service has been on that status.

=item *

B<passing>: Total number of hosts that are in passing status.

=item *

B<passing_pct>: Similar to passing but set as a percent.

=item *

B<any>: The total number of hosts (aka in I<any> status).

=back

Additionally you will also find I<critical>, I<critical_ct>, I<warning> and I<warning_pct>.

=back

=cut
sub set_env {
    my ($self) = @_;
    
    my $record = $self->{'service_name'} . '.service.' . $self->{'colo'} . '.consul';
    # Get node info and expand it as env variables
    my @node_services = $self->get_node_services();

    # Ok, now run the healthcheck
    # But before export some variables
    $ENV{'APOLLO_RECORD'} = $record;
    $ENV{'APOLLO_DATACENTER'} = $self->{'colo'};
    $ENV{'APOLLO_SERVICE_NAME'} = $self->{'service_name'};
    
    if (@node_services) {
        foreach my $node_service (@node_services) {
            next unless $node_service->{'name'};
            my ($service_health_status) = $self->get_service_nodes($node_service->{'name'});
            my $env_name = 'APOLLO_SERVICE_STATUS_' . uc($node_service->{'name'});
            my $env_val  = 'status=' . $node_service->{'status'} . ',' .
                'since=' . $node_service->{'since'} . ',';
            my $total = $service_health_status->{'any'}->{'total'};
            foreach my $status (keys %{$service_health_status}) {
                my $pct   = $total > 0 ? sprintf('%.0f',
                        $service_health_status->{$status}->{'total'}/$total*100) : '0';
                $env_val .= ',' . $status . '=' . $service_health_status->{$status}->{'total'};
                $env_val .= ',' . $status . '_pct=' . $pct;
            }
            $env_val =~ s/,,/,/g;
            $ENV{$env_name} = $env_val;
        }
    }
}

=head3 take_env_snapshot()

Calls L<set_env()> and takes a snapshot of all the environment variables. This snapshot
is passed later when we heal the host so that you can know the state of how things were
when the main service failed.

All snapshot environment variables will start with I<APOLLO_SNAPSHOT_> and their names
and values are the same as the ones of L<set_env()>.

=cut
sub take_env_snapshot {
    my ($self) = @_;

    $self->set_env();
    foreach my $env_key (keys %ENV) {
        next unless ($env_key =~ /^APOLLO/);
        next if ($env_key =~ /^APOLLO_SNAPSHOT/);

        my $new_key = $env_key;
        $new_key    =~ s/^APOLLO_/APOLLO_SNAPSHOT_/g;
        $self->{'snapshot_env'}->{$new_key} = $ENV{$env_key};
    }
}

=head3 can_host_go_down()

Checks if the current host can go into a BAD state.

How it decides if the current host can go into a BAD state? Apollo will take
the following decisions:

=over 4

=item 1. Check if any there are any hosts left and with their checks passing. If
there are none then Apollo will not let the host go down (returning undef) B<UNLESS>
L<allow_full_outage> is set.

=item 2. Then it will check if the total number of hosts (as a fixed number or a percent)
is greater than L<threshold_down>, if that is the case then Apollo will not let the host go
down because it is considered unsafe.

=back

In order for Apollo to don't be switching/flapping the list of bad/down hosts, it will sort
the list of those bad hosts and ONLY use the first N of them, where N is the threshold of
hosts that we can allow. The reason of this is important: if your service has 10 nodes, your
threshold is 5 (50%) and you are in the middle of a big outage then there is a high chance
that host number 9 (say host9) will sometimes be also failing and then it wont (flapping)
because Apollo runs the checks at different intervals (in milliseconds, I<ms>) so
in order to prevent this flapping Apollo will sort the list of bad hosts and only count until
5, that means if somehow 80% of your hosts are in bad state (host1 .. host8) then Apollo
will only be using the list of host1 .. host5.

It will return true if the host can go down.

=cut
sub can_host_go_down {
    my ($self) = @_;

    # Get the ranges
    my ($service_health_status) = $self->get_service_nodes($self->{'service_name'}, 1);
    my $record                  = $self->{'service_name'} . '.service.' . $self->{'colo'} . '.consul';
    my $log_tag                 = "service:" . $self->{'service_name'};
    unless ($service_health_status) {
        log_error("[$log_tag] Was impossible to get service status from $self->{'service_name'}");
        return undef;
    }

    my $we_have_enough = $service_health_status->{'passing'}->{'total'} ? 1 : 0;
    unless ($we_have_enough) {
        log_warn("[$log_tag] $record does not have any entries or all hosts are down skipping the healing");
        if ($self->{'allow_full_outage'}) {
            log_warn("[$log_tag] I said $record does not have any entries but allowing full outage!");
        } else {
            return undef;
        }
    }

    # Do we have any bad hosts? If not why would we even care?
    unless ($service_health_status->{'critical'}->{'total'}) {
        log_debug("[$log_tag] $record does not have any down hosts! :)");
        return 1;
    }

    # Does user even care about thresholds? If not, how would we even care?
    unless ($self->{'threshold_down'}) {
        log_warn("[$log_tag] Uh, no thresholds for either how many hosts you allow to have UP or DOWN. You " .
                "like to live dangerously. That means I can take as many hosts I want OOR :D");
        return 1;
    }
    
    # Ok, I guess we have some bad hosts and user cares about us not
    # taking the whole thing down
    my $down_threshold  = $self->get_threshold($self->{'service_name'}, 'down');
    my $critical_total  = $service_health_status->{'critical'}->{'total'};
    unless ($critical_total >= $down_threshold) {
        log_info("[$log_tag] $record has $critical_total servers DOWN (BAD). Threshold for DOWN is $down_threshold");
        return 1;
    }
    
    # Ok, we are hare, we should only care about those first N hosts
    # that are bad and only keep those in BAD.
    my @bad_nodes = ();
    my $total_bads = 0;
    # Make sure we get all the bad hosts and sorted
    my @nodes = $self->compare_ranges(
            $service_health_status->{'critical'}->{'range'},
            $service_health_status->{'any'}->{'range'});
    unless (@nodes) {
        log_warn("[$log_tag] Not letting this host go down because failed to expand range: " .
                $service_health_status->{'critical'}->{'range'});
        return undef;
    }
    # Ok, only get the first N hosts and check if this host is part of those
    my $last_index      = $down_threshold-1;
    my @first_bad_nodes = ();
    if ($last_index < 0) {
        log_warn("[$log_tag] $record returned $critical_total servers DOWN. This is more than what we " .
            "expect it to be ($down_threshold). Also couldn't get the pool of existing bad hosts based " .
            "so this will be flapping");
        @first_bad_nodes = @nodes;
    } else {
        @first_bad_nodes = @nodes[0 .. $last_index];
    }
    my $first_bad_range = $self->compress_range(\@first_bad_nodes);
    # Ok, we part of this pool?
    if (grep($_ eq $self->{'hostname'}, @first_bad_nodes)) {
        log_warn("[$log_tag] $record returned $critical_total servers DOWN. This is more than what we " .
            "expect it to be ($down_threshold), however host joined first into the pool of " .
            "bad hosts ($first_bad_range), so it can go DOWN");
        return 1;
    }
    log_warn("[$log_tag] $record returned $critical_total servers DOWN. This is more than what we " .
            "expect it to be ($down_threshold). Also the pool of allowed bad hosts is taken by: " .
            $first_bad_range);
    return undef;
}

=head3 get_threshold($type)

Translates the threshold. Basically it returns the exact number of hosts
that we expect either to be UP or DOWN.

Set C<$type> if you want the up or down threshold by passing 'up' or 'down'.

C<$type> can either be represented as:

=over 4

=item *

A B<fixed> number. In which case we require this exact number of hosts before
we take a decision.

=item *

Or a B<percentage>. In which case it needs to have a I<%> sign. If a percentage
is used then Apollo will ask consul for the total number of hosts that it knows
of a given service (regardless of their state/status).

=back

In the of B, we know that Consul will re-ap (throw away) hosts that have been
out of service for more than 72 hours, that is enough for us to get a good number
of known hosts.

=cut
sub get_threshold {
    my ($self, $service, $type) = @_;

    my $threshold = $self->{'threshold_' . $type};
    $threshold    = '50%' unless $threshold;

    if ($threshold =~ /%/) {
        my $known    = 0;
        my $service_status = $self->get_service_nodes($service);
        if ($service_status) {
            $known = $service_status->{'any'}->{'total'};
        }
        $threshold =~ s/%//g;
        my $value = int(($known*$threshold)/100);
        return $value;
    } else {
        return $threshold;
    }
}

=head3 generate_heal_report($taken_oor, $services)

Generates a report of all the services and subservices and their status. The report is
stored in a text file (L<report_file>). This report is updated after each self-healing.

You can use this file via your /etc/motd, /etc/issue or profile.d. An example:

    $ cat /etc//profile.d/apollo-show-report.sh 
    
    #!/usr/local/bin/bash
    report=/path/to/report.txt
    if [[ -f $report ]]; then
        cat $report
    fi

=cut
sub generate_heal_report {
    my ($self, $taken_oor, $services) = @_;

    my $url = $self->{'consul_endpoint'} . '/v1/agent/checks';
    my $response;
    my $retry = 0;
    while(1) {
        $response = $self->{'ua'}->get($url);
        last if $response->is_success;
        $retry++;
        last if ($retry == 5);
        log_info("Retrying $url (next try in 30 seconds)...");
        sleep(30);
    }
    my $report_file = $self->{'report_file'};
    open(REPORT_H, "> $report_file.tmp") or die "Failed to write report to $self->{'report_file'} - $@";
    print REPORT_H "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n";
    print REPORT_H "\n Apollo report:\n";
    if ($self->{'heal_dryrun'}) {
            print REPORT_H "\n\t - Healing status: Not healing (dry-run)\n\n";
    } else {
        if ($taken_oor) {
            print REPORT_H "\n\t - Healing status: Host has been healed or is getting healed\n";
        } else {
            print REPORT_H "\n\t - Healing status: Unknown\n\n";
        }
    }
    if ($response->is_success) {
        log_debug("Called $url and got: " . $response->status_line);
        my $content  = $response->decoded_content;
        my $json     = decode_json($content);
        # Ok, check each service
        foreach my $service (@{$services}) {
            my $key = 'service:' . $service->{'id'};
            if ($json->{$key}) {
                my $status = $json->{$key}->{'Status'};
                $status = 'OK' if ($status eq 'passing');
                $status = 'BAD' if ($status eq 'critical');
                $status = 'WARNING' if ($status eq 'warning');
                print REPORT_H "\t - Status of $service->{'id'} is $status\n";
            }
        }
        print REPORT_H "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n";
        close(REPORT_H);
        system("cp -f $report_file.tmp $report_file");
        log_debug("[report] Called $url and got: " . $response->status_line);
    } else {
        log_error("[report] Called $url and seems I failed with: " . $response->decoded_content);
    }
}

=head3 check_service($service_name, $datacenter)

Does a DNS query to consul for the given service (L<$service_name)> and for the given
datacenter (L<$datacenter>). Returns an array of all the hosts behind this service.

Not used in the code but kept as a convenience.

Returns undef if no hosts are found.

=cut
sub check_service {
    my ($self, $service_name, $datacenter) = @_;
    
    $datacenter = $self->{'colo'} unless $datacenter;

    my $record = $service_name . '.service.' . $datacenter . '.consul';
    log_debug("Trying to resolve (SRV record): $record with localhost:8600");
    my $res = Net::DNS::Resolver->new(
            nameservers     => [qw(127.0.0.1)],
            port            => 8600);
    # Use Virtual Circuit - Aka TCP
    $res->usevc(1);

    my $query = $res->search($record, 'SRV');
    my @records;
    if ($query) {
        if ($query->additional) {
            foreach my $rr ($query->additional) {
                next unless $rr->type eq 'A';
                push(@records, {
                        'name'  => $rr->name,
                        'ip'    => $rr->address});
            }
        } else {
            log_debug("$record does not have any *additional* (SRV) data");
        }
    }
    return @records;
}

=head3 get_all_consul_services()

Returns an array with all existing services.

Returns undef if we can't get an answer.

=cut
sub get_all_consul_services {
    my ($self) = @_;

    my $url = '/v1/catalog/services';
    my $response = $self->{'ua'}->get($self->{'consul_endpoint'} . $url);
    if ($response->is_success) {
        my $content  = $response->decoded_content;
        my $json;
        eval {
            $json = decode_json($content);
        };
        if ($@) {
            log_error("Failed to get list of services");
            return undef;
        }
        my @services = ();
        foreach my $service (keys %{$json}) {
                push(@services, $service);
        }
        return @services;
    }
    return undef;
}

=head3 get_node_services($node)

Returns a list (an array of hashes) of all the services that the current node has and
their status. Each item is a hash that has the status name (such as passing, failing,
etc) and the last time it changed.

The last time when the status changed is set when we pass/warn/fail a check, Apollo
sets the timestamp via a parameter and the value is kept on Consul. If a service
does not have a time then 0 is returned. If a service TTL expired then the time will
be -1.

The hash keys are:

=over 4

=item *

B<name>: Service's name

=item *

B<status>: The status code in consul's world (passing/critical/warning).

=item *

B<status_code>: The exit code associated with the C<status>.

=item *

B<by_apollo>: A boolean that can say if the status was done via apollo or another way (like
taking the host OOR).

=item *

B<since>: Timestamp of when the status was set.

=back

=cut
sub get_node_services {
    my ($self, $node) = @_;

    $node = $self->{'hostname'} unless $node;
    my $retry = 0;
    my $max_retries = 4;
    while(1) {
        log_debug("Getting services from this host");
        $retry++;
        my $request = $self->{'ua'}->get($self->{'consul_endpoint'} . '/v1/health/node/' . $node);
        if ($request->is_success) {
            my $json;
            eval {
                $json = decode_json($request->decoded_content);
            };
            if ($@) {
                log_error("Failed to process query of $node, tried to get info. $!");
                return undef;
            }
            my @services = ();
            foreach my $entry (@{$json}) {
                my $lastchange = 0;
                my $by_apollo = 0;
                if ($entry->{'Output'}) {
                    if ($entry->{'Output'} =~ /Last change was on (\d+\.?\d+)/) {
                        $lastchange = $1;
                    }
                    if ($entry->{'Output'} =~ /TTL expired/) {
                        $lastchange = -1;
                    }
                    if ($entry->{'Output'} =~ /by:apollo/) {
                        $by_apollo = 1;
                    }
                }
                my $service_name = $entry->{'ServiceID'};
                if ($entry->{'CheckID'} =~ /serfHealth/) {
                    $service_name = 'consul';
                }
                my $status_code;
                if ($entry->{'Status'} eq 'passing') {
                    $status_code = App::Apollo::Status::OK;
                } elsif ($entry->{'Status'} eq 'critical') {
                    $status_code = App::Apollo::Status::BAD;
                } elsif ($entry->{'Status'} eq 'warning') {
                    $status_code = App::Apollo::Status::WARN;
                }
                push(@services, {
                        'name'          => $service_name,
                        'status'        => $entry->{'Status'},
                        'status_code'   => $status_code,
                        'by_apollo'     => $by_apollo,
                        'since'         => $lastchange});
            }
            return @services;
        } else {
            # We SHOULD NEVER get here, but having this in case Consul
            # starts getting overloaded and consul servers start flapping
            if ($retry > $max_retries) {
                log_error("Failed to get the health of $node");
                return undef;
            } else {
                log_error("Retrying. trying to get health of $node once again (retry $retry)");
                sleep(1);
            }
        }
    } 
}

=head3 get_service_status($service)

Returns the status (as stored in consul) of a given service for the current
host.

The status that is returned is in the form of an array:

=over 4

=item 1. The status code in consul's world (passing/critical/warning).

=item 2. The exit code associated with the C<status>.

=item 3. A boolean that can say if the status was done via apollo or another way (like
taking the host OOR).

=item 4. Timestamp of when the status was set.

=back

=cut
sub get_service_status {
    my ($self, $service_name) = @_;

    my @node_services = $self->get_node_services();
    if (@node_services) {
        foreach my $node_service (@node_services) {
            next unless $node_service->{'name'};
            if ($node_service->{'name'} eq $service_name) {
                return ($node_service->{'status'},
                        $node_service->{'status_code'},
                        $node_service->{'by_apollo'},
                        $node_service->{'since'});
            }
        }
    }
    return undef;
}

=head3 get_service_nodes($service, $include_range)

Returns a hash with how many nodes are in each status (according to consul).

=over 4

=item *

B<any>: All nodes behind the server, regardless of status.

=item *

B<unknown> All nodes that have an unknown status.

=item *

B<passing>: All nodes that have a passing status (aka up).

=item *

B<warning>: All nodes that have a warning status.

=item *

B<critical>: All nodes that have a critical status.

=back

Apollo will query two checks, one is the one associated with the given service, C<$service>,
while the other one is associated with the internal consul healthcheck (C<serfHealth>), if
B<ANY> of those checks is bad then we assume the service is in critical state.

Please note that the hash only includes the total number of hosts, to also get the range
of hosts in a given status please use C<$include_range>.

If things go south or we can't get an answer then we return undef.

=cut
sub get_service_nodes {
    my ($self, $service, $include_range) = @_;

    my $url = '/v1/health/service/' . $service;
    my $response = $self->{'ua'}->get($self->{'consul_endpoint'} . $url);
    if ($response->is_success) {
        my $nodes = {};
        my $content  = $response->decoded_content;
        my $json;
        eval {
            $json = decode_json($content);
        };
        if ($@) {
            log_error("[service:$service] Failed to get nodes behind service $service");
            return undef;
        }
        foreach my $service_node (@{$json}) {
            my $status = '';
            foreach my $check (@{$service_node->{'Checks'}}) {
                if ($check->{'CheckID'} eq 'serfHealth') {
                    if ($check->{'Status'} eq 'critical') {
                        $status = $check->{'Status'};
                        last;
                    }
                }
                if ($check->{'CheckID'} eq 'service:' . $service) {
                    $status = $check->{'Status'};
                }
            }
            $nodes->{'any'}->{'total'} = 0 unless $nodes->{'any'}->{'total'};
            $nodes->{'any'}->{'total'}++;

            $status = 'passing' unless $status;
            $nodes->{$status}->{'total'} = 0 unless $nodes->{$status}->{'total'};
            $nodes->{$status}->{'total'}++;

            if ($include_range) {
                push(@{$nodes->{'any'}->{'hosts'}}, $service_node->{'Node'}->{'Node'});
                push(@{$nodes->{$status}->{'hosts'}}, $service_node->{'Node'}->{'Node'});
            }
        }

        if ($include_range) {
            foreach my $status (keys %{$nodes}) {
                $nodes->{$status}->{'range'} = $self->compress_range($nodes->{$status}->{'hosts'});
                delete($nodes->{$status}->{'hosts'});
            }
        }
        return $nodes;
    } else {
        return undef;
    }
}

=head3 expand_range($range)

Expands the given range of hosts.

A range is a compressed view (think of CSV) of a list of hosts. Many companies define
their ranges (or clusters) in different ways so if you want to use your in-house solution
then this method should be overwriten.

Returns an array (the list of hosts).

=cut
sub expand_range {
    my ($self, $range) = @_;

    my @hosts = split(/,/, $range);
    return @hosts;
}

=head3 sorted_expand_range($range)

Similar to L<expand_range()> except that it guarantees that the list of hosts is 
sorted.

A range is a compressed view (think of CSV) of a list of hosts. Many companies define
their ranges (or clusters) in different ways so if you want to use your in-house solution
then this method should be overwriten.

Returns an array (the list of hosts).

=cut
sub sorted_expand_range {
    my ($self, $range) = @_;

    my @hosts = $self->expand_range($range);
    @hosts = sort @hosts;
    return @hosts;
}

=head3 compress_range($host_list)

Does the opposite of L<expand_range()>, it takes a list of hosts and returns them
in a compressed format (CSV).

A range is a compressed view (think of CSV) of a list of hosts. Many companies define
their ranges (or clusters) in different ways so if you want to use your in-house solution
then this method should be overwriten.

Returns an array (the list of hosts).

=cut
sub compress_range {
    my ($self, $host_list) = @_;

    my $range = join(',', @{$host_list});
    return $range;
}

=head3 compare_range($range_a, $range_b)

It looks for the intersection of hosts with two range of hosts.

For example if C<$range_a> has:

    one,two,three,four.

And C<$range_b> has:

    two,four

Then the returned value will be an array that has two and four.

=cut
sub compare_ranges {
    my ($range_a, $range_b) = @_;

    my @range_a_sorted = sorted_expand_range($range_a);
    my @range_b_sorted = sorted_expand_range($range_b);

    my $lc = List::Compare->new(\@range_a_sorted, \@range_b_sorted);
    return $lc->get_intersection;
}

######################## METHODS/FUNCTIONS ##############################
sub BUILD {
    my ($self) = @_;

    # Load the config
    if (-f $self->{'config_file'}) {
        $self->{'config'} = LoadFile($self->{'config_file'});
    } else {
        die "$self->{'config_file'} does not exist";
    }

    # Store all the keys
    foreach my $config_key (keys %{$self->{'config'}}) {
        $self->{$config_key} = $self->{'config'}->{$config_key};
    }

    if (!$self->{'hostname'} and !$self->{'colo'}) {
        die "Not able to guess the short FQDN or the colo from this host and *hostname* and *colo* " .
            "were not found in $self->{'config_file'}";
    }

    die "service_name was not set" unless $self->{'service_name'};

    # Do we have any tags? like special IDs for this service/cluster?
    if ($self->{'tags_list'}) {
        @{$self->{'tags'}} = split(',', $self->{'tags_list'});
    }

    # Create a UA
    $self->{'ua'} = LWP::UserAgent->new;
    $self->{'ua'}->timeout(5);

    # for keeping the checks in check
    $self->{'running_checks'} = {}; 

    init_logger();
    use_debug(1) if $self->{'debug'};
}


# Run the command
sub run_cmd {
    my ($self, $cmd, $service_to_run) = @_;

    $self->set_env();

    my $timeout = 600; # 10 minutes

    my ($result, $out, $err, $error_msg, $in);
    my @cmd_array = split(/\s+/, $cmd);
    my $full_path = $cmd_array[0];
    unless (-x $full_path) {
        log_info("[service:$service_to_run] $full_path does NOT exist");
        return App::Apollo::Status::WARN;
    }
    
    eval {
        log_info("[service:$service_to_run] Running command: $cmd - will timeout in $timeout seconds");
        $result = run_forked("@cmd_array", {
                child_in => \$in,
                timeout  => $timeout});
    };
    unless ($result) {
        log_info("[service:$service_to_run] $cmd likely does not exist, but guessing this a mistake from you, so just a WARN");
        return App::Apollo::Status::WARN;
    }
    if ($result->{'timeout'} == $timeout) {
        log_warn("[service:$service_to_run] $cmd timed out, but playing safe and marking this failure as OK");
        return 0;
    }

    my $exit_code;
    if ($result->{'exit_code'} == App::Apollo::Status::OK) {
        log_info("[service:$service_to_run] $cmd finished OK - exit $result->{'exit_code'}");
        $exit_code = App::Apollo::Status::OK;
    } elsif ($result->{'exit_code'} == App::Apollo::Status::OOR) {
        log_info("[service:$service_to_run] $cmd finished BAD (OOR) - exit $result->{'exit_code'}");
        $exit_code = App::Apollo::Status::OOR;
    } elsif ($result->{'exit_code'} == App::Apollo::Status::BAD) {
        log_info("[service:$service_to_run] $cmd finished BAD - exit $result->{'exit_code'}");
        $exit_code = App::Apollo::Status::BAD;
    } elsif ($result->{'exit_code'} == App::Apollo::Status::WARN) {
        log_info("[service:$service_to_run] $cmd finished WARN - exit $result->{'exit_code'}");
        $exit_code = App::Apollo::Status::WARN;
    } else {
        log_info("[service:$service_to_run] $cmd finished with UNKNOWN - exit $result->{'exit_code'} - but playing safe");
        $exit_code = App::Apollo::Status::UNKNOWN;
    }
    # The output
    $out = $result->{'merged'} ? $result->{'merged'} : '';
    if ($out) {
        chomp($out);
        my @lines = split(/\n/, $out);
        log_info("[service:$service_to_run] $cmd threw the following to STDERR/STDOUT: ");
        foreach my $line (@lines) {
            log_info("[service:$service_to_run] $line");
        }
    }
    return $exit_code;
}

sub check_pid {
    my ($self) = @_;
    
    # Is there a pid or some sort?
    my $pid_file = $self->{'pid_file'};
    my $pid_block = 0;
    if (-f $pid_file) {
        # The pid still exists?
        my $pid = qx(cat $pid_file);
        chomp($pid);
        if (-d "/proc/$pid") {
            log_fatal("$pid_file exists and pid $pid is still running");
            exit 1;
        }
    }
    open(PID_H, "> $pid_file") or die "Failed to write to $pid_file";
    print PID_H "$$";
    close(PID_H);
}

sub get_all_services {
    my ($self) = @_;

    # Get a list of all the services we need
    my @extra_services   = $self->build_consul_extra_service_config();
    my @all_services     = ();

    # First fill up any extra services and pick a random sleep value (in ms). Keep the
    # value because that value will be used to set the sleep value for our main
    # service. Reason of this is so that we let the extra services finish first and
    # then do the main service
    my $max_msslep = 0;
    foreach my $service (@extra_services) {
        my $rand 	= 10 + int(rand(200 - 10));
        if ($rand > $max_msslep) {
            $max_msslep = $rand;
        }
        # Sub-services or extra services should have their own frequency
        push(@all_services, {
                'id'            => $service->{'def'}->{'service'}->{'name'},
                'script'        => $service->{'def'}->{'service'}->{'check'}->{'script'},
                'retries'	    => $service->{'def'}->{'service'}->{'check'}->{'retries'},
                'mssleep'       => $rand,
                'frequency'     => $service->{'def'}->{'service'}->{'check'}->{'real_ttl'}});
    }
    
    if ($self->{'service_cmd'} and $self->{'service_frequency'}) {
        # Our random number should be between $max_mssleep + 100ms and
        # $max_mssleep + 300ms
        my $rand 	= ($max_msslep+100) + int(rand(($max_msslep+300) - ($max_msslep+100)));
        # Main service frequency should be set to service_frequency.
        push(@all_services, {
                'id'            => $self->{'service_name'},
                'script'        => $self->{'service_cmd'},
                'mssleep'       => $rand,
                'frequency'     => $self->{'service_frequency'}});
    }
    foreach my $service (@all_services) {
        log_info("[service:$service->{'id'}] Will be set to run every $service->{'frequency'} with a sleep of " .
                "$service->{'mssleep'}ms");
    }
    return @all_services;
}
1;

