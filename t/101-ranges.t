#
# Test: 002-load-config.t
#
# Copyright 2016 Yahoo INC.
# Check the LICENSE file for the COPYRIGHT/LICENSE
use strict;
use warnings;
use Test::More tests => 8;                      # last test to print
use FindBin '$RealBin';
use App::Apollo;

my $app = App::Apollo->new(
        config_file             => "$RealBin/conf/test_config.yaml",
        consul_config_file      => "$RealBin/conf/test_consul_config.yaml");

my $range = "test101.west.example.com,test103.west.example.com,test102.west.example.com";

my @unsorted_hosts = $app->expand_range($range);

ok($unsorted_hosts[0] eq 'test101.west.example.com', "First host from unsorted $range is test101");
ok($unsorted_hosts[1] eq 'test103.west.example.com', "Second host from unsorted $range is test103");
ok($unsorted_hosts[2] eq 'test102.west.example.com', "Third host from unsorted $range is test102");


# Ok, now do the expand but sorted
my @sorted_hosts = $app->sorted_expand_range($range);
ok($sorted_hosts[0] eq 'test101.west.example.com', "First host from sorted $range is test101");
ok($sorted_hosts[1] eq 'test102.west.example.com', "Second host from sorted $range is test102");
ok($sorted_hosts[2] eq 'test103.west.example.com', "Third host from sorted $range is test103");


# And compress them
ok($app->compress_range(\@unsorted_hosts) =~ /test101\S+,test103\S+,test102\S+/, "Compressed range of unsorted hosts");
ok($app->compress_range(\@sorted_hosts) =~ /test101\S+,test102\S+,test103\S+/, "Compressed range of sorted hosts");

