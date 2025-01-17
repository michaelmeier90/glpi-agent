package GLPI::Agent::Task::Inventory::Generic::Databases::MongoDB;

use English qw(-no_match_vars);

use strict;
use warnings;

use parent 'GLPI::Agent::Task::Inventory::Generic::Databases';

use Cpanel::JSON::XS;
use English qw(-no_match_vars);
use POSIX qw(strftime);

use GLPI::Agent::Tools;
use GLPI::Agent::Inventory::DatabaseService;

sub isEnabled {
    return canRun('mongo') || canRun('mongosh');
}

sub doInventory {
    my (%params) = @_;

    my $inventory = $params{inventory};

    # Try to retrieve credentials updating params
    GLPI::Agent::Task::Inventory::Generic::Databases::_credentials(\%params, "mongodb");

    my $dbservices = _getDatabaseService(%params);

    foreach my $dbs (@{$dbservices}) {
        $inventory->addEntry(
            section => 'DATABASES_SERVICES',
            entry   => $dbs->entry(),
        );
    }
}

sub _getDatabaseService {
    my (%params) = @_;

    my $credentials = delete $params{credentials};
    return [] unless $credentials && ref($credentials) eq 'ARRAY';

    my @dbs = ();

    $params{mongosh} = canRun('mongosh') ? 1 : 0
        unless defined($params{mongosh}); # Needed for tests

    foreach my $credential (@{$credentials}) {
        GLPI::Agent::Task::Inventory::Generic::Databases::trying_credentials($params{logger}, $credential);
        my $rcfile = _mongoRcFile($credential);
        $params{rcfile} = $rcfile->filename if $rcfile;

        # Keep port as we need it to set --port option
        $params{port} = $credential->{port} if $credential->{port};

        my ($name, $manufacturer) = qw(MongoDB MongoDB);
        my $version = _runSql(
            sql     => "db.version()",
            nodb    => 1,
            %params
        )
            or next;

        if ($version =~ /W NETWORK.*reason: Connection refused/m) {
            $params{logger}->error("Connection failure on "._connectUrl($credential));
            next;
        }

        my $dbs_size = 0;
        my $lastbootmilli = _runSql(
            sql => "ISODate().getTime()-db.serverStatus().uptimeMillis",
            %params
        );
        my $lastboot;
        $lastboot = strftime("%Y-%m-%d %H:%M:%S", gmtime(int($lastbootmilli/1000)))
            if $lastbootmilli && $lastbootmilli =~ /^\d+$/;

        my $dbs = GLPI::Agent::Inventory::DatabaseService->new(
            type            => "mongodb",
            name            => $name,
            version         => $version,
            manufacturer    => $manufacturer,
            port            => $credential->{port} // 27017,
            is_active       => 1,
            last_boot_date  => $lastboot,
        );

        my @databases;
        my $databases = join('', _runSql(
            sql => "db.adminCommand( { listDatabases: 1 } ).databases",
            stringify => $params{mongosh},
            %params
        ));
        if (!$databases) {
            if ($params{logger}) {
                my ($code, $codename);
                my $listdatabases = join('', _runSql(
                    sql => "db.adminCommand( { listDatabases: 1 } )",
                    stringify => $params{mongosh},
                    %params
                ));
                if ($listdatabases) {
                    $params{logger}->debug2("database list command server answer: $listdatabases");
                    eval {
                        my $json = decode_json($listdatabases);
                        $code = $json->{code};
                        $codename = $json->{codeName};
                    };
                    if ($EVAL_ERROR || !$code) {
                        $params{logger}->debug("Failed to analyse mongodb database list command answer");
                    } else {
                        $params{logger}->error("Failure on mongodb database list command: $codename (errcode=$code)");
                    }
                } else {
                    $params{logger}->error("No answer to mongodb database list command");
                }
            }
        } else {
            eval {
                @databases = grep { ref($_) eq 'HASH' } @{ decode_json($databases) };
            };
            if ($EVAL_ERROR) {
                $params{logger}->error("Can't decode mongodb database list: ".($databases =~ /^{/ ? $EVAL_ERROR : $databases))
                    if $params{logger};
            }

            foreach my $dbinfo (@databases) {
                my $db = $dbinfo->{name}
                    or next;
                my $size = $dbinfo->{sizeOnDisk}
                    or next;

                if ($size) {
                    $dbs_size += $size;
                    $size = getCanonicalSize("$size bytes", 1024);
                } else {
                    undef $size;
                }

                my $status = _runSql(
                    sql => "db = new Mongo().getDB('$db');db.runCommand('ping').ok",
                    %params
                );

                $dbs->addDatabase(
                    name            => $db,
                    size            => $size,
                    is_active       => $status,
                );
            }
        }

        $dbs->size(getCanonicalSize("$dbs_size bytes", 1024));

        push @dbs, $dbs;

        # Always forget rcfile and port
        delete $params{rcfile};
        delete $params{port};
    }

    return \@dbs;
}

sub _date {
    my ($date) = @_
        or return;
    $date =~ /^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})/;
    return $1;
}

sub _runSql {
    my (%params) = @_;

    my $sql = delete $params{sql}
        or return;

    my $nodb = delete $params{norc};
    my $rcfile = delete $params{rcfile};
    my $command = "mongo";
    $command .= "sh" if $params{mongosh};
    $command .= " --port $params{port}" if $params{port};
    $command .= " --quiet";
    $command .= " --nodb" if $nodb;
    $command .= " --norc $rcfile" if $rcfile;
    # Mongosh must be instructed to output JSON like mongo does before
    $sql = "EJSON.stringify($sql)" if $params{stringify};
    $command .= " --eval \"$sql\"";

    # Only to support unittests
    if ($params{file}) {
        $sql =~ s/[ .]+/-/g;
        $sql =~ s/[^-_0-9A-Za-z]//g;
        $sql =~ s/[-][-]+/-/g;
        $params{file} .= "-" . lc($sql);
        unless ($params{istest}) {
            print STDERR "\nGenerating $params{file} for new MongoDB test case...\n";
            system("$command >$params{file}");
        }
    } else {
        $params{command} = $command;
    }

    if (wantarray) {
        return map { chomp; $_ } getAllLines(%params);
    } else {
        my $result  = getFirstLine(%params);
        return unless defined($result);
        chomp($result);
        return $result;
    }
}

sub _connectUrl {
    my ($credential) = @_;

    my $conn = $credential->{host} // "localhost";
    $conn .= ":".($credential->{port} // "27017");

    return $conn;
}

sub _mongoRcFile {
    my ($credential) = @_;

    return unless $credential->{type};

    my $fh;
    if ($credential->{type} eq "login_password") {
        File::Temp->require();

        $fh = File::Temp->new(
            TEMPLATE    => 'mongorc-XXXXXX',
            SUFFIX      => '.js',
        );
        my $conn = _connectUrl($credential);
        print $fh 'conn = new Mongo("'.$conn.'");', "\n";
        $conn = $credential->{socket} if $credential->{socket};
        print $fh 'db = connect("'.$conn.'");', "\n";
        if ($credential->{login} && $credential->{password}) {
            my $password = $credential->{password};
            $password =~ s/'/\\'/g;
            print $fh "db.auth({\n";
            print $fh "    user: '$credential->{login}',\n";
            print $fh "    pwd: '$password',\n";
            print $fh "});\n";
        }
        close($fh);
    }

    # Temp file must be deleted out of caller scope
    return $fh;
}

1;
