package ELM::Ford;
use warnings;
use strict;
# FIXME: Install Path::Class on hal, then make this code use it, instead of handcoded junk.
#use Path::Class;

sub new {
  my ($class, %options) = @_;

  my $self = bless {}, $class;
  $self->{verbose} = $options{verbose};

  # Autodetect.  Very linux-specific, and only useful for USB devices.
  if (!$options{port} and $options{usb_vendor} and $options{usb_product}) {
    for my $tty_dir (glob('/sys/class/tty/*')) {
      # Skip non-device-based ttys (virtual consoles).
      if (!-e "$tty_dir/device") {
	next;
      }
      my $device_dir = "$tty_dir/" . readlink("$tty_dir/device");
      $device_dir =~ s!/[^/]*$!!;
      $device_dir =~ s!/[^/]*$!!;

      # Skip non-usb devices.
      next unless -e "$device_dir/idVendor";
      my $vendor = do {local @ARGV = "$device_dir/idVendor"; <>};
      chomp $vendor;
      my $product = do {local @ARGV = "$device_dir/idProduct"; <>};
      chomp $product;

      # print "$tty_dir - $vendor - $product\n";

      next unless ($options{usb_vendor}  eq $vendor and
		   $options{usb_product} eq $product);
      
      # The first place where we have an assumption that I'm not
      # sure is terribly defensable.
      $tty_dir =~ m!/([^/]*)$!
	or die "Can't figure name for tty $tty_dir";
      my $name = $1;
      die "Found USB $options{usb_vendor}:$options{usb_product} at $tty_dir, but can't find coorosponding device file /dev/$name"
	unless (-e "/dev/$name");
      
      # Woo!
      $options{port} = "/dev/$name";
      last;
    }
  }
  if (!$options{port} and $options{usb_vendor} and $options{usb_product}) {
    die "Could not autodetect device file for USB $options{usb_vendor}:$options{usb_product}";
  }

  if (!$options{port}) {
    die "Must specify port or usb_vendor + usb_product";
  }
  
  if ($self->{verbose}) {
    print "Opening on port $options{port}\n";
  }
  
  open my $fh, "+<", $options{port}
    or die "Couldn't open $options{port}: $!";

  $self->{fh} = $fh;

  if ($self->{verbose}) {
    print "stty\n";
  }

  # FIXME: Replace with something *other* then system?
  system("stty -F $options{port} 38400 -crtscts");

  my $oldselect = select($self->{fh});
  $| = 1;
  select($oldselect);

  if ($self->{verbose}) {
    print "ret\n";
  }

  $self->do_at_cmd('atd');
  $self->{headers} = 'defaut';
  $self->do_at_cmd('ath1');

  return $self;
}

# FIXME: Merge with do_at_cmd?
sub do_obd_cmd {
  my ($self, $cmd) = @_;

  if ($self->{headers} ne 'defualt') {
    $self->do_at_cmd('atd');
    $self->{headers} = 'defaut';
    $self->do_at_cmd('ath1');
  }

  $cmd .= "\x0D";

  my $cmd_copy = $cmd;
  $cmd_copy =~ s/([^ -~])/sprintf "\\x{%02x}", ord $1/ge;

  if ($self->{verbose}) {
    print "Outputting to ELM: $cmd_copy";
  }

  syswrite($self->{fh}, $cmd)
    or die "Couldn't output at command $cmd_copy to ELM: $!";

  my $res = '';
  while (1) {
    print "sysreading\n" if $self->{verbose};

    sysread($self->{fh}, $res, 1, length($res))
      or die "Couldn't sysread ELM: $!";

    print "sysread: '$res'\n" if $self->{verbose};

    if ($res =~ m/>$/) {
      $res =~ s/[\x0A\x0D]/\n/g;

      my $res_copy = $res;
      $res_copy =~ s/([^ -~])/sprintf "\\x{%02x}", ord $1/ge;

      if ($self->{verbose}) {
	print "Reponse from ELM: $res_copy";
      }

      $res =~ s/[\x0A\x0D]>// or die "Response to $cmd_copy ($res_copy) didn't end with prompt";
      # Where the command had an \xA or \xD in it, accept either in the response.
      my $cmd_re = $cmd;
      $cmd_re =~ s/[\x0A\x0D]/[\\x0A\\x0D]/g;
      print "Matching against $cmd_re\n" if $self->{verbose};
      $res =~ s/$cmd_re// or die "Response to $cmd_copy ($res_copy) didn't begin with echo";
      chomp $res;

      my @lines = grep {$_ ne 'NO DATA'} split /\n/, $res;
      @lines = map {
	my $raw = $_;
	$_ = [map {hex $_} split / /, $_];
	my ($pri_type, $target, $source, @payload) = @$_;
	my ($crc) = pop @payload;

	# jnat_v6_1.pdf, page 27.
	# ppphkyzz
	# 0 is most important, 7 is least important.
	my $priority = $pri_type >> 5;
	# 0: one-byte header, 1: three-byte header ???
	my $h = ($pri_type >> 4) & 1;
	# Is in-frame-response not allowed (0) or required (1).
	my $k = ($pri_type >> 3) & 1;
	# 0: functional addressing, 1: physical addressing.
	my $y = ($pri_type >> 2) & 1;
	# kyzz combined are message type.
	# Msg   KYZZ   Response   Addressing IFR  Message Type/Name
	# Type          (K bit)    (Y bit)  Type
	# 0     0000 Required    Functional  2   Function
	# 1     0001 Required    Functional  1   Broadcast
	# 2     0010 Required    Functional  2   Function Query
	# 3     0011 Required    Functional  3   Function Read
	# 4     0100 Required    Physical    1   Node-to-Node
	# 5     0101 Required    Physical     -  Reserved - MFG
	# 6     0110 Required    Physical     -  Reserved - SAE
	# 7     0111 Required    Physical     -  Reserved - MFG
	# 8     1000 Not Allowed Functional  0   Function Command / Status
	# 9     1001 Not Allowed Functional  0   Function Request / Query
	# 10    1010 Not Allowed Functional  0   Function Ext. Command / Status
	# 11    1011 Not Allowed Functional  0   Function Ext. Request / Query
	# 12    1100 Not Allowed Physical    0   Node-to Node
	# 13    1101 Not Allowed Physical    0   Reserved - MFG
	# 14    1110 Not Allowed Physical    0   Acknowledgement
	# 15    1111 Not Allowed Physical    0   Reserved - MFG
	
	my $z = $pri_type & 0b11;
	my $kyzz = $pri_type & 0b1111;

	+{
	  priority => $priority,
	  h => $h,
	  k => $k,
	  y => $y,
	  kyzz => $kyzz,
	  target => $target,
	  source => $source,
	  payload => \@payload,
	  crc => $crc,
	  raw => $raw,
	 };
      } @lines;

      return \@lines;
    }
  }
}

# FIXME: Merge with do_obd_cmd?
sub do_at_cmd {
  my ($self, $cmd) = @_;

  if ($cmd !~ m/^at/i) {
    $cmd = "AT $cmd";
  }
  $cmd .= "\x0D";

  my $cmd_copy = $cmd;
  $cmd_copy =~ s/([^ -~])/sprintf "\\x{%02x}", ord $1/ge;

  if ($self->{verbose}) {
    print "Outputting to ELM: $cmd_copy";
  }

  syswrite($self->{fh}, $cmd)
    or die "Couldn't output at command $cmd_copy to ELM: $!";

  my $res = '';
  while (1) {
    print "sysreading\n" if $self->{verbose};

    sysread($self->{fh}, $res, 1, length($res))
      or die "Couldn't sysread ELM: $!";

    print "sysread: '$res'\n" if $self->{verbose};

    if ($res =~ m/>$/) {
      my $res_copy = $res;
      $res_copy =~ s/([^ -~])/sprintf "\\x{%02x}", ord $1/ge;

      if ($self->{verbose}) {
	print "Reponse from ELM: $res_copy";
      }
      
      my $cmd_re = $cmd;
      $cmd_re =~ s/[\x0A\x0D]/[\\x0A\\x0D]/g;
      print "Matching $res_copy against $cmd_re\n" if $self->{verbose};

      next if($res !~ m/$cmd_re/);

      $res =~ s/$cmd_re// or die "Response to $cmd_copy ($res_copy) didn't begin with echo";
      $res =~ s/[\x0A\x0D]>// or die "Response to $cmd_copy ($res_copy) didn't end with prompt";
      $res =~ s/[\x0A\x0D]/\n/g;
      chomp $res;

      return $res;
    }
  }
}

sub rpm {
  my ($self) = @_;
  
  my $res = $self->do_obd_cmd('010c');
  if (!@$res) {
    die "No response to mode 01 PID 0x0C to get RPM";
  }

  my $payload = $res->[0]{payload};
  die unless (shift @$payload == 0x41 and
	      shift @$payload == 0x0C);
  return +($payload->[0]*255+$payload->[1])/4;
}

sub kph {
  my ($self) = @_;
  
  my $res = $self->do_obd_cmd('010d');
  if (!@$res) {
    die "No response to mode 01 PID 0x0D to get RPM";
  }

  my $payload = $res->[0]{payload};
  die unless (shift @$payload == 0x41 and
	      shift @$payload == 0x0D);
  return @$payload[0];
}

sub mph {
  return $_[0]->kph * 0.62137119;
}

sub fuel_proportion {
  my ($self) = @_;
  my $res = $_[0]->do_ford_22('16c1');
  use Data::Dump::Streamer;
  Dump $res if $self->{verbose};
  my $n = $res->[0]{payload}[0]*0x100 + $res->[0]{payload}[1];
  printf ("fuel_proportion, n=%04x\n", $n) if $self->{verbose};
  # An almost-full tank is 0x7e97, so clearly the high bit is something else... low-fuel light on?
  my $ret = ($n & 0x7FFF)/0x7FFF;
  return $ret;
}

sub fuel_remaining {
  my ($self, $tank_size) = @_;
  return $self->fuel_proportion*$tank_size;
}

sub do_ford_22 {
  my ($self, $pid) = @_;
  
  my ($pid_high, $pid_low) = map {hex $_} ($pid =~ m/(..)/g);
  if ($self->{headers} ne '10') {
    $self->do_at_cmd('ath1');
    # Priority 7=very low,
    # h 0=three-byte header
    # k 0=IFR required
    # y 1=physical addressing
    # zz 00=node-to-node
    # target 10 = (main) ECU
    # source f1 = scan tool.
    $self->do_at_cmd('at sh e4 10 f1');
    $self->{headers} = '10';
  }

  my $cmd = "22$pid\x0D";

  my $cmd_copy = $cmd;
  $cmd_copy =~ s/([^ -~])/sprintf "\\x{%02x}", ord $1/ge;

  if ($self->{verbose}) {
    print "Outputting to ELM: $cmd_copy";
  }

  syswrite($self->{fh}, $cmd)
    or die "Couldn't output at command $cmd_copy to ELM: $!";

  my $res = '';
  while (1) {
    print "sysreading\n" if $self->{verbose};

    sysread($self->{fh}, $res, 1, length($res))
      or die "Couldn't sysread ELM: $!";

    print "sysread: '$res'\n" if $self->{verbose};

    if ($res =~ m/>$/) {
      my $res_copy = $res;
      $res_copy =~ s/([^ -~])/sprintf "\\x{%02x}", ord $1/ge;

      if ($self->{verbose}) {
	print "Reponse from ELM: $res_copy";
      }
      
      $res =~ s/$cmd// or die "Response to $cmd_copy ($res_copy) didn't begin with echo";
      $res =~ s/[\x0A\x0D]>// or die "Response to $cmd_copy ($res_copy) didn't end with prompt";
      $res =~ s/[\x0A\x0D]/\n/g;
      chomp $res;

      my @lines = grep {$_ ne 'NO DATA'} split /\n/, $res;
      @lines = map {
	my $raw = $_;
	$_ = [map {hex $_} split / /, $_];
	my ($pri_type, $target, $source, @payload) = @$_;
	my ($crc) = pop @payload;

	# jnat_v6_1.pdf, page 27.
	# ppphkyzz
	# 0 is most important, 7 is least important.
	my $priority = $pri_type >> 5;
	# 0: one-byte header, 1: three-byte header ???
	my $h = ($pri_type >> 4) & 1;
	# Is in-frame-response not allowed (0) or required (1).
	my $k = ($pri_type >> 3) & 1;
	# 0: functional addressing, 1: physical addressing.
	my $y = ($pri_type >> 2) & 1;
	# kyzz combined are message type.
	# Msg   KYZZ   Response   Addressing IFR  Message Type/Name
	# Type          (K bit)    (Y bit)  Type
	# 0     0000 Required    Functional  2   Function
	# 1     0001 Required    Functional  1   Broadcast
	# 2     0010 Required    Functional  2   Function Query
	# 3     0011 Required    Functional  3   Function Read
	# 4     0100 Required    Physical    1   Node-to-Node
	# 5     0101 Required    Physical     -  Reserved - MFG
	# 6     0110 Required    Physical     -  Reserved - SAE
	# 7     0111 Required    Physical     -  Reserved - MFG
	# 8     1000 Not Allowed Functional  0   Function Command / Status
	# 9     1001 Not Allowed Functional  0   Function Request / Query
	# 10    1010 Not Allowed Functional  0   Function Ext. Command / Status
	# 11    1011 Not Allowed Functional  0   Function Ext. Request / Query
	# 12    1100 Not Allowed Physical    0   Node-to Node
	# 13    1101 Not Allowed Physical    0   Reserved - MFG
	# 14    1110 Not Allowed Physical    0   Acknowledgement
	# 15    1111 Not Allowed Physical    0   Reserved - MFG
	
	my $z = $pri_type & 0b11;
	my $kyzz = $pri_type & 0b1111;

	my $ret = {
		   priority => $priority,
		   h => $h,
		   k => $k,
		   y => $y,
		   kyzz => $kyzz,
		   target => $target,
		   source => $source,
		   payload => \@payload,
		   crc => $crc,
		   raw => $raw,
		  };

	# Herin lies the Ford 22 specific stuff.
	if ($payload[0] == (0x40|0x22) and
	    $payload[1] == $pid_high and
	    $payload[2] == $pid_low) {
	  $ret->{mode} = 0x22;
	  $ret->{pid} = $pid_high*0x100 + $pid_low;
	  splice(@{$ret->{payload}}, 0, 3, ());
	} elsif ($payload[0] == 0x7f and
		 $payload[1] == 0x22 and
		 $payload[2] == $pid_high and
		 $payload[3] == $pid_low and
		 $payload[4] == 0 and
		 $payload[5] == 0x12) {
	  die "Attempt to do Ford 22 $pid response 'Sub-function not supported, or invalid format'";
	} else {
	  die "Don't know how to handle Ford mode 22 response @payload (decimal)";
	}


	$ret;
      } @lines;

      return \@lines;
    }
  }
}

1;
