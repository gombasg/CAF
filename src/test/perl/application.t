use FindBin qw($Bin);
use lib "$Bin/modules";
use strict;
use warnings;
use Test::More;
use testapp;

use Test::MockModule;
use Test::Quattor::Object;
use CAF::Application qw($OPTION_CFGFILE);


is($OPTION_CFGFILE, 'cfgfile',
   "Magic configfile option name $OPTION_CFGFILE");

# test predefined options
my $defapp = CAF::Application->new('mydefname');
isa_ok($defapp, 'CAF::Application', 'A CAF::Application instance');
is($defapp->{NAME}, 'mydefname', 'NAME attribute set');

ok(! defined($defapp->option($OPTION_CFGFILE)), "OPTION_CFGFILE is undef by default");

# mock an application
my $def_cfgfile = '/doesnotexist/apptest.cfg';
my $def_value = 'mydefault';

my $mock = Test::MockModule->new('CAF::Application');
$mock->mock('app_options', sub {
    return [
        {
            NAME => "$OPTION_CFGFILE=s",
            DEFAULT => $def_cfgfile,
            HELP => 'Config file for test app',
        },
        {
            NAME => 'myoption=s',
            DEFAULT => $def_value,
            HELP => 'A very useful option',
        },
        ];
});

my $app = CAF::Application->new('myname');
isa_ok($app, 'CAF::Application', 'A CAF::Application instance');
is($app->{NAME}, 'myname', 'NAME attribute set');

# pick up the default
ok(! -f $def_cfgfile, "No default configfile $def_cfgfile found");
is($app->option($OPTION_CFGFILE), $def_cfgfile,
   "Default config file location $def_cfgfile");
is($app->option('myoption'), $def_value,
   "Default myoption value");

# use actual cfgfile
my $cfgfile = 'src/test/resources/apptest.cfg';
my $value = 'myvalue';

# 1st format --cfgfile path/tofile
my $newapp = CAF::Application->new('myname', "--$OPTION_CFGFILE", $cfgfile);
isa_ok($newapp, 'CAF::Application', 'A CAF::Application instance');

ok(-f $cfgfile, "configfile $cfgfile found");
is($newapp->option($OPTION_CFGFILE), $cfgfile,
   "Specified config file location $cfgfile via --cfgfile path/tofile");
is($newapp->option('myoption'), $value,
   "myoption value from configfile");

# 1st format short -cfgfile path/tofile
$newapp = CAF::Application->new('myname', "-$OPTION_CFGFILE", $cfgfile);
isa_ok($newapp, 'CAF::Application', 'A CAF::Application instance');

ok(-f $cfgfile, "configfile $cfgfile found shortformat");
is($newapp->option($OPTION_CFGFILE), $cfgfile,
   "Specified config file location $cfgfile via -cfgfile path/tofile shortformat");
is($newapp->option('myoption'), $value,
   "myoption value from configfile shortformat");

# 2nd format --cfgfile=path/tofile
my $newapp2 = CAF::Application->new('myname', "--$OPTION_CFGFILE=$cfgfile");
isa_ok($newapp2, 'CAF::Application', 'A CAF::Application instance');

is($newapp2->option($OPTION_CFGFILE), $cfgfile,
   "Specified config file location $cfgfile --cfgfile=path/tofile");
is($newapp2->option('myoption'), $value,
   "myoption value from configfile (2nd format)");

# 2nd format short -cfgfile=path/tofile
$newapp2 = CAF::Application->new('myname', "-$OPTION_CFGFILE=$cfgfile");
isa_ok($newapp2, 'CAF::Application', 'A CAF::Application instance');

is($newapp2->option($OPTION_CFGFILE), $cfgfile,
   "Specified config file location $cfgfile -cfgfile=path/tofile shortformat");
is($newapp2->option('myoption'), $value,
   "myoption value from configfile (2nd format) shortformat");

# handle non-option arguments
# case 1: old behaviour (using @ARGV does work, must be a special perl array)
my @args = qw(--myoption myvalue not an option);
my $app3 = CAF::Application->new('myname', @args);
isa_ok($app3, 'CAF::Application', 'A CAF::Application instance');
is($app3->{NAME}, 'myname', 'NAME attribute set');
is($app3->option('myoption'), 'myvalue', 'myoption=myvalue parsed');
is_deeply(\@args, [qw(--myoption myvalue not an option)],
          'args array does not handle remaining arguments correctly');

# case 2: new behaviour, single arrayref as argument
my $argsref = \@args;
$app3 = CAF::Application->new('myname', $argsref);
isa_ok($app3, 'CAF::Application', 'A CAF::Application instance');
is($app3->{NAME}, 'myname', 'NAME attribute set');
is($app3->option('myoption'), 'myvalue', 'myoption=myvalue parsed');
is_deeply($argsref, [qw(not an option)],
          'args array ref does remaining arguments correctly');

# test logging
# Mock FileHandle new from CAF::Log
use IO::String;
my $io = IO::String->new();
my $mock_fh = Test::MockModule->new('FileHandle');
$mock_fh->mock('new', $io);

# Pass fake logfile, to enable CAF::Application LOG config
my $tapp = testapp->new ($0, qw (--quiet --verbose --logfile test/fake/log));
ok($tapp->{LOG_TSTAMP}, "testapp has TSTAMP enabled");
ok($tapp->{LOG_PROCID}, "testapp has PROCID enabled");
$tapp->error("testmessage");
$io->seek(0);
like (join('', <$io>), qr{\d+/\d+/\d+-\d+:\d+:\d+ \[\d+\] \[ERROR\] testmessage},
      "log format as expected logged");

diag explain $tapp;

done_testing();
