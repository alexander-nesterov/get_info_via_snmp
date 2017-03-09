#!/usr/bin/perl -w

#You need to install: 
#cpan install SNMP
#cpan install MIME::Lite
#cpan install HTML::Table
#cpan install JSON


#perl get_info_via_snmp.pl -t template --h smartmontools --o 'Cisco SNMP CPU Usage'
#perl get_info_via_snmp.pl -t group --h smartmontools --o 'Cisco SNMP CPU Usage'
#perl get_info_via_snmp.pl -t group --h '.Templates - ELK' --o 'Cisco SNMP CPU Usage'

use strict;
use warnings;
use SNMP;
use JSON::RPC::Client;
use JSON::XS qw(encode_json decode_json);
use Getopt::Long;
use Data::Dumper;
use MIME::Lite;
use HTML::Table;

#==========================================================================
#Data
#==========================================================================
my %data_oid;

#1
#$data_oid{'description'}{'name'} = 'Description';
#$data_oid{'description'}{'oid'} = 'sysDescr.0';

#2
#$data_oid{'serial_number'}{'name'} = 'Serial Number';
#$data_oid{'serial_number'}{'oid'} = '.1.3.6.1.2.1.47.1.1.1.1.11.1001';

#3
#CISCO-CONFIG-MAN-MIB
#$data_oid{'who_changed'}{'name'} = 'Who changed';
#$data_oid{'who_changed'}{'oid'} = '.1.3.6.1.4.1.9.9.43.1.4.3.0';

#4
#CISCO-CONFIG-MAN-MIB
#$data_oid{'last_change_time'}{'name'} = 'Last change time';
#$data_oid{'last_change_time'}{'oid'} = '.1.3.6.1.4.1.9.9.43.1.4.3.0';


#==========================================================================
#Constants
#==========================================================================
#if 0 - get OID from hash
#if 1 - get OID from zabbix
use constant OID => 1;

#SNMP
use constant SNMP_COMMUNITY	=> 'SNMP_public';
use constant SNMP_VERSION	=> 1;
use constant SNMP_RETRIES	=> '2';
use constant SNMP_REMOTEPORT	=> '161';
use constant SNMP_TIMEOUT	=> '100000'; #in micro-seconds

#ZABBIX
use constant ZABBIX_USER	=> 'Admin';
use constant ZABBIX_PASSWORD	=> 'zabbix';
use constant ZABBIX_SERVER	=> 'zabbix';

#MAIL
use constant MAIL_SERVER	=> 'nsk-mail-01';
use constant MAIL_FROM		=> 'zabbix@cwc.ru';
use constant MAIL_SUBJECT	=> 'Report about network devices';
use constant MAIL_RECIPIENT	=> 'nesterov.a@cwc.ru';

#==========================================================================
#Global variables
#==========================================================================
my $ZABBIX_AUTH_ID;
my $SESSION;

my $WHERE_TYPE;
my $WHERE_HOSTS;
my $TEMPLATE_OID;

#==========================================================================
    main();

#==========================================================================
sub parse_argv
{
	GetOptions ('t=s' => \$WHERE_TYPE, #template or group
	'h=s' => \$WHERE_HOSTS,
    'o=s' => \$TEMPLATE_OID);
}

#==========================================================================
sub zabbix_auth
{
    my %data;

    $data{'jsonrpc'} = '2.0';
    $data{'method'} = 'user.login';
    $data{'params'}{'user'} = ZABBIX_USER;
    $data{'params'}{'password'} = ZABBIX_PASSWORD;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

    if (!defined($response))
    {
	print "Authentication failed, zabbix server: ". ZABBIX_SERVER . "\n";
	return 0;
    }

    $ZABBIX_AUTH_ID = $response->content->{'result'};

    print "Authentication successful. Auth ID: $ZABBIX_AUTH_ID\n";

    undef $response;

    return 1;
}

#==========================================================================
sub zabbix_logout
{
    my %data;

    $data{'jsonrpc'} = '2.0';
    $data{'method'} = 'user.logout';
	$data{'params'} = [];
    $data{'auth'} = $ZABBIX_AUTH_ID;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

    if (!defined($response))
    {
        print "Logout failed, zabbix server: " . ZABBIX_SERVER . "\n";
        return 0;
    }

    print "Logout successful. Auth ID: $ZABBIX_AUTH_ID\n";

    undef $response;
}

#==========================================================================
sub send_to_zabbix
{
    my $json = shift;

    my $response;

    my $url = "http://" . ZABBIX_SERVER . "/api_jsonrpc.php";

    my $client = new JSON::RPC::Client;

    $response = $client->call($url, $json);

    return $response;
}

#==========================================================================
sub zabbix_get_hosts
{
    my ($type, $name) = @_;

    my %data;

    $data{'jsonrpc'} = '2.0';

    if ($type eq 'template')
    {
	$data{'method'} = 'template.get';
	$data{'params'}{'filter'}{'host'} = $name;
    }
    elsif($type eq 'group')
    {
	$data{'method'} = 'hostgroup.get';
	$data{'params'}{'filter'}{'name'} = $name;
    }

    $data{'params'}{'output'} = 'extend';

    #snmp_available
    #0 - disable
    #1 - enable
    #2 - error connecting
    $data{'params'}{'selectHosts'} = ['name', 'host', 'snmp_available'];
    $data{'auth'} = $ZABBIX_AUTH_ID;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

    if (!defined($response))
    {
        print "failed, zabbix server: " . ZABBIX_SERVER . "\n";
        return 0;
    }

    print "$type: $name";

    my @hosts;

    foreach my $result(@{$response->content->{'result'}})
    {
       foreach my $host(@{$result->{'hosts'}})
       {
          push @hosts, $host->{'name'};
       }
    }
	print ", count: " . scalar @hosts . " host(s)\n";
return @hosts;
}

#==========================================================================
sub zabbix_get_oid
{
    my $name = shift;

    my %data;

	#Clear hash if use oid from template
    undef %data_oid;

    $data{'jsonrpc'} = '2.0';
    $data{'method'} = 'template.get';
    $data{'params'}{'output'} = 'extend';
    $data{'params'}{'filter'}{'host'} = $name;
    $data{'params'}{'selectItems'} = ['itemid', 'name', 'key_' , 'snmp_oid'];
    $data{'auth'} = $ZABBIX_AUTH_ID;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

    if (!defined($response))
    {
        print "failed, zabbix server: " . ZABBIX_SERVER . "\n";
        return 0;
    }

    print "template: $name\n";

    my $i = 0;

    foreach my $result(@{$response->content->{'result'}})
    {
       foreach my $item(@{$result->{'items'}})
       {
	    my $item_name = $item->{'name'};
	    my $item_oid = $item->{'snmp_oid'};
	    my $item_key = $item->{'key_'};

	    $data_oid{$item_name}{'oid'} = $item_oid;
	    $data_oid{$item_name}{'key'} = $item_key;

	    $i++;
       }
    }
}

#==========================================================================
sub set_session
{
    my $host = shift;

    $SESSION = new SNMP::Session(
				'DestHost'	=> $host,
				'Version'	=> SNMP_VERSION,
				'Community'	=> SNMP_COMMUNITY,
				'Retries'	=> SNMP_RETRIES,	#default '5'
				'RemotePort'	=> SNMP_REMOTEPORT, 	#default '161'
				'Timeout'	=> SNMP_TIMEOUT 	#default '1000000' micro-seconds before retry
				);

    return $SESSION;
}

#==========================================================================
sub get_data
{
    my $oid = shift;

    my $result = $SESSION->get($oid) or die return "Error - Can't get data";

    return "$result\r\n";
}

#==========================================================================
sub exists_template
{
    my $template = shift;

    my %data;

    $data{'jsonrpc'} = '2.0';
    $data{'method'} = 'template.get';
    $data{'params'}{'output'} = 'extend';
    $data{'params'}{'filter'}{'host'} = [$template];
    $data{'auth'} = $ZABBIX_AUTH_ID;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

    if (scalar keys $response->result == 0)
    {
	print "I don't know about template $template. Check it\n";
	return 0;
    }
    return 1;
}

#==========================================================================
sub exists_group
{
    my $group = shift;

    my %data;

    $data{'jsonrpc'} = '2.0';
    $data{'method'} = 'group.get';
    $data{'params'}{'output'} = 'extend';
    $data{'params'}{'filter'}{'host'} = [$group];
    $data{'auth'} = $ZABBIX_AUTH_ID;
    $data{'id'} = 1;

    my $response = send_to_zabbix(\%data);

    if (scalar keys $response->result == 0)
    {
	print "I don't know about group $group. Check it\n";

	return 0;
    }
    return 1;
}

#==========================================================================
sub create_table
{
    my @hosts = @_;

    my $table = new HTML::Table(-border => 1, -bgcolor => '#fffbf5');

    for (my $host = 0; $host < scalar @hosts; $host++)
    {
	my $session = set_session($hosts[$host]);

	my $row = $table->getTableRows;

	if (defined($session))
	{
	    $table->addRow("Host: $hosts[$host]");
	    $table->setRowBGColor($row+1, '#4ca6ff');

	    foreach my $key (keys %data_oid)
	    {
		my $name;
		my $oid;

		foreach my $value (keys %{$data_oid{$key}})
		{
		    $name = $data_oid{$key}{name};
		    $oid = $data_oid{$key}{oid};
		}

                my $data = get_data($oid);
		$table->addRow($name . $data);
	    }
	}
	else
	{
	    $table->addRow("Host: $hosts[$host] - Session is defined");
	    $table->setRowBGColor($row+1, '#BD0300');
	}
    }

    $SESSION = undef;

    return $table;
}

#==========================================================================
sub create_html
{
    my $table = shift;

    my $html = qq{
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
    <html xmlns="http://www.w2.org/1999/xhtml">
	<head>
	    <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
	    <style type="text/css">
		p {
		    line-height: 1.0;
		}
	    </style>
	</head>
	<body>
	};

    $html .= "Host(s) from: $WHERE_TYPE($WHERE_HOSTS)<br>";
    $html .= "OID(s) from: <br>";

    $html .= $table;

    $html .= qq{
	    <p><b>Report about network devices</b></p>
	    </body>
	    </html>
	};

    return $html;
}

#==========================================================================
sub send_message
{
    my @hosts = @_;

    my $result_table = create_table(@hosts);

    my $body = create_html($result_table);

    my $msg = MIME::Lite->new(
	'From'		=> MAIL_FROM,
	'To'		=> MAIL_RECIPIENT,
	'Subject'	=> MAIL_SUBJECT,
	'Type'		=> 'multipart/related'
    );

    $msg->attach(
	'Type'		=> 'text/html',
	'Data'		=> $body
    );

    eval
    {
	$msg->send('smtp', MAIL_SERVER);
    };

    if ($@)
    {
	print "Error: $@";
    }

    ($msg, $body) = ();
}

#==========================================================================
sub is_empty_hash
{
    if (scalar keys (%data_oid) == 0)
    {
	return 1; #empty
    }

    return 0; #not empty
}

#==========================================================================
sub main
{
    system('clear');

    parse_argv();

	if (!defined $WHERE_TYPE)
    {
	print "You need to set type (template or group), example: perl get_info_via_snmp.pl -t template --h 'smartmontools' --o 'Cisco SNMP CPU Usage'\n";
	print "OR\n";
	print "You need to set type (template or group), example: perl get_info_via_snmp.pl -t group --h 'smartmontools' --o 'Cisco SNMP CPU Usage'\n";
	exit 0;
    }
	
	if ($WHERE_TYPE ne 'template' && $WHERE_TYPE ne 'group')
	{
	 print "I don't know about $WHERE_TYPE. You must use 'template or 'group'\n";
	 exit 0;
	}
	
    if (!defined $WHERE_HOSTS)
    {
	print "You need to set template name or group name, example: perl get_info_via_snmp.pl --h 'smartmontools' --o 'Cisco SNMP CPU Usage'\n";
	exit 0;
    }

	if (!defined $TEMPLATE_OID && scalar keys (%data_oid) == 0)
    {
	print "You need to set template, example: perl get_info_via_snmp.pl -t template --h 'smartmontools' --o 'Cisco SNMP CPU Usage'\n";
	print "OR\n";
	print "Fill hash '%data_oid', example:\n";
	print "\t\t\t\t\$data_oid{'description'}{'name'} = 'Description';\n";
	print "\t\t\t\t\$data_oid{'description'}{'oid'} = 'sysDescr.0';\n";
	exit 0;
    }

    if (zabbix_auth() != 0)
    {
	#Get hosts from the template, $WHERE_TYPE is template
	my @hosts = zabbix_get_hosts($WHERE_TYPE, $WHERE_HOSTS);

	#or
	#Get hosts from the group, $WHERE_TYPE is group
	#my @hosts = zabbix_get_hosts('group', 'NSK.Core.Servers.Web');

	if (scalar @hosts != 0)
	{
            #Get OID from the template 'Cisco SNMP CPU Usage' and then fill the hash %data_oid
	    #zabbix_get_oid('Cisco SNMP CPU Usage') if OID;

	    exists_template($WHERE_HOSTS);
	    #exists_template('12');

	    #0 - not empty, 1 - empty
	    #print is_empty_hash() . "\n";
	    #print Dumper \%data_oid;
	    #create_table(@hosts);
            send_message(@hosts);
	}
	else
	{
	    print "Not found hosts\n";
	}
	zabbix_logout();
    }
}
