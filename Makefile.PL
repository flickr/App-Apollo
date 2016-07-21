use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

system qq{$^X -MPod::Text -e "pod2text(q(lib/App/Apollo.pm))" > README};
WriteMakefile(
    NAME	      => 'App::Apollo',
    VERSION_FROM  => 'lib/App/Apollo.pm', # finds $VERSION
    ABSTRACT_FROM => 'lib/App/Apollo.pm',
    AUTHOR        => 'Pablo Fischer',
    LICENSE       => 'mit',
    PREREQ_PM     => {
        'Moose'                         => 0,
        'AnyEvent'                      => 0,
        'IPC::Cmd'                      => 0,
        'URI'                           => 0,
        'Net::DNS'                      => 0,
        'MIME::Base64'                  => 0,
        'JSON'                          => 0,
        'YAML::Syck'                    => 0,
        'Time::HiRes'                   => 0,
        'File::Slurp'                   => 0,
        'Log::Log4perl'                 => 0,
        'List::Compare'                 => 0,
        'Getopt::Long::Descriptive'     => 0,    
    },
    EXE_FILES    => [
        'bin/apollo-run-healing'
    ],
    BUILD_REQUIRES => {
        'Test::More'                    => '1.001',
    },
    META_MERGE        => {
       resources => {
           repository  =>  'http://github.com/Flickr/Apollo',
       },
       x_contributors => [
           'Pablo Fischer <pablo@pablo.com.mx>',
       ],
    },
    dist => {
      PREOP => $^X.' -MPod::Text -e "pod2text(q(lib/App/Apollo.pm))" > README'
    }
);
