#
# Test: 102-exit-codes.t
#
# Copyright 2016 Yahoo INC.
# Check the LICENSE file for the COPYRIGHT/LICENSE
use strict;
use warnings;
use Test::More tests => 9;                      # last test to print
use FindBin '$RealBin';
use App::Apollo::Status;

ok(0 == App::Apollo::Status::HEALED, "HEALED exit-code = 0");
ok(0 == App::Apollo::Status::OK, "OK exit-code = 0");
ok(1 == App::Apollo::Status::WARN, "WARN exit-code = 1");
ok(2 == App::Apollo::Status::BAD, "BAD exit-code = 2");
ok(3 == App::Apollo::Status::OOR, "OOR exit-code = 3");
ok(1 == App::Apollo::Status::UNKNOWN, "UNKNOWN exit-code = 2");

# Now the healing exit codes
ok(100 == App::Apollo::Status::OK_HEAL_NOW, "OK_HEAL_NOW = 100");
ok(101 == App::Apollo::Status::WARN_HEAL_NOW, "WARN_HEAL_NOW = 101");
ok(102 == App::Apollo::Status::BAD_HEAL_NOW, "BAD_HEAL_NOW = 102");


