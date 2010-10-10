#!/usr/bin/perl
use warnings;
use strict;
use lib './lib';
use ELM::Ford;
use Twatch;
use Daemon::Daemonize ':all';

$|=1;

if ($ARGV[0] eq '--fork') {
  print "About to fork\n";
  my $log_filename = "/root/carstuff/logs/logs-".time.".log";
  open my $logfh, ">", $log_filename or die "Can't open $log_filename: $!";
  daemonize(chdir => '/root/carstuff/logs',
            close => 1,
            stdout => $logfh,
            stderr => $logfh,
           ) or die "Couldn't deamonize: $!";
  print "Forked\n";
}


print "Connecting to ELM\n";
my $elm = ELM::Ford->new(usb_vendor => '0403', usb_product => '6001', verbose => 0);
#my $elm = ELM::Ford->new(port => '/dev/ttyUSB0', verbose => 1);

#print "01 0d 1:  [[[", do_command($elm, "01 0d 1"),  "]]]\n";

print "Connecting to twatch\n";
my $twatch = Twatch::new('169.254.1.1', undef, 4, 20);
print "Staring up\n";
$twatch->clearLCD();
$twatch->backlightOn();

print "Running!\n";
while (1) {
    my $speed = $elm->mph;
    # In L.
    my $fuel = $elm->fuel_remaining(50);

    my $speed_blocks = int($speed/5);
    # \xFF is solid block.
    my $speed_char = $speed > 70 ? '*' : "\xFF";
    $twatch->printLine(sprintf("%2d %s", $speed, ($speed_char x $speed_blocks) . (' ' x (17-$speed_blocks))), 1, 1);

    my $fuel_blocks = int($fuel/50 * 17);
    $twatch->printLine(sprintf("%2d %s", $fuel, "\xFF" x $fuel_blocks . ' ' x (17 - $fuel_blocks)), 2, 1);

    $twatch->printLine(scalar localtime, 4, 1);
    print time, ", $speed, $fuel\n";
    sleep 1;
}
