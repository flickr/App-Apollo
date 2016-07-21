#
# App::Apollo::Tools::Logger
#
# Copyright 2016 Yahoo INC.
# Check the LICENSE file for the COPYRIGHT/LICENSE
package App::Apollo::Tools::Logger;

=head1 NAME

App::Apollo::Tools::Logger - Main logger interface, uses log4perl

=head1 DESCRIPTION

Main logger interface, uses log4perl

=cut
use strict;
use warnings;
use Exporter 'import';
use vars qw(@EXPORT_OK @EXPORT);
use Log::Log4perl qw(:easy get_logger :levels);
use Data::Dumper;
use FindBin;

@EXPORT_OK = qw(init_logger use_debug log_debug log_error log_info log_die log_fatal log_warn);
@EXPORT = @EXPORT_OK;

my $LOGGER = undef;
my $USE_DEBUG = 0;

=head2 Functions

=head3 init_logger()

Creates the logger object.

=cut
sub init_logger {
    my ($self) = @_;

    my $log4perl_config = "log4perl.logger.Apollo=DEBUG, Logfile\n";
    $log4perl_config .= "log4perl.appender.Logfile=" .
        "Log::Log4perl::Appender::Screen\n";
    $log4perl_config .= "log4perl.appender.Logfile.stderr=1\n";
    $log4perl_config .= "log4perl.appender.Logfile.layout=" .
        "Log::Log4perl::Layout::PatternLayout\n";
    $log4perl_config .= "log4perl.appender.Logfile.DatePattern=" .
        "yyyy-MM-dd\n";
    $log4perl_config .= "log4perl.appender.Logfile.layout.ConversionPattern=" .
        "\%d \%p \%m \%n";
    Log::Log4perl->init(\$log4perl_config);
    $LOGGER = get_logger('Apollo');
}

=head3 use_debug($on)

Turn on (by default) or off debug mode.

=cut
sub use_debug {
    my ($on) = @_;

    $USE_DEBUG = $on ? 1 : 0;
    $ENV{'USE_DEBUG'} = $USE_DEBUG;
}

=head3 log_die($msg)

Dies with log4perl sending a C<logdie()>

=cut
sub log_die {
    my ($msg) = @_;

    if ($LOGGER) {
        $LOGGER->logcroak($msg);
    } else {
        die $msg;
    }
}

=head3 log_error($msg)

Logs an error, but not fatal errors to kill the app.

=cut
sub log_error {
    my ($msg) = @_;

    if ($LOGGER) {
        $LOGGER->error($msg);
    } else {
        print STDERR "ERROR: $msg\n";
    }
}


=head3 log_info($msg)

Logs an info message (something handy, just as a FYI).

=cut
sub log_info {
    my ($msg) = @_;

    if ($LOGGER) {
        $LOGGER->info($msg);
    } else {
        print STDERR "INFO: $msg\n";
    }
}


=head3 log_warn($msg)

Logs a warn message (something handy, just as a FYI).

=cut
sub log_warn {
    my ($msg) = @_;

    if ($LOGGER) {
        $LOGGER->warn($msg);
    } else {
        print STDERR "WARN: $msg\n";
    }
}

=head3 log_fatal($msg)

Logs a fatal message (kills app)

=cut
sub log_fatal {
    my ($msg) = @_;

    if ($LOGGER) {
        $LOGGER->fatal($msg);
    } else {
        print STDERR "FATAL: $msg\n";
        exit 1;
    }
}

=head3 log_debug($msg)

Handy for debug messsages.

=cut
sub log_debug {
    my ($msg) = @_;

    if (!$USE_DEBUG) {
        if (!$ENV{'USE_DEBUG'}) {
            return;
        }
    }
    if ($LOGGER) {
        $LOGGER->debug($msg);
    } else {
        print STDERR "DEBUG: $msg\n";
    }
}

1;
