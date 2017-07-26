#!/usr/bin/perl

package MYAVAIL;

use strict;
use CGI();
use URI::Escape();
use XML::Simple qw(:strict);
use IPC::System::Simple qw( capturex );
use Data::Dumper;
use Time::Piece();
use Time::Seconds;
use Time::Local();
use CGI();
use POSIX();

# load runtime config
use FindBin qw($Bin);
require "$Bin/config.pl";

# package globals reset for each request
our ($q, %USERS);

################################################
# utils
################################################

sub dumpit {
  my ($it) = @_;
  if (ref($it)) {
    local $Data::Dumper::Indent=2;
    local $Data::Dumper::Sortkeys=1;
    $it = Dumper($it);
    $it =~ s/^\$VAR1\s*\=\s*//;
  }
  return $it;
}

sub encrypt {
  local $ENV{DATA} = $_[0];
  my $x = `echo \$DATA | openssl enc -aes-128-cbc -a -salt -pass env:MYAVAIL_VAULT_PASS`;
  chomp $x;
  return $x;
}
sub decrypt {
  local $ENV{DATA} = $_[0];
  my $x = `echo \$DATA | openssl enc -aes-128-cbc -a -d -salt -pass env:MYAVAIL_VAULT_PASS`;
  chomp $x;
  return $x;
}

sub escape_html { CGI::escapeHTML(@_); }
sub escape_xml { return CGI::escapeHTML(@_); }
sub escape_uri { URI::Escape::uri_escape(@_); }

# force scalar param return
sub param { return scalar($q->param(@_)); }


# return an http header
sub http_header {
  my %opts = @_;
  $opts{-Cache_Control} ||= 'no-store, no-cache, must-revalidate, post-check=0, pre-check=0';
  return CGI::header(%opts);
}

# returns { '2015-03-31' => [[1400,1500],..], .. }
sub get_calendar {
  my %opts = @_;
  my $startDate = Time::Piece->strptime(Time::Piece->new()->ymd,'%Y-%m-%d');
  my $endDate = $startDate + (60 * 60 * 24 * 7 * $opts{weeks});

  my $request_xml = '<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
  <soap:Body>
    <FindItem Traversal="Shallow" xmlns="http://schemas.microsoft.com/exchange/services/2006/messages">
      <ItemShape>
        <t:BaseShape>Default</t:BaseShape>
        <t:AdditionalProperties>
          <t:FieldURI FieldURI="calendar:MyResponseType"/>
        </t:AdditionalProperties>
      </ItemShape>
      <CalendarView MaxEntriesReturned="'.$opts{maxEntries}.'" StartDate="'.escape_xml($startDate->datetime()).'" EndDate="'.escape_xml($endDate->datetime()).'"/>
      <ParentFolderIds>
        <t:DistinguishedFolderId Id="calendar"/>
      </ParentFolderIds>
    </FindItem>
  </soap:Body>
</soap:Envelope>';

#  print STDERR "request_xml: $request_xml\n";

  my $response_xml = capturex(
    'curl','-s',
    '-u', $opts{user}.':'.decrypt($opts{pass}),
    '-L', $opts{server}, "-d", $request_xml,
    '-H', 'Content-Type:text/xml', "--ntlm");

#  print STDERR "response_xml: $response_xml\n";

  my $dat;
  eval {
    $dat = XMLin($response_xml, ForceArray => 0, KeyAttr => []);
  };
  if ($@) {
    print STDERR "could not parse XML\nREQUEST_XML: $request_xml\n\nRESPONSE_XML: $response_xml\n\n";
    die $@;
  }

  my $recs = $$dat{'s:Body'}{'m:FindItemResponse'}{'m:ResponseMessages'}{'m:FindItemResponseMessage'}{'m:RootFolder'}{'t:Items'}{'t:CalendarItem'} || [];

  # 't:Subject' => 'lunch',
  # 't:End' => '2015-03-09T16:30:00Z',
  # 't:LegacyFreeBusyStatus' => 'Busy',
  # 't:Start' => '2015-03-09T16:30:00Z'

  my %calendar; # (localdate_yyyy-mm-dd => [[starttime-hhmi,endtime-hhmi], ..], ..)

  foreach my $rec (@$recs) {
    next if $$rec{'t:LegacyFreeBusyStatus'} eq 'Free';

    my $start = gmtime2localtime(Time::Piece->strptime($$rec{'t:Start'}, '%Y-%m-%dT%H:%M:%SZ'));
    my $end =   gmtime2localtime(Time::Piece->strptime($$rec{'t:End'},   '%Y-%m-%dT%H:%M:%SZ'));

    # add event to each date from start to end
    my $d = $start;
    while ($d <= $end) {
      my $startMin;

      # if day is start date use start min, otherwise 0
      if ($d->ymd eq $start->ymd) {
        $startMin = ($start->hour * 60) + $start->min;
      } else {
        $startMin = 0;
      }

      # if day is end date use end min, otherwise 24 hours * 60 min in hour
      my $endMin;
      if ($d->ymd eq $end->ymd) {
        $endMin = ($end->hour * 60) + $end->min;
      } else {
        $endMin = 24 * 60;
      }
 
      my $events = $calendar{$d->ymd} ||= [];
      push @$events, [$startMin, $endMin];
      $d += ONE_DAY;
    }
  }

  return \%calendar;
}

sub gmtime2localtime {
  my ($t) = @_;
  my $epoch = Time::Local::timegm($t->sec, $t->min, $t->hour, $t->mday, $t->_mon, $t->year);
  return Time::Piece->new($epoch);
}

sub get_freetime {
  my %opts = @_;
  my $calendar = $opts{calendar} || get_calendar(%opts);
  my %freetimes;

  # look for available time on the 15 min interval
  my $dayStart = $opts{dayStart} || '08:00';
  my $dayEnd = $opts{dayEnd} || '17:00';
  my $intervalSec = ($opts{intervalBlockMin} || 15) * 60;
  my $smallestBlock = $opts{smallestBlockMin} || 45;

  my $currentDay = Time::Piece->strptime(Time::Piece->new()->ymd,'%Y-%m-%d');
  my $endDate = $currentDay + (60 * 60 * 24 * 7 * $opts{weeks});

  my $now = Time::Piece->new();

  while ($currentDay < $endDate) {
    my $timeSlice = Time::Piece->strptime($currentDay->ymd.'T'.$dayStart,'%Y-%m-%dT%H:%M');
    my $endOfDay  = Time::Piece->strptime($currentDay->ymd.'T'.$dayEnd,  '%Y-%m-%dT%H:%M');

    my $freeStart;
    while ($timeSlice < $endOfDay) {
      if ($now < $timeSlice) {
        my $events = $$calendar{$currentDay->ymd} ||= [];

        # are the next 15 minutes available?
        my $is_avail = 1;
        my $timeSliceMin = ($timeSlice->hour * 60) + $timeSlice->min;

        foreach my $e (@$events) {
          # if slice is before event or after event, slice is free
          if (($timeSliceMin + 15) <= $$e[0] || ($timeSliceMin >= $$e[1])) {
            # time slice is not in conflict
          } else {
            $is_avail = 0;  
            last;
          }
        }

        if ($is_avail) {
          $freeStart ||= $timeSlice;
        } elsif ($freeStart) {
          my $minAvail = ($timeSlice - $freeStart) / 60;
          if ($minAvail >= $smallestBlock) {
            $freetimes{$freeStart->ymd} ||= []; 
            push @{ $freetimes{$freeStart->ymd} }, [$freeStart, $timeSlice];
          }
          $freeStart=undef;
        }
      }

      $timeSlice += $intervalSec;
    }

    # include any free time found at the end of the day
    if ($freeStart) {
      my $minAvail = ($endOfDay - $freeStart) / 60;
      if ($minAvail >= $smallestBlock) {
        $freetimes{$freeStart->ymd} ||= []; 
        push @{ $freetimes{$freeStart->ymd} }, [$freeStart, $timeSlice];
      }
    }
    
    $currentDay += ONE_DAY;
  }

  return \%freetimes;
}


sub get_html_list {
  my %opts = @_;
  my $free_blocks = get_freetime(%opts);

  my $timezone = POSIX::strftime("%Z", localtime());

  my $buf = '
<html>
<head>
<title>'.escape_html($opts{title}).'</title>
<style>
body {
  font-family: sans-serif;
  margin: 0;
}
h2 {
  background-color: #ccc;
  color: #666;
  padding: 10px;
  margin: 10px 0;
}
h3 {
  margin: 0 0 4px 0;
}
.day {
  padding: 10px;
}
.day + .day {
  border-top: 1px solid #ccc; 
}
.times {
  color: #444;
}
#top {
  margin-left: 10px;
}
</style>
</head>
<body>
<div id=top>
<h1>'.escape_html($opts{title}).'</h1>
<strong>All times in '.escape_html($timezone).' timezone.</strong>
<p>
'.$opts{message}.'
</div>';
  my $lastmonth;
  
  foreach my $day (sort keys (%$free_blocks)) {
    my $d = $$free_blocks{$day}[0][0];
    next if index($opts{showdays}, $d->wday)==-1;

    if ($lastmonth ne $d->monname) {
      $buf .= "<h2>".escape_html($d->fullmonth)."</h2>\n";
      $lastmonth = $d->monname;
    }


    my @times;
    foreach my $availblock (@{ $$free_blocks{$day} }) {
      my $t0 = $$availblock[0];
      $t0 = $t0->strftime("%I:%M%P");
      $t0 =~ s/^0//;

      my $t1 = $$availblock[1];
      $t1 = $t1->strftime("%I:%M%P");
      $t1 =~ s/^0//;

      push @times, "$t0-$t1";
    }

    my $day = $d->strftime("%d");
    $day =~ s/^0//;
    $buf .= '<div class=day><h3>'.$d->wdayname.' '.$day."</h3><span class=times>".join(', ', @times)."</span></div>\n";
  }

  $buf .= '</body></html>';
  return $buf;
}


################################################
# page content actions (must have act_ prefix)
################################################
sub handler {
  local $q = new CGI();


  my $act = __PACKAGE__->can('act_'.param('act')) || \&act_showavail;
  $act = \&error_vault if $ENV{MYAVAIL_VAULT_PASS} eq '';
  $act->();
}

sub error_vault {
  print http_header(), "Vault password is not configured";
}

sub act_add {
  my $buf = 
'<html>
<head>
<style>
body {
  font-family: sans-serif;
}
input,textarea {
  width: 30em;
  padding: 6px;
  color: blue;
  border-radius: 6px;
  border: 1px solid #ccc;
}
textarea {
  height: 6em;
}
label {
  font-weight: bold;
  color: #444;
}
fieldset {
  border: 1px solid #ccc;
  border-radius: 10px;
}
legend {
  color: #666;
}

</style>
</head>
<body>
<h1>Add User</h1>
<form method=post>

<p><label>page title<br><input type=text name=title value="My Availability"></label>
<p><label>name<br><input type=text name=name></label>
<p><label>HTML message<br><textarea name=message>Email <a href=mailto:a@b.com>a@b.com</a> to suggest a time to meet.</textarea></label>
<p><label>day start<br><input type=text name=dayStart required placeholder="08:00" value="08:00"></label>
<p><label>day end<br><input type=text name=dayEnd required placeholder="17:00" value="17:00"></label>
<p><label>show weeks<br><input type=text name=weeks value=24 required placeholder=24></label>

<fieldset>
  <legend>exchange server</legend>
  <p><label>url<br><input type=text name=server required value="https://exchange.unh.edu/ews/exchange.asmx">
  <p><label>username<br><input type=text name=user required></label>
  <p><label>password<br><input type=password name=pass required></label>
</fieldset>

<p><button type=submit name=act value=showaddconfig>submit</button>
</form>
</body>
</html>';
    print http_header(), $buf;
}

sub act_showaddconfig {
  my %c;
  $c{$_} = param($_) for (qw( title name user message dayStart dayEnd server weeks ));
  $c{pass} = encrypt(param('pass'));
  my $buf = '
<pre>
Add the following config to myavail/config.pl

$MYAVAIL::USERS{\''.$c{user}.'\'} = '.dumpit(\%c).'
</pre>

<p>
<a href="?">back</a>
';
  print http_header(), $buf;
}

sub act_showavail {
  my $user = param('user');

  if (! $user || ref($USERS{$user}) ne 'HASH') {
    my $buf = "<html><body><h1>Select a user</h1><ul>\n";
    my @users;
    foreach my $u (sort keys %USERS) {
      my $name = $USERS{$u}{name} || $USERS{$u}{user} || $u;
      $buf .= "<li><a href='?user=".escape_uri($u)."'>".escape_html($name)."</a>\n";
    }
    $buf .= "</ul><a href='?act=add'>add user</a></body></html>";
    print http_header(), $buf;
  }

  else {
    my %opts = %{ $USERS{$user} };
    $opts{user} ||= $user;
    $opts{name} ||= $user;
    my $timezone = POSIX::strftime("%Z", localtime());
    $opts{title} ||= "$user Availability ($timezone)";
    $opts{message} ||= 'Send me an email to suggest a time to meet.';
    $opts{dayStart} ||= '08:00';
    $opts{dayEnd} ||= '17:00';
    $opts{intervalBlockMin} ||= 15;
    $opts{smallestBlockMin} ||= 45;
    $opts{maxEntries} ||= 5000;
    $opts{server} ||= 'https://exchange.unh.edu/ews/exchange.asmx';
    $opts{weeks} ||= 12;
    $opts{showdays} ||= '23456'; # (Sun=1, Sat=7)
    print http_header(), get_html_list(%opts);
  }
}

handler() unless caller;
1;
