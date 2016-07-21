#
# Test: 1-load-module.t
#
# Copyright 2016 Yahoo INC.
# Check the LICENSE file for the COPYRIGHT/LICENSE
use strict;
use warnings;
use Test::More tests => 3;

BEGIN {
    use_ok('App::Apollo');
    use_ok('App::Apollo::Status');
    use_ok('App::Apollo::Tools::Logger');
}




