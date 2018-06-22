#  Copyright 2018 - present MongoDB, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

use strict;
use warnings;
use Test::More 0.96;
use Test::Fatal;
use Test::Deep qw/!blessed/;

use utf8;
use List::Util 'max';
use Tie::IxHash;

use MongoDB;
use MongoDB::Error;

use lib "t/lib";

use MongoDBTest qw/
    build_client
    skip_unless_mongod
    skip_unless_sessions
    get_test_db
    server_version
    server_type
    clear_testdbs
    get_unique_collection
/;

skip_unless_mongod();
skip_unless_sessions();

my @events;

sub clear_events { @events = () }
sub event_count { scalar @events }
sub event_cb { push @events, $_[0] }

my $conn           = build_client(
    monitoring_callback => \&event_cb,
);
my $testdb         = get_test_db($conn);
my $server_version = server_version($conn);
my $server_type    = server_type($conn);
my $coll           = $testdb->get_collection('test_collection');

$coll->insert_one({}); # do a write so cluster establishes an optime
clear_events();

# Last in First out
subtest 'LIFO Pool' => sub {
    my $session_a = $conn->start_session;
    my $session_b = $conn->start_session;

    # cache the ID's
    my $id_a = $session_a->session_id;
    my $id_b = $session_b->session_id;
    ok defined $id_a->{id}, 'Session A ID defined';
    ok defined $id_b->{id}, 'Session B ID defined';

    $session_a->end_session;
    $session_b->end_session;

    # Internal only check, not part of spec
    is $session_a->_server_session, undef, 'Session A has been returned';
    is $session_b->_server_session, undef, 'Session B has been returned';

    my $session_c = $conn->start_session;
    ok defined $session_c->session_id->{id}, 'Session C ID defined';
    is $session_c->session_id->{id}, $id_b->{id}, 'Session C same ID as Session B';

    my $session_d = $conn->start_session;
    ok defined $session_d->session_id->{id}, 'Session D ID defined';
    is $session_d->session_id->{id}, $id_a->{id}, 'Session D same ID as Session A';
};

subtest 'clusterTime in commands' => sub {

    clear_events();

    subtest 'SDAM' => sub {
        my $local_client = get_high_heartbeat_client();

        $local_client->topology_status( refresh => 1 );

        my $command = $events[0]->{command};
        ok exists $command->{'ismaster'}, 'ismaster in sent command';

        # first ismaster to unknown hosts won't have it
        ok !exists $command->{'$clusterTime'}, 'clusterTime in sent command';

        # find max time among replies
        my $max_cluster_time = max(
            map  { $_->{reply}{'$clusterTime'}{clusterTime} }
            grep { $_->{type} eq 'command_succeeded' } @events
        );

        clear_events();

        $local_client->topology_status( refresh => 1 );

        my $command2 = $events[0]->{command};

        # next ismaster to known hosts should have $clustertime
        ok exists $command2->{'ismaster'}, 'ismater in sent command'
          or diag explain $command2;

        my $got = $command2->{'$clusterTime'}->{clusterTime};
        ok( $got == $max_cluster_time, "clusterTime matches" )
          or diag "GOT:\n", explain $got, "\nEXPECTED:\n", explain $max_cluster_time;
    };

    clear_events();

    subtest 'ping' => sub {
        my $local_client = get_high_heartbeat_client();

        my $ping_result = $local_client->send_admin_command(Tie::IxHash->new('ping' => 1));

        my $command = $events[-2]->{ command };
        my $result = $events[-1]->{ reply };

        ok exists $command->{'ping'}, 'ping in sent command';

        ok exists $command->{'$clusterTime'}, 'clusterTime in sent command';

        my $ping_result2 = $local_client->send_admin_command(Tie::IxHash->new('ping' => 1));

        my $command2 = $events[-2]->{ command };

        ok $command2->{'$clusterTime'}->{clusterTime}
          == $result->{'$clusterTime'}->{clusterTime},
           "clusterTime matches";
    };

    clear_events();

    subtest 'aggregate' => sub {
        my $local_client = get_high_heartbeat_client();
        my $local_db = get_test_db($local_client);
        my $local_coll = get_unique_collection($local_db, 'cluster_agg');

        $local_coll->insert_many( [ { wanted => 1, score => 56 },
                              { wanted => 1, score => 72 },
                              { wanted => 1, score => 96 },
                              { wanted => 1, score => 32 },
                              { wanted => 1, score => 61 },
                              { wanted => 1, score => 33 },
                              { wanted => 0, score => 1000 } ] );

        my $agg_result = $local_coll->aggregate( [
            { '$match'   => { wanted => 1 } },
            { '$group'   => { _id => 1, 'avgScore' => { '$avg' => '$score' } } }
        ] );

        my $command = $events[-2]->{ command };
        my $result = $events[-1]->{ reply };

        ok exists $command->{'aggregate'}, 'aggregate in sent command';

        ok exists $command->{'$clusterTime'}, 'clusterTime in sent command';

        my $agg_result2 = $local_coll->aggregate( [ { '$match'   => { wanted => 1 } },
            { '$group'   => { _id => 1, 'avgScore' => { '$avg' => '$score' } } } ] );

        my $command2 = $events[-2]->{ command };

        ok $command2->{'$clusterTime'}->{clusterTime}
          == $result->{'$clusterTime'}->{clusterTime},
           "clusterTime matches";
    };

    clear_events();

    subtest 'find' => sub {
        my $local_client = get_high_heartbeat_client();
        my $local_db = get_test_db($local_client);
        my $local_coll = get_unique_collection($local_db, 'cluster_find');

        $local_coll->insert_one({_id => 1});

        # need to actually call ->result to make it touch the database, and
        # explain 1 to get it to show the whole returned result
        my $find_result = $local_coll->find({_id => 1})->result;

        my $command = $events[-2]->{ command };
        my $result = $events[-1]->{ reply };

        ok exists $command->{'find'}, 'find in sent command';

        ok exists $command->{'$clusterTime'}, 'clusterTime in sent command';

        my $find_result2 = $local_coll->find({_id => 1})->result;

        my $command2 = $events[-2]->{ command };

        ok $command2->{'$clusterTime'}->{clusterTime}
          == $result->{'$clusterTime'}->{clusterTime},
           "clusterTime matches";
    };

    clear_events();

    subtest 'insert_one' => sub {
        my $local_client = get_high_heartbeat_client();
        my $local_db = get_test_db($local_client);
        my $local_coll = get_unique_collection($local_db, 'cluster_find');

        my $insert_result = $local_coll->insert_one({_id => 1});

        my $command = $events[-2]->{ command };
        my $result = $events[-1]->{ reply };

        ok exists $command->{'insert'}, 'insert in sent command';

        ok exists $command->{'$clusterTime'}, 'clusterTime in sent command';

        my $insert_result2 = $local_coll->insert_one({_id => 2});

        my $command2 = $events[-2]->{ command };

        ok $command2->{'$clusterTime'}->{clusterTime}
          == $result->{'$clusterTime'}->{clusterTime},
           "clusterTime matches";
    };
};

sub get_high_heartbeat_client {
    my $local_client = build_client(
        # You want big number? we give you big number
        heartbeat_frequency_ms => 9_000_000_000,
        monitoring_callback => \&event_cb,
    );

    return $local_client;
}

subtest 'correct session for client' => sub {
    my $client1 = build_client();
    my $client2 = build_client();

    ok $client1->_id ne $client2->_id, 'client id is different';

    my $db1 = get_test_db($client1);
    my $coll1 = get_unique_collection($db1, 'cross_session');

    my $session = $client2->start_session;

    subtest 'collection sessions' => sub {
        test_collection_session_exceptions(
            $coll1,
            $session,
            qr/session from another client/i,
            "Session from another client fails (%s)",
        );
    };

    subtest 'database sessions' => sub {
        test_db_session_exceptions(
            $db1,
            $session,
            qr/session from another client/i,
            "Session from another client fails (%s)",
        );
    };
};

subtest 'ended session unusable' => sub {
    my $client1 = build_client();
    my $db1 = get_test_db($client1);
    my $coll1 = get_unique_collection($db1, 'end_session');

    my $session = $client1->start_session;
    $session->end_session;

    subtest 'collection sessions' => sub {
        test_collection_session_exceptions(
            $coll1,
            $session,
            qr/session which has ended/i,
            "Ended session is unusable (%s)",
        );
    };

    subtest 'database sessions' => sub {
        test_db_session_exceptions(
            $db1,
            $session,
            qr/session which has ended/i,
            "Ended session is unusable (%s)",
        );
    };
};

sub test_collection_session_exceptions {
    my ( $coll, $session, $error_regex, $message_string )  = @_;

    # Done in order of listings in METHODS in pod

    # indexes?

    like
        exception { $coll->insert_one( { _id => 1 }, { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'insert_one' );

    like
        exception { $coll->insert_many( [
            { _id => 1 },
            { _id => 2 },
            { _id => 3 },
            { _id => 4 },
          ], { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'insert_many' );

    like
        exception { $coll->delete_one(
                        { _id => 1 },
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'delete_one' );

    like
        exception { $coll->delete_many(
                        { _id => { '$in' => [1,2,3,4] } },
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'delete_many' );

    like
        exception { $coll->replace_one(
                        { _id => 1 },
                        { _id => 1, foo => 'qux' },
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'replace_one' );

    like
        exception { $coll->update_one(
                        { _id => 1 },
                        { '$set' => { foo => 'qux' } },
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'update_one' );

    like
        exception { $coll->update_many(
                        { _id => { '$in' => [1,2,3,4] } },
                        { '$set' => { foo => 'qux' } },
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'update_many' );

    # Must call result to get it to touch the database
    like
        exception { $coll->find(
                        { _id => { '$in' => [1,2,3,4] } },
                        { session => $session }
                      )->result },
        $error_regex,
        sprintf( $message_string, 'find' );

    like
        exception { $coll->find_one(
                        { _id => 1 },
                        {},
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'find_one' );

    like
        exception { $coll->find_id(
                        1,
                        {},
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'find_id' );

    like
        exception { $coll->find_one_and_delete(
                        { _id => 1 },
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'find_one_and_delete' );

    like
        exception { $coll->find_one_and_replace(
                        { _id => 1 },
                        { _id => 1, foo => 'qux' },
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'find_one_and_replace' );

    like
        exception { $coll->find_one_and_update(
                        { _id => 1 },
                        { '$set' => { foo => 'qux' } },
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'find_one_and_update' );

    like
        exception { $coll->aggregate(
                        [
                          { '$match'   => { wanted => 1 } },
                          { '$group'   => { _id => 1, 'avgScore' => { '$avg' => '$score' } } }
                        ],
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'aggregate' );

    like
        exception { $coll->count_documents(
                        { _id => 1 },
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'count' );

    like
        exception { $coll->distinct(
                        "id_",
                        { _id => 1 },
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'distinct' );

    like
        exception { $coll->rename(
                        "another_collection_name",
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'rename' );

    like
        exception { $coll->drop(
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'drop' );

    like
        exception {
            my $bulk = $coll->ordered_bulk;
            $bulk->insert_one( { _id => 1 } );
            $bulk->insert_one( { _id => 2 } );
            $bulk->execute( undef, { session => $session } );
        },
        $error_regex,
        sprintf( $message_string, 'ordered_bulk' );

    like
        exception {
            my $bulk = $coll->unordered_bulk;
            $bulk->insert_one( { _id => 1 } );
            $bulk->insert_one( { _id => 2 } );
            $bulk->execute( undef, { session => $session } );
        },
        $error_regex,
        sprintf( $message_string, 'unordered_bulk' );

    like
        exception { $coll->bulk_write(
                        [
                            insert_one => [ { _id => 1 } ],
                            insert_one => [ { _id => 2 } ],
                        ],
                        { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'bulk_write' );
}

sub test_db_session_exceptions {
    my ( $db, $session, $error_regex, $message_string )  = @_;

    like
        exception { $db->list_collections( {}, { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'list_collections' );

    like
        exception { $db->collection_names( {}, { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'collection_names' );

    # get_collection makes no sense and I dont think ontacts the database until later
    # same for get_gridfsbucket ?

    like
        exception { $db->drop( { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'drop' );

    like
        exception { $db->run_command( [ is_master => 1 ], undef, { session => $session } ) },
        $error_regex,
        sprintf( $message_string, 'run_command' );
}

clear_testdbs;

done_testing;
