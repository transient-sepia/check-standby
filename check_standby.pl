#!/usr/bin/perl -w
#
# standby-chan
# version 1.0
#
# / the elevator is out of order, but we can still climb. /
#

# use
use strict;
use DBI;
use POSIX;
use Getopt::Std;

# args
my %args;
getopts('h', \%args);

# arguments and help check
if ( $#ARGV < 1 && !$args{h} ) {
   print "WARNING - Input error. Use -h.\n";
   exit 1;
}

my $help = "\n\tcheck_standby - checks the status of standby databases.\n \
        check_standby.pl [-h] <INSTANCE> <USERNAME> [<WARN>]\n \
        <INSTANCE> - database alias. \
        <USERNAME> - connect with the specified user. \
        <WARN>     - defines the warning number of minutes for database apply lag (optional).\n \
        -h - print this message\n\n";
if ($args{h}) { print $help; exit 1; }

# variables
my ($lag_minutes,$mrp_process,$mrp_status,$output,$ec,$app,$days,$else,$hours,$mins,$secs,$lag);
my $client_process = "NONE";
my $instance = $ARGV[0];
my $user = $ARGV[1];
my $warn = defined($ARGV[2]) ? $ARGV[2] : 60;
my $pwd = "";

# checks
my $dbh = DBI->connect( 'dbi:Oracle:'.$instance,$user,$pwd,{ora_session_mode => 2, PrintError => 0});
if ($DBI::errstr) { print "WARNING - Database connection not made: $DBI::errstr\n"; exit 1; }

my $db_mode_query = q{ select database_role from v$database };
my $sth = $dbh->prepare($db_mode_query);
$sth->execute();
my $db_mode = $sth->fetchrow_array;
if ($db_mode ne 'PHYSICAL STANDBY') {
   print "WARNING - This script can only check physical standby databases.\n";
   exit 1;
} else {
   my $srl_num_query = q{ select count(*) from v$standby_log };
   $sth = $dbh->prepare($srl_num_query);
   $sth->execute();
   my $srl_num = $sth->fetchrow_array;
   if ($srl_num == 0) {
      print "WARNING - No standby redo logfiles were found.\n";
      exit 1;
   } else {
      my $srl_active_query = q { select count(*), status from v$standby_log where status = 'ACTIVE' group by status };
      $sth = $dbh->prepare($srl_active_query);
      $sth->execute();
      my ($srl_num_active,$srl_status) = $sth->fetchrow_array;
      if (!$srl_num_active) {
         my $client_process_q = q { select client_process from v$managed_standby where client_process = 'LGWR' };
         $sth = $dbh->prepare($client_process_q);
         $sth->execute();
         $client_process = defined($sth->fetchrow_array) ? $sth->fetchrow_array : 'ARCH';
         if ($client_process eq 'LGWR') {
            print "WARNING - Found $srl_num standby redo logfiles, but no ACTIVE ones. Please check your configuration.\n";
            exit 1;
         }
      }
   }
}

# main
my $lag_query = q{ select value from v$dataguard_stats where name='apply lag' };

$sth = $dbh->prepare($lag_query);
$sth->execute();
$lag_minutes = $sth->fetchrow_array;

my $mrp_query = q{
          select process, status
          from v$managed_standby
          where process like 'MR%'
        };

$sth = $dbh->prepare($mrp_query);
$sth->execute();
($mrp_process,$mrp_status) = $sth->fetchrow_array;

if (!$mrp_process) {
   $output = "WARNING - Unable to find MRP process, managed recovery may be stopped.\n";
   $ec = 1;
} else {
   if (!$lag_minutes) {
      $output = "WARNING - Recovery process status is $mrp_status, but apply lag couldn't be calculated.\n";
      $ec = 1;
   } else {
      substr($lag_minutes,0,1) = "";
      ($days,$else) = split(/\s/, $lag_minutes);
      # days
      if ($days eq '00' ) {
         # no days delay
         $days = 0;
      } elsif ($days =~ /^0/) {
         substr($days,0,1) = "";
         $days = $days * 24 * 60;
      } else {
         $days = $days * 24 * 60;
      }
      ($hours,$mins,$secs) = split(/:/, $else);
      # hours
      if ($hours eq '00' ) {
         # no hours delay
         $hours = 0;
      } elsif ($hours =~ /^0/) {
         substr($hours,0,1) = "";
         $hours = $hours * 60;
      } else {
         $hours = $hours * 60;
      }
      # minutes
      if ($mins eq '00' ) {
         # no minutes delay
         $mins = 0;
      } elsif ($mins =~ /^0/) {
         substr($mins,0,1) = "";
      } else {
         # minutes stay the same
      }
      # seconds
      if ($secs eq '00' ) {
         # no seconds delay
         $secs = 0;
      } elsif ($secs =~ /^0/) {
         substr($secs,0,1) = "";
         $secs = $secs / 60;
         $secs = sprintf('%.1f', $secs);
      } else {
         $secs = $secs / 60;
         $secs = sprintf('%.1f', $secs);
      }
      #print $days." ".$hours." ".$mins." ".$secs."\n";
      $lag = ceil($days + $hours + $mins + $secs);
      if ($lag <= $warn) { $app = "OK - "; $ec = 0; }
      #elsif ($lag > $warn && $lag <= $crit) { $app = "WARNING - "; $ec = 1; }
      else { $app = "WARNING - "; $ec = 1; }
      $output = $app."Dataguard standby lag is $lag minutes. | dataguard_lag=$lag;$warn\n";
   }
}

# output
print $output;
exit $ec;
