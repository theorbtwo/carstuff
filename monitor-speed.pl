#!/usr/bin/perl
use warnings;
use strict;
use lib './lib';
use ELM::Ford;
$|=1;

#my $elm = ELM::Ford->new(usb_vendor => '0403', usb_product => '6001', verbose => 0);
my $elm = ELM::Ford->new(port => '/dev/ttyUSB0', verbose => 1);

#print "01 0d 1:  [[[", do_command($elm, "01 0d 1"),  "]]]\n";

while (1) {
    my $speed = $elm->mph;
    # In L.
    my $fuel = $elm->fuel_remaining(50);

    print time, ", $speed, $fuel\n";
    sleep 1;
}
