#${PMpre} CAF::Kerberos${PMpost}

use parent qw(CAF::Object);
use Readonly;
use CAF::Object qw (SUCCESS);
use CAF::Process;
use LC::Exception;
use File::Temp qw(tempdir);
use File::Path qw(rmtree);

use GSSAPI;

our $_EC = LC::Exception::Context->new()->will_store_errors();

# Interfaces for the following methods of each class will be generated.
Readonly::Hash our %GSSAPI_INTERFACE_WRAPPER => {
    Context => [qw(accept init valid_time_left wrap unwrap)],
    Name => [qw(display import)],
    Cred => [qw(acquire_cred inquire_cred)],
};

Readonly my $KRB5ENV_CCNAME => 'KRB5CCNAME';
Readonly my $KRB5CCDIR_TEMPLATE => '/tmp/CAF-Kerberos-XXXXXX';

# The default server keytab (also to be used as client keytab)
Readonly my $DEFAULT_SERVER_KEYTAB => '/etc/krb5.keytab';
Readonly my $KRB5ENV_SERVER_KEYTAB => 'KRB5_KTNAME';
Readonly my $KRB5ENV_CLIENT_KEYTAB => 'KRB5_CLIENT_KTNAME';

#
# kinit is not required at all, just provided for convenience
#
# TODO: set as rpm requirement?
Readonly my $KINIT_DEFAULT => '/usr/bin/kinit';

# Module variable holding the location of the kinit binary
# Shouldn't be changed, and if so, should be system wide setting,
# so a module variable is fine.
# TODO: add function to change it?
my $kinit_bin = $KINIT_DEFAULT;

# Terminology: http://web.mit.edu/kerberos/krb5-1.4/krb5-1.4.3/doc/krb5-user/Kerberos-Glossary.html
#    ticket: A temporary set of electronic credentials that verify
#            the identity of a client for a particular service.
#    principal: The principal name or principal is the unique name
#               of a user or service allowed to authenticate using Kerberos.
#               A principal name follows the form primary[/instance]@REALM.

=head1 NAME

CAF::Kerberos - Class for Kerberos handling using L<GSSAPI>.

=head1 DESCRIPTION

This class handles Kerberos tickets and some
utitlities like kerberos en/decryption.

To create a new ticket for principal C<SERVICE/host@REALM>
(using default (server) keytab for the TGT), you can use

    my $krb = CAF::Kerberos->new(
        principal => 'SERVICE/host@REALM',
        log => $self,
    );
    return if(! defined($krb->get_context()));

    # set environment to temporary credential cache
    # temporary cache is cleaned-up during destroy of $krb
    local %ENV = %ENV;
    $krb->update_env(\%ENV);

=cut

=head2 Methods

=over

=item C<_initialize>

Initialize the kerberos object. Arguments:

Optional arguments

=over

=item C<log>

A C<CAF::Reporter> object to log to.

=item lifetime, keytab

Ticket lifetime and keytab are passed to C<update_ticket_options> method.

=item primary, instances, realm, principal

Principal primary, instances, realm and principal are passed to C<update_principal> method.

=back

=cut

sub _initialize
{
    my ($self, %opts) = @_;

    # A hashref to store any environment variables to set
    # NAME = undef means unset NAME
    $self->{ENV} = {};

    $self->{ticket} = {
        keytab => $DEFAULT_SERVER_KEYTAB, # set the default server keytab as keytab
    };
    my %t_opts = map {$_ => $opts{$_}} grep {defined($opts{$_})} qw(lifetime keytab);
    $self->update_ticket_options(%t_opts);

    # The principal attribute is a hashref with the components,
    # it is not the principal string
    $self->{principal} = {};
    my %p_opts = map {$_ => $opts{$_}} grep {defined($opts{$_})} qw(primary instances realm principal);
    $self->update_principal(%p_opts);

    # ccdir: the credential cache directory (mainly kept around for cleanup)
    $self->{ccdir} = undef;

    $self->{log} = $opts{log} if $opts{log};

    return SUCCESS;
}

=item update_ticket_options

Update ticket details using optional named arguments
(and set the keytab ENV attributes).

=over

=item lifetime

Requested lifetime. (There is no verification if the actual lifetime is
this long).

=item keytab

Set the keytab to use to create the TGT.

=back

=cut

sub update_ticket_options
{

    my ($self, %opts) = @_;

    # use defined, can be 0?
    if (defined($opts{lifetime})) {
        $self->{ticket}->{lifetime} = $opts{lifetime} ;
        $self->verbose("update_ticket_options lifetime $self->{ticket}->{lifetime}");
    }
    if (exists($opts{keytab})) {
        $self->{ticket}->{keytab} = $opts{keytab};
        $self->verbose("update_ticket_options keytab ", $self->{ticket}->{keytab});
    }

    # Set the keytab environment variables
    if(exists($self->{ticket}->{keytab})) {
        # Set both client and server keytab
        $self->{ENV}->{$KRB5ENV_SERVER_KEYTAB} = $self->{ticket}->{keytab};
        $self->{ENV}->{$KRB5ENV_CLIENT_KEYTAB} = $self->{ticket}->{keytab};
        $self->verbose("set keytab ENV attributes ",
                       "$KRB5ENV_SERVER_KEYTAB and $KRB5ENV_CLIENT_KEYTAB to ",
                       $self->{ticket}->{keytab});
    }

    return SUCCESS;
};

=item update_principal

Set the principal details (primary, instances and/or realm)
using following optional named arguments

=over

=item primary

The primary component (i.e. username or service) (cannot be empty string).

=item instances

Array reference with instances for the principal

=item realm

The realm.

=item principal

The principal string, will be split in above components.
Any individual component specified will precede the value from
this string.

=back

=cut

sub update_principal
{
    my ($self, %opts) = @_;

    my $principal;

    # first process the principal string (other options precede this one)
    if ($opts{principal}) {
        $principal = $self->_split_principal_string($opts{principal});
        if (! $principal) {
            $self->error("update_principal: $self->{fail}");
            return;
        }
    } else {
        $principal = {};
    }

    # you cannot set empty string
    $principal->{primary} = $opts{primary} if $opts{primary};

    if ($opts{instances}) {
        my $ref = ref($opts{instances});
        if ($ref eq 'ARRAY') {
            $principal->{instances} = $opts{instances}
        } else {
            $self->error("update_principal: instances must be arrayref, got $ref.");
            return;
        }
    }

    $principal->{realm} = $opts{realm} if $opts{realm};

    # update the principal attribute
    foreach my $attr (keys %$principal) {
        $self->{principal}->{$attr} = $principal->{$attr};
    }

    my $p_str = $self->_principal_string();
    if ($p_str) {
        $self->verbose("update_principal to new principal $p_str");
        return SUCCESS;
    } else {
        $self->error("Cannot create pricipal string: $self->{fail}");
        return;
    }
}


=item create_credential_cache

Create the credential cache and add the C<KRB5CCNAME> to the temp environment.
Use C<kinit> to get an initial TGT for that cache.

Returns SUCCESS on success, undef otherwise (see fail attribute).

=cut

sub create_credential_cache
{
    my ($self) = @_;

    # This is NoAction safe, since this a tempdir
    my $tmppath = tempdir($KRB5CCDIR_TEMPLATE);
    if (! chmod(0700, $tmppath)) {
        return $self->fail("Failed to set permissons on credential cache dir $tmppath");
    } else {
        $self->{ccdir} = $tmppath;
        $self->{ENV}->{$KRB5ENV_CCNAME} = "FILE:$tmppath/tkt";
    }

    # Get TGT with kinit
    # Getting a TGT is possible on EL7 with gssapi and krb5 alone,
    # but not on older OS.
    # By default, always use kinit
    if($self->_kinit()) {
        $self->verbose("credential cache with TGT: $self->{ccdir}");
        return SUCCESS;
    } else {
        return $self->fail("Failed to get TGT for credential cache $self->{ccdir}: $self->{fail}");
    }
}

=item get_context

Create a C<GSSAPI::Context>.

Following options are supported

=over

=item name

The C<GSSAPI::Name> instance to use. If undef,
C<get_name> method will be used to create one.

=item iflags

Input flags/bits for the Context to create to support certain service options.
(See e.g. C<_spnego_iflags>). Defaults to 0.

=item itoken

Input token (C<q{}> is used if not defined).

=item usecred

Boolean, if true, (try to) get a credential before getting the context.

=back

Returns the output token in case of succes, undef in case of failure.

=cut

sub get_context
{
    my ($self, %opts) = @_;

    # Set name
    my $name = $opts{name};
    if(! defined($name)) {
        $name = $self->get_name();
        # Logs an error already
        return if(! defined($name));
    }

    my $cred;

    if ($opts{usecred}) {
        $self->verbose("Trying to get credential");
        $cred = $self->get_cred(name => $name);
        # Already reports error
        return if ! $cred;
    } else {
        $self->verbose("Not checking for credential");
        $cred = GSS_C_NO_CREDENTIAL;
    };

    if(! defined($self->{ccdir})) {
        return if ! defined($self->create_credential_cache());
    }

    my $iflags = defined($opts{iflags}) ? $opts{iflags} : 0;
    # Do not log itoken for security reasons
    # Do not use GSS_C_NO_BUFFER as default, it gives
    # unintialised variable warnings from withing the XS module.
    my $itoken = defined($opts{itoken}) ? $opts{itoken} : q{};

    my $imech = GSSAPI::OID::gss_mech_krb5;
    my $bindings = GSS_C_NO_CHANNEL_BINDINGS;
    # 0 means default validity period
    my $itime = $self->{ticket}->{lifetime} || 0;

    my ($omech, $otoken, $oflags, $otime);

    # short version: _init is a client application,
    #     so the client keytab will be used (KRB5_CLIENT_KTNAME)
    #     (e.g. /etc/krb5.keytab is the default server keytab, not the client keytab)
    #
    # With cred=GSS_C_NO_CREDENTIAL, and in absence of valid credential in ccache (e.g. empty tempdir),
    # _init will try to get a tgt from the keytab using
    # the (first?) principal in the client keytab, and will then continue
    # with principal from the Name::import.
    # It is possible to obtain a specific credential using GSSAPI::Cred::acquire_cred,
    # but this requires that the principal name matching the keytab is also provided/known.
    # In that case, one could pass the acquired credentials.
    # Advanced mode: It is also possible to do a acquire_cred with GSS_C_NO_CREDENTIAL manually,
    #   this is the same as passing GSS_C_NO_CREDENTIAL to _init directly.
    #   (And the credential is only available after inquire_cred or _init, so an empty
    #   KRB5CCNAME="DIR:/some/path" klist -A is normal))
    #
    # (why couldn't someone have documented this ;)

    my $ctx = GSSAPI::Context->new();

    my $ttl;
    if($self->_gssapi_init(
           $ctx, $cred, $name,
           $imech, $iflags, $itime, $bindings, $itoken,
           $omech, $otoken, $oflags, $otime) &&
       $self->_gssapi_valid_time_left($ctx, $ttl)) {
        # klist should now show the ticket
        # Not logging otoken for security reasons
        $self->verbose("Created context with TTL $ttl");
        return $otoken;
    } else {
        $self->error("context init attempt failed: $self->{fail}.");
        return;
    };

}

=item get_cred

Acquire a C<GSSAPI::Cred> instance.

Following options are supported

=over

=item name

The C<GSSAPI::Name> instance to use. If undef,
C<get_name> method will be used to create one.

=item usage

Specify the credential usage, one of C<GSSAPI> constants
C<GSS_C_INITIATE>, C<GSS_C_ACCEPT> or (default) C<GSS_C_BOTH>.

=back

Returns the C<GSSAPI::Cred> instance in case of succes, undef in case of failure.

=cut

sub get_cred
{
    my ($self, %opts) = @_;

    # Set name
    my $name = $opts{name};
    if(! defined($name)) {
        $name = $self->get_name();
        # Logs an error already
        return if(! defined($name));
    }

    if(! defined($self->{ccdir})) {
        return if ! defined($self->create_credential_cache());
    }

    my $usage = defined($opts{usage}) ? $opts{usage} : GSS_C_BOTH;
    my $in_time = 120;
    my ($in_mechs, $cred, $out_mechs, $out_time, $inq_name, $inq_lifetime, $inq_usage, $inq_mechs);

    if ($self->_gssapi_acquire_cred($name, $in_time, $in_mechs, $usage, $cred, $out_mechs, $out_time) &&
        $self->_gssapi_inquire_cred($cred, $inq_name, $inq_lifetime, $inq_usage, $inq_mechs)) {
        my $inq_hrname = $self->get_hrname($inq_name);
        if ($inq_hrname) {
            $self->verbose("Created credential instance $cred with hrname $inq_hrname lifetime $inq_lifetime usage $inq_usage mechs $inq_mechs");
            return $cred;
        } else {
            $self->error("failed to get inquired credential hrname: $self->{fail}");
            return;
        };
    } else {
        $self->error("failed to get credential: $self->{fail}");
        return;
    };
};


=item get_hrname

Return human readablename from C<GSSAPI::Name> instance.
Return undef on failure (and set C<fail> attribute with reason).

=cut

sub get_hrname
{
    my ($self, $name) = @_;

    my $hr_name;

    if ($self->_gssapi_display($name, $hr_name)) {
        if ($hr_name) {
            $self->verbose("hrname $hr_name for $name");
            return $hr_name;
        } else {
            return $self->fail("_gssapi_display returns empty hrname from name $name: $self->{fail}.");
        }
    } else {
        return $self->fail("_gssapi_display failed with name $name: $self->{fail}.");
    }

    return;
};


=item get_name

Return a imported C<GSSAPI::Name> instance.

Returns undef on failure.

Optional C<principal> hashref is passed to C<_principal_string>.

=cut

sub get_name
{
    my ($self, $principal) = @_;

    my $p_str = $self->_principal_string($principal);
    if(! defined($p_str)) {
        $self->error("Failed to generate principal string: $self->{fail}");
        return;
    };

    my ($name, $hr_name);
    if ($self->_gssapi_import($name, $p_str, GSSAPI::OID::gss_nt_krb5_name) &&
        ($hr_name = $self->get_hrname($name))) {
        $self->verbose("Created name $hr_name from principal $p_str.");
        return $name;
    } else {
        $self->error("Failed to created name from principal $p_str: $self->{fail}.");
        return;
    };
}

=item DESTROY

On DESTROY, following cleanup will be triggered

=over

=item Cleanup of credential cache

=back

=cut

sub DESTROY {
    my $self = shift;

    # This is NoAction safe, since this a tempdir
    rmtree($self->{ccdir}) if $self->{ccdir};
}

=item _principal_string

Convert the principal hashref into a principal string.

Optional C<principal> hashref can be passed, if none is provided,
use the instance C<< $self->{principal} >>.

Returns the principal string, undef in case or problem.

=cut

sub _principal_string
{
    my ($self, $principal) = @_;

    $principal = $self->{principal} if (! defined($principal));

    my @components;
    if ($principal->{primary}) {
        if ($principal->{primary} =~ m/^[\w.-]+$/) {
            push(@components, $principal->{primary});
        } else {
            return $self->fail("Invalid character in primary ".$principal->{primary});
        }
    } else {
        return $self->fail("No primary in principal hashref");
    }

    if ($principal->{instances}) {
        my $insts = $principal->{instances};
        my $ref = ref($insts);
        if($ref eq 'ARRAY') {
            if (grep {$_ !~ m/^[\w.-]+$/} @$insts) {
                return $self->fail("Invalid character in instance ".join(',', @$insts));
            } else {
                push(@components, @$insts);
            };
        } else {
            return $self->fail("principal instances must be array ref, got $ref");
        }
    }

    my $p_str = join('/', @components);
    if ($principal->{realm}) {
        if ($principal->{realm} =~ m/^[\w.-]+$/) {
            $p_str .= '@' . $principal->{realm} ;
        } else {
            return $self->fail("Invalid character in realm ".$principal->{realm});
        };
    }

    $self->verbose("_principal_string created $p_str");
    return $p_str;
}

=item _split_principal_string

Split a principal string in primary, instances and realm components.

Returns a hashref with the components, undef incase the string is invalid.

=cut

sub _split_principal_string
{
    my ($self, $p_str) = @_;

    my %res;

    my @pi_r = split ('@', $p_str);
    my $msg = "principal string '$p_str' split into ";
    if (scalar @pi_r > 2) {
        return $self->fail("Invalid principal string '$p_str': more than one realm separator '\@'");
    } else {
        if (scalar @pi_r == 2) {
            $res{realm} = $pi_r[1];
            $msg .= "realm $res{realm} ";
        }
        my @components = split('/', $pi_r[0]);
        $res{primary} = shift @components;
        if ($res{primary}) {
            $msg .= "primary $res{primary} ";
        } else {
            return $self->fail("No primary found in '$p_str'.");
        }

        if (@components) {
            $res{instances} = \@components;
            $msg = "instances " . join(',', @{$res{instances}});
        }
    }

    $self->verbose($msg);

    return \%res;
}


=item _spnego_iflags

Create the SPNEGO iflags for Context instance.

Optional C<$delegate> boolean.

=cut

sub _spnego_iflags
{
    my ($self, $delegate) = @_;

    my $iflags = GSS_C_REPLAY_FLAG;
    if ($delegate) {
       $iflags = $iflags
           | GSS_C_MUTUAL_FLAG
           | GSS_C_DELEG_FLAG;
    };
    $self->verbose("_spnego_iflags delegate ".($delegate ? 1 : 0));
    return $iflags;
}


# Perl GSSAPI is a very thin XS layer,
# so a lot of the function/method calling is just C style.
# status: a GSSAPI::Status instance, with overloaded boolean
#    is returned by all GSSAPI functions to indicate succes or failure.
# http://web.mit.edu/kerberos/krb5-current/doc/appdev/gssapi.html
# https://www.gnu.org/software/gss/manual/gss.html
# http://cpansearch.perl.org/src/AGROLMS/GSSAPI-0.28/examples/ (and the actual code itself)

=item _gss_decrypt

Given C<token>, decrypt C<inbuf> that is encrypted with GSSAPI wrap'ping.
Returns human readable C<GSSAPI::Name> and decrypted output buffer.
Returns undef on failure.

=cut

# Based on _gss_decrypt from CCM::Fetch::Download 15.12
#     token and inbuf are assumed unpack'ed
#     no Gunzip'ping of the returned outbuf.
sub _gss_decrypt
{
    my ($self, $token, $inbuf) = @_;

    my ($name, $hrname, $status, $outbuf);

    my $ctx = GSSAPI::Context->new();
    # _accept is used for server applications,
    # GSS_C_NO_CREDENTIAL will try to obtain credentials from server keytab (KRB5_KTNAME)
    if ($self->_gssapi_accept(
            $ctx, GSS_C_NO_CREDENTIAL, $token,
            GSS_C_NO_CHANNEL_BINDINGS, $name,
            undef, undef, undef, undef, undef) &&
        $self->_gssapi_display($name, $hrname) &&
        $self->_gssapi_unwrap($inbuf, $outbuf, 0, 0)) {
        return ($hrname, $outbuf);
    } else {
        return $self->fail("_gss_decrypt failed: $self->{fail}");
    }
}

=item _gss_status

Evaulatues C<status>: on success, returns SUCCESS reports with C<verbose>, on failure
returns C<fail> (The fail message is set in the C<fail> attribute).

Optional C<text> can be used to construct the message prefix.

=cut

sub _gss_status
{
    my ($self, $status, %opts) = @_;

    my $text = $opts{text} || ''; # default no text

    my (@msg, @status_msgs);

    push(@msg, 'GSS', ($status ? 'Success' : 'Error'), $text . ':');

    @status_msgs = $status->generic_message();
    push(@msg, 'MAJOR:', @status_msgs) if (@status_msgs);

    @status_msgs = $status->specific_message();
    push(@msg, 'MINOR:', @status_msgs) if (@status_msgs);
    my $msg_text = join(' ', @msg);

    if ($status) {
        $self->verbose($msg_text);
        return SUCCESS;
    } else {
        return $self->fail($msg_text);
    }
}


=item _gssapi_{init,accept,wrap,unwrap,import,display}

Interfaces to GSSAPI methods returning a C<GSSAPI::Status> instance.

Given an C<instance> of C<GSSAPI::Context> (for accept,init,valid_time_left,wrap,unwrap)
or C<GSSAPI::Name> (for display,import), call the metod on the instacne
with the remaining arguments. The returned status is processed by
C<_gss_status>.

Returns undef in case of failure (with message in C<fail> attribute),
SUCCESS otherwise.

=cut

# Remarks:
#   a. No support for GSS_C_CONTINUE_NEEDED
#   b. method name uniqueness is unittested
#   c. GSSAPI::Context::init is init_sec_context based
#   d. If you encounter warnings like
#      'Use of uninitialized value in subroutine entry at'
#      with a line number to one of the eval, it is the XS
#      bits that are complaining about unexpected undef
#      (http://www.perlmonks.org/bare/?node_id=415141).

no strict 'refs';
foreach my $class (sort keys %GSSAPI_INTERFACE_WRAPPER) {
    foreach my $method (@{$GSSAPI_INTERFACE_WRAPPER{$class}}) {
        my $full_method = "_gssapi_$method";
        *{$full_method} = sub {
            # We cannot have 'my ($self, $instance, @args) = @_;'
            # for e.g. Name->import, the $instance would be
            # restricted to this scope
            # The main reason is to make it possible to pass undef
            # variable references to the GSSAPI lowlevel code without
            # evaluation of the variable reference.
            # Even the instance can't be assigned to local variable,
            # e.g. $context->init updates $context inplace, and this
            # causes issues with a local my $instance = shift;
            my $self = shift;

            # Setup local environment
            # assigning undef to ENV gives warning in EL5
            no warnings qw(uninitialized);
            local %ENV = %ENV;
            use warnings qw(uninitialized);

            $self->update_env(\%ENV);

            my ($status);
            my $fclass = join('::', 'GSSAPI', $class);
            my $fmethod = join('::', $fclass, $method);
            my $ref = ref($_[0]);

            my $msg = "$fmethod->()";
            my $isinstance = 1;

            if ($ref) {
                my $expected_class = $method eq 'acquire_cred' ? 'GSSAPI::Name' : $fclass;
                if (UNIVERSAL::can($_[0], 'can') &&
                    $_[0]->isa($expected_class)) {
                    # Test for a blessed reference with UNIVERSAL::can
                    # UNIVERSAL::can also return true for scalars, so also test
                    # if it's a reference to start with
                    $self->debug(2, "$full_method using $msg with first arg instance of class $expected_class.");
                } else {
                    return $self->fail("$full_method expected a $expected_class instance, got ref $ref instead.");
                };
            } else {
                $msg = "$fclass->$method()";
                $isinstance = 0;
            };

            $self->debug(1, "$full_method status $msg isinstance $isinstance");

            # Actual GSSAPI calls
            local $@;
            eval {
                $status = $isinstance ? $fmethod->(@_) : $fclass->$method(@_);
            };

            # Make sure eval $@ is trapped
            my $ec = "$@";

            # Stringification of the args seems safe after the GSSAPI call is made
            # Level 5 since security related token might get logged
            # Run in eval to handle failures of stringification of the arguments
            $@ = '';
            eval {
                $self->debug(5, "$full_method status $msg args ",
                             join(', ', map {defined($_) ? $_ : '<undef>'} @_),
                             " eval ec $ec");
            };
            if ($@) {
                $self->debug(5, "failed reporting $full_method status $msg args eval ec $ec: failure $@");
            }

            if ($ec) {
                return $self->fail("$full_method $fmethod croaked: $ec");
            } else {
                return $self->_gss_status($status, text => $fmethod);
            }
        };
    }
}
use strict 'refs';

# not needed, in principle GSSAPI and proper environment (esp client keytab)
# should be sufficient.

=item _process

Run arrayref $cmd via C<< CAF::Process->new->output >> in updated environment.

Returns the output (and sets C<< $? >>).

=cut

sub _process
{
    my ($self, $cmd) = @_;

    # Setup local environment
    # assigning undef to ENV gives warning in EL5
    no warnings qw(uninitialized);
    local %ENV = %ENV;
    use warnings qw(uninitialized);

    $self->update_env(\%ENV);

    my $proc = CAF::Process->new($cmd, log => $self);
    my $output = $proc->output();

    if ($_EC->error()) {
        # LC::Exception supports formatted stringification
        my $errmsg = ''.$_EC->error();
        $_EC->ignore_error();
        return $self->fail($errmsg);
    }

    $self->verbose("output from $proc: $output");

    return $output;
}

=item _kinit

Obtain the C<TGT> using kinit, using the credential
cache specified in the 'KRB5CCNAME' environment variable.

Principal used is generated via C<_principal_string>.

Returns SUCCESS on success, undef otherwise.

=cut

# TODO: Main issue is the principal of the keytab
#       Available principals can be listed via klist -k
#       The keytab principal is typically not the one needed
#       Default principal host/<fqdn>@<REALM> vs HTTP/remoteserver@REALM

sub _kinit
{
    my ($self) = @_;

    my $cmd = [$kinit_bin];

    my $lifetime = $self->{ticket}->{lifetime};
    if (defined($lifetime)) {
        $self->verbose("_kinit lifetime $lifetime");
        push(@$cmd, '-l', $lifetime);
    };

    my $keytab = $self->{ticket}->{keytab};
    if (defined($keytab)) {
        $self->verbose("_kinit keytab $keytab");
        push(@$cmd, '-k', '-t', $keytab);
    } else {
        $self->warn('_kinit: no keytab defined');
    };

    my $principal = $self->_principal_string();
    if($principal) {
        $self->verbose("_kinit principal $principal");
        push(@$cmd, $principal);
    } else {
        if($self->{fail}) {
            return $self->fail("_kinit: no principal $self->{fail}");
        } else {
            $self->warn('_kinit: no principal defined');
        }
    }

    my $output = $self->_process($cmd);
    if ($?) {
        return $self->fail("_kinit returned failure ec $? (output $output,",
                           " command '", join(' ', @$cmd),"')");
    } else {
        $self->verbose("_kinit ok");
        return SUCCESS;
    }
}


=pod

=back

=cut

1;
