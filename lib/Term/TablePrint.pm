
package Term::TablePrint;

use warnings;
use strict;
use 5.008000;
no warnings 'utf8';

our $VERSION = '0.019';
use Exporter 'import';
our @EXPORT_OK = qw( print_table );

use Carp         qw( carp croak );
use List::Util   qw( sum );
use Scalar::Util qw( looks_like_number );

use Term::Choose       qw( choose );
use Term::Choose::Util qw( term_size insert_sep unicode_sprintf );
use Term::ProgressBar  qw();
use Text::LineFold     qw();
use Unicode::GCString  qw();

sub CLEAR_SCREEN () { "\e[H\e[J" }



sub new {
    my $class = shift;
    croak "new: called with " . @_ . " arguments - 0 or 1 arguments expected." if @_ > 1;
    my ( $opt ) = @_;
    my $self = bless {}, $class;
    if ( defined $opt ) {
        croak "new: The (optional) argument is not a HASH reference." if ref $opt ne 'HASH';
        $self->__validate_options( $opt );
    }
    return $self;
}


sub __validate_options {
    my ( $self, $opt ) = @_;
    if ( $opt->{_db_browser_mode} || $opt->{db_browser_mode} ) { ###
        %$self = ( %$self, %$opt );
        return;
    }
    my $valid = {
        progress_bar    => '[ 0-9 ]+',
        max_rows        => '[ 0-9 ]+',
        min_col_width   => '[ 0-9 ]+',
        tab_width       => '[ 0-9 ]+',
        binary_filter   => '[ 0 1 ]',
        add_header      => '[ 0 1 ]',
        keep_header     => '[ 0 1 ]',
        table_expand    => '[ 0 1 ]',
        choose_columns  => '[ 0 1 2 ]',
        mouse           => '[ 0 1 2 3 4 ]',
        binary_string   => '',
        undef           => '',
        #thsd_sep       => '',
        #no_col         => '',
    };

    for my $key ( keys %$opt ) {
        if ( ! exists $valid->{$key} ) {
            carp "print_table: '$key' is not a valid option name.";
            choose( [ 'Press ENTER to continue' ], { prompt => '' } );
            next;
        }
        next if ! defined $opt->{$key};
        if ( $valid->{$key} eq '' ) {
            $self->{$key} = $opt->{$key};
        }
        elsif ( $opt->{$key} =~ /^$valid->{$key}\z/x ) {
            $self->{$key} = $opt->{$key};
        }
        else {
            croak "print_table: '$opt->{$key}' is not a valid value for option '$key'.";
        }
    }
}


sub __set_defaults {
    my ( $self ) = @_;
    $self->{progress_bar}   = 40000  if ! defined $self->{progress_bar};
    $self->{max_rows}       = 50000  if ! defined $self->{max_rows};
    $self->{tab_width}      = 2      if ! defined $self->{tab_width};
    $self->{min_col_width}  = 30     if ! defined $self->{min_col_width};
    $self->{table_expand}   = 1      if ! defined $self->{table_expand};
    $self->{binary_filter}  = 0      if ! defined $self->{binary_filter};
    $self->{undef}          = ''     if ! defined $self->{undef};
    $self->{mouse}          = 0      if ! defined $self->{mouse};
    $self->{binary_string}  = 'BNRY' if ! defined $self->{binary_string};
    $self->{choose_columns} = 0      if ! defined $self->{choose_columns};
    $self->{add_header}     = 0      if ! defined $self->{add_header};
    $self->{keep_header}    = 1      if ! defined $self->{keep_header};
    $self->{thsd_sep} = ',';
    $self->{no_col}   = 'col';
}


sub __choose_columns_with_order {
    my ( $self, $avail_cols ) = @_;
    my $col_idxs = [];
    my $ok = '-ok-';
    my @pre = ( $ok );
    my $init_prompt = 'Columns: ';
    my $gcs = Unicode::GCString->new( $init_prompt );
    my $s_tab = $gcs->columns();

    while ( 1 ) {
        my @chosen_cols = @$col_idxs ? map( $avail_cols->[$_], @$col_idxs ) : '*';
        my $prompt = $init_prompt . join ', ', @chosen_cols;
        my $choices = [ @pre, @$avail_cols ];
        # Choose
        my @idx = choose(
            $choices,
            { prompt => $prompt, lf => [ 0, $s_tab ], clear_screen => 1,
              no_spacebar => [ 0 .. $#pre ], index => 1, mouse => $self->{mouse} }
        );
        if ( ! @idx || ! defined $choices->[$idx[0]] ) {
            if ( @$col_idxs ) {
                $col_idxs = [];
                next;
            }
            else {
                return;
            }
        }
        elsif ( $choices->[$idx[0]] eq $ok ) {
            shift @idx;
            push @$col_idxs, map { $_ -= @pre; $_ } @idx;
            return $col_idxs;
        }
        else {
            push @$col_idxs, map { $_ -= @pre; $_ } @idx;
        }
    }
}


sub __choose_columns_simple {
    my ( $self, $avail_cols ) = @_;
    my $all = '-*-';
    my @pre = ( $all );
    my $choices = [ @pre, @$avail_cols ];
    my @idx = choose(
        $choices,
        { prompt => 'Choose: ', no_spacebar => [ 0 .. $#pre ], index => 1, mouse => $self->{mouse} }
    );
    return if ! @idx;
    if ( $choices->[$idx[0]] eq $all ) {
        return [];
    }
    return [ map { $_ -= @pre; $_ } @idx ];
}


sub print_table {
    if ( ref $_[0] ne 'Term::TablePrint' ) {
        return Term::TablePrint->new( $_[1] )->print_table( $_[0] );
    }
    my $self = shift;
    my ( $table_ref, $opt ) = @_;
    my  $a_ref;
    if ( $self->{_db_browser_mode} || $self->{db_browser_mode} ) { ###
        $self->__set_defaults();
        $a_ref = $table_ref;
    }
    else {
        croak "print_table: called with " . @_ . " arguments - 1 or 2 arguments expected." if @_ < 1 || @_ > 2;
        croak "print_table: Required an ARRAY reference as the first argument."            if ref $table_ref  ne 'ARRAY';
        croak "print_table: Empty table without header row!"                               if ! @$table_ref;
        if ( defined $opt ) {
            croak "print_table: The (optional) second argument is not a HASH reference."   if ref $opt ne 'HASH';
            $self->{backup_opt} = { map{ $_ => $self->{$_} } keys %$opt } if defined $opt;
            $self->__validate_options( $opt );
        }
        $self->__set_defaults();
        if ( $self->{add_header} ) {
            unshift @$table_ref, [ map { $_ . '_' . $self->{no_col} } 1 .. @{$table_ref->[0]} ];
        }
        my $last_row_idx = $self->{max_rows} && $self->{max_rows} < @$table_ref ? $self->{max_rows} : $#$table_ref;
        my @copy = ();
        if ( $self->{choose_columns}  ) {
            my $col_idxs;
            $col_idxs = $self->__choose_columns_simple( $table_ref->[0] )     if $self->{choose_columns} == 1;
            $col_idxs = $self->__choose_columns_with_order( $table_ref->[0] ) if $self->{choose_columns} == 2;
            return if ! defined $col_idxs;
            if ( @$col_idxs ) {
                @copy = map { [ @{$table_ref->[$_]}[@$col_idxs] ] } 0 .. $last_row_idx;
            }
        }
        if ( @copy ) {
            $a_ref = \@copy;
        }
        else {
            $a_ref = $table_ref;
            $#$a_ref = $last_row_idx;
        }
    }
    my $gcs_bnry = Unicode::GCString->new( $self->{binary_string} );
    $self->{binary_length} = $gcs_bnry->columns;
    if ( $self->{progress_bar} ) {
        print 'Computing: ...' . "\n";
        $self->{show_progress} = int @$a_ref * @{$a_ref->[0]} / $self->{progress_bar};
    }
    $self->__calc_col_width( $a_ref );
    $self->__inner_print_tbl( $a_ref );
    if ( $self->{backup_opt} ) {
        my $backup_opt = delete $self->{backup_opt};
        for my $key ( keys %$backup_opt ) {
            $self->{$key} = $backup_opt->{$key};
        }
    }
}


sub __inner_print_tbl {
    my ( $self, $a_ref ) = @_;
    my ( $term_width ) = term_size();
    my $width_cols = $self->__calc_avail_width( $a_ref, $term_width );
    return if ! $width_cols;
    my ( $list, $len ) = $self->__trunk_col_to_avail_width( $a_ref, $width_cols );
    if ( $self->{max_rows} && @$list - 1 >= $self->{max_rows} ) {
        my $reached_limit = 'REACHED LIMIT "MAX_ROWS": ' . insert_sep( $self->{max_rows}, $self->{thsd_sep} );
        my $gcs1 = Unicode::GCString->new( $reached_limit );
        if ( $gcs1->columns > $len ) {
            $reached_limit = 'REACHED LIMIT';
            my $gcs2 = Unicode::GCString->new( $reached_limit );
            if ( $gcs2->columns > $len ) {
                $reached_limit = '=LIMIT=';
            }
        }
        push @$list, unicode_sprintf( $reached_limit, $len, 0 );
    }
    #my $old_row = $self->{keep_header} ? @$list : 0;
    my $old_row = 0;
    my $auto_jump = 1;
    my ( $width ) = term_size();
    while ( 1 ) {
        if ( ( term_size() )[0] != $width ) {
            ( $width ) = term_size();
            $self->__inner_print_tbl( $a_ref );
            return;
        }
        my $prompt = $self->{keep_header} ? shift @$list : '';
        if ( ! @$list ) {
            push @$list, $prompt;
            $prompt = '';
            $old_row = 0;
        }
        my $row = choose(
            $list,
            { prompt => $prompt, index => 1, default => $old_row, ll => $len, layout => 3,
              clear_screen => 1, mouse => $self->{mouse} }
        );
        unshift @$list, $prompt if $self->{keep_header};
        return if ! defined $row;
        #if ( ! $self->{table_expand} ) {
        #    return if $row == 0;
        #    next;
        #}
        #if ( $old_row == $row ) {
        #    return if $row == 0;
        #    $old_row = 0;
        #    next;
        #}
        if ( ! $self->{table_expand} ) {
            return if $row == 0;
            next;
        }
        if ( $old_row == $row && ! $self->{keep_header} ) {
            return if $row == 0;
            $old_row = 0;
            next;
        }
        if ( $old_row == $row && ! $auto_jump ) {
            return if $row == 0;
            $old_row = 0;
            $auto_jump = 1;
            next;
        }
        $auto_jump = 0;
        $old_row = $row;
        $row++ if $prompt;

        my $row_data = $self->__single_row( $a_ref, $row, $self->{longest_col_name} + 1 );
        choose(
            $row_data,
            { prompt => '', layout => 3, clear_screen => 1, mouse => $self->{mouse} }
        );
    }
}


sub __single_row {
    my ( $self, $a_ref, $row, $len_key ) = @_;
    my ( $term_width ) = term_size();
    $len_key = int( $term_width / 100 * 33 ) if $len_key > int( $term_width / 100 * 33 );
    my $separator = ' : ';
    my $gcs_sep = Unicode::GCString->new( $separator );
    my $len_sep = $gcs_sep->columns;
    my $col_max = $term_width - ( $len_key + $len_sep + 1 );
    my $line_fold = Text::LineFold->new(
        Charset=> 'utf8',
        OutputCharset => '_UNICODE_',
        Urgent => 'FORCE' ,
        ColMax => $col_max,
    );
    my $row_data = [ ' Close with ENTER' ];
    for my $col ( 0 .. $#{$a_ref->[0]} ) {
        push @{$row_data}, ' ';
        my $key = $a_ref->[0][$col];
        my $sep = $separator;
        if ( ! defined $a_ref->[$row][$col] || $a_ref->[$row][$col] eq '' ) {
            push @{$row_data}, sprintf "%*.*s%*s%s", $len_key, $len_key, $key, $len_sep, $sep, '';
        }
        else {
            my $text = $line_fold->fold( $a_ref->[$row][$col], 'PLAIN' );
            for my $line ( split /\R+/, $text ) {
                push @{$row_data}, sprintf "%*.*s%*s%s", $len_key, $len_key, $key, $len_sep, $sep, $line;
                $key = '' if $key;
                $sep = '' if $sep;
            }
        }
    }
    return $row_data;
}


sub __calc_col_width {
    my ( $self, $a_ref ) = @_;
    my $binray_regexp = qr/[\x00-\x08\x0B-\x0C\x0E-\x1F]/;
    $self->{longest_col_name} = 0;
    my $normal_row = 0;
    $self->{width_cols} = [ ( 1 ) x @{$a_ref->[0]} ];
    my @col_idx = ( 0 .. $#{$a_ref->[0]} );
    my $show_progress = $self->{show_progress} >= 2 ? 1 : 0; #
    my $total = $#{$a_ref};                   #
    my $next_update = 0;                      #
    my $c = 0;                                #
    my $progress;                             #
    if ( $show_progress ) {                   #
        local $| = 1;                         #
        print CLEAR_SCREEN;                   #
        $progress = Term::ProgressBar->new( { #
            name => 'Computing',              #
            count => $total,                  #
            remove => 1 } );                  #
        $progress->minor( 0 );                #
    }                                         #
    for my $row ( @$a_ref ) {
        for my $i ( @col_idx ) {
            $row->[$i] = $self->{undef} if ! defined $row->[$i];
            if ( ref $row->[$i] ) {
                $row->[$i] = $self->__handle_reference( $row->[$i] );
            }
            my $width;
            if ( $self->{binary_filter} && substr( $row->[$i], 0, 100 ) =~ $binray_regexp ) {
                $row->[$i] = $self->{binary_string};
                $width     = $self->{binary_length};
            }
            else {
                $row->[$i] =~ s/^\p{Space}+//;
                $row->[$i] =~ s/\p{Space}+\z//;
                #$row->[$i] =~ s/(?<=\P{Space})\p{Space}+/ /g;
                $row->[$i] =~ s/\p{Space}+/ /g;
                $row->[$i] =~ s/\p{C}//g;
                my $gcs = Unicode::GCString->new( $row->[$i] );
                $width = $gcs->columns;
            }
            if ( $normal_row ) {
                $self->{width_cols}[$i] = $width if $width > $self->{width_cols}[$i];
                ++$self->{not_a_number}[$i] if $row->[$i] && ! looks_like_number $row->[$i];
            }
            else {
                # column name
                $self->{width_head}[$i] = $width;
                $self->{longest_col_name} = $width if $width > $self->{longest_col_name};
                $normal_row = 1 if $i == $#$row;
            }
        }
        if ( $show_progress ) {                                              #
            my $is_power = 0;                                                #
            for ( my $i = 0; 2 ** $i <= $c; ++$i ) {                         #
                $is_power = 1 if 2 ** $i == $c;                              #
            }                                                                #
            $next_update = $progress->update( $c ) if $c >= $next_update;    #
            ++$c;                                                            #
        }                                                                    #
    }
    $progress->update( $total ) if $show_progress && $total >= $next_update; #
}

sub __handle_reference {
    my ( $self, $ref ) = @_;
    if ( ref $ref eq 'ARRAY' ) {
        return 'ref: [' . join( ',', map { '"' . $_ . '"' } @$ref ) . ']';
    }
    elsif ( ref $ref eq 'SCALAR' ) {
        return 'ref: \\' . $$ref;
    }
    elsif ( ref $ref eq 'HASH' ) {
        return 'ref: {' . join( ',', map { $_ . '=>"' . $ref->{$_} . '"' } keys %$ref ) . '}';
    }
    elsif ( ref $ref eq 'Regexp' ) {
        return 'ref: qr/' . $ref . '/';
    }
    elsif ( ref $ref eq 'VSTRING' ) {
        return 'ref: \v' . join '.', unpack 'C*', $$ref;
    }
    elsif ( ref $ref eq 'GLOB' ) {
        return 'ref: \\' . $$ref;
    }
    else {
        return 'ref: ' . ref( $ref );
    }
}


sub __calc_avail_width {
    my ( $self, $a_ref, $term_width ) = @_;
    my $width_head = [ @{$self->{width_head}} ];
    my $width_cols = [ @{$self->{width_cols}} ];
    my $avail_width = $term_width - $self->{tab_width} * $#$width_cols;
    my $sum = sum( @$width_cols );
    if ( $sum < $avail_width ) {
        # auto cut
        HEAD: while ( 1 ) {
            my $count = 0;
            for my $i ( 0 .. $#$width_head ) {
                if ( $width_head->[$i] > $width_cols->[$i] ) {
                    ++$width_cols->[$i];
                    ++$count;
                    last HEAD if ( $sum + $count ) == $avail_width;
                }
            }
            last HEAD if $count == 0;
            $sum += $count;
        }
        return $width_head, $width_cols;
    }
    elsif ( $sum > $avail_width ) {
        my $minimum_with = $self->{min_col_width} || 1;
        if ( @$width_head > $avail_width ) {
            print 'Terminal window is not wide enough to print this table.' . "\n";
            choose(
                [ 'Press ENTER to show the column names.' ],
                { prompt => '', clear_screen => 0, mouse => $self->{mouse} }
            );
            my $prompt = 'Reduce the number of columns".' . "\n";
            $prompt .= 'Close with ENTER.';
            choose(
                $a_ref->[0],
                { prompt => $prompt, clear_screen => 0, mouse => $self->{mouse} }
            );
            return;
        }
        my @width_cols_tmp = @$width_cols;
        my $percent = 0;

        MIN: while ( $sum > $avail_width ) {
            ++$percent;
            my $count = 0;
            for my $i ( 0 .. $#width_cols_tmp ) {
                next if $minimum_with >= $width_cols_tmp[$i];
                if ( $minimum_with >= _minus_x_percent( $width_cols_tmp[$i], $percent ) ) {
                    $width_cols_tmp[$i] = $minimum_with;
                }
                else {
                    $width_cols_tmp[$i] = _minus_x_percent( $width_cols_tmp[$i], $percent );
                }
                ++$count;
            }
            $sum = sum( @width_cols_tmp );
            $minimum_with-- if $count == 0;
            #last MIN if $minimum_with == 0;
        }
        my $rest = $avail_width - $sum;
        if ( $rest ) {

            REST: while ( 1 ) {
                my $count = 0;
                for my $i ( 0 .. $#width_cols_tmp ) {
                    if ( $width_cols_tmp[$i] < $width_cols->[$i] ) {
                        $width_cols_tmp[$i]++;
                        $rest--;
                        $count++;
                        last REST if $rest == 0;
                    }
                }
                last REST if $count == 0;
            }
        }
        $width_cols = [ @width_cols_tmp ] if @width_cols_tmp;
    }
    return $width_cols;
}

sub _minus_x_percent {
    my ( $value, $percent ) = @_;
    my $new = int( $value - ( $value / 100 * $percent ) );
    return $new > 0 ? $new : 1;
}


sub __trunk_col_to_avail_width {
    my ( $self, $a_ref, $width_cols ) = @_;
    my $total = $#{$a_ref};                   #
    my $next_update = 0;                      #
    my $c = 0;                                #
    my $progress;                             #
    if ( $self->{show_progress} ) {           #
        local $| = 1;                         #
        print CLEAR_SCREEN;                   #
        $progress = Term::ProgressBar->new( { #
            name => 'Computing',              #
            count => $total,                  #
            remove => 1 } );                  #
        $progress->minor( 0 );                #
    }                                         #
    my $list;
    my $tab = ' ' x $self->{tab_width};
    for my $row ( @$a_ref ) {
        my $str = '';
        for my $i ( 0 .. $#$width_cols ) {
            $str .= unicode_sprintf( $row->[$i], $width_cols->[$i], $self->{not_a_number}[$i] ? 0 : 1 );
            $str .= $tab if $i != $#$width_cols;
        }
        push @$list, $str;
        if ( $self->{show_progress} ) {                                      #
            my $is_power = 0;                                                #
            for ( my $i = 0; 2 ** $i <= $c; ++$i ) {                         #
                $is_power = 1 if 2 ** $i == $c;                              #
            }                                                                #
            $next_update = $progress->update( $c ) if $c >= $next_update;    #
            ++$c;                                                            #
        }                                                                    #
    }
    $progress->update( $total ) if $self->{show_progress} && $total >= $next_update; #
    my $len = sum( @$width_cols, $self->{tab_width} * $#{$width_cols} );
    return $list, $len;
}




1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Term::TablePrint - Print a table to the terminal and browse it interactively.

=head1 VERSION

Version 0.019

=cut

=head1 SYNOPSIS

    my $table = [ [ 'id', 'name' ],
                  [    1, 'Ruth' ],
                  [    2, 'John' ],
                  [    3, 'Mark' ],
                  [    4, 'Nena' ], ];

    use Term::TablePrint qw( print_table );

    print_table( $table );

    # or OO style:

    use Term::TablePrint;

    my $pt = Term::TablePrint->new();
    $pt->print_table( $table );

=head1 DESCRIPTION

C<print_table> shows a table and lets the user interactively browse it. It provides a cursor which highlights the row
on which it is located. The user can scroll through the table with the different cursor keys - see L</KEYS>.

If the table has more rows than the terminal, the table is divided up on as many pages as needed automatically. If the
cursor reaches the end of a page, the next page is shown automatically until the last page is reached. Also if the
cursor reaches the topmost line, the previous page is shown automatically if it is not already the first one.

If the terminal is too narrow to print the table, the columns are adjusted to the available width automatically.

If the option table_expand is enabled and a row is selected with Return, each column of that row is output in its own
line preceded by the column name. This might be useful if the columns were cut due to the too low terminal width.

To get a proper output C<print_table> uses the C<columns> method from L<Unicode::GCString> to calculate the string
length.

The following modifications are made (at a copy of the original data) before the output.

Leading and trailing spaces are removed from the array elements

    s/^\p{Space}+//;
    s/\p{Space}+\z//;

and spaces are squashed to a single white-space.

    s/\p{Space}+/ /g;

In addition, characters of the Unicode property C<Other> are removed.

    s/\p{C}//g;

In C<Term::TablePrint> the C<utf8> C<warnings> are disabled.

    no warnings 'utf8';

The elements in a column are right-justified if one or more elements of that column do not look like a number, else they
are left-justified.

=head1 METHODS

=head2 new

The C<new> method returns a C<Term::TablePrint> object. As an argument it can be passed a reference to a hash which
holds the options - the available options are listed in L</OPTIONS>.

    my $tp = Term::TablePrint->new( [ \%options ] );

=head2 print_table

The C<print_table> method prints the table passed with the first argument.

    $tp->print_table( $array_ref, [ \%options ] );

The first argument is a reference to an array of arrays. The first array of these arrays holds the column names. The
following arrays are the table rows where the elements are the field values.

As a second and optional argument a hash reference can be passed which holds the options - the available options are
listed in L</OPTIONS>.

=head1 SUBROUTINES

=head2 print_table

The C<print_table> subroutine prints the table passed with the first argument.

    print_table( $array_ref, [ \%options ] );

The subroutine C<print_table> takes the same arguments as the method L</print_table>.

=head1 USAGE

=head2 KEYS

Keys to move around:

=over

=item *

the C<ArrowDown> key (or the C<j> key) to move down and  the C<ArrowUp> key (or the C<k> key) to move up.

=item *

the C<PageUp> key (or C<Ctrl-B>) to go back one page, the C<PageDown> key (or C<Ctrl-F>) to go forward one page.

=item *

the C<Home> key (or C<Ctrl-A>) to jump to the first row of the table, the C<End> key (or C<Ctrl-E>) to jump to the last
row of the table.

=back

The C<Return> key closes the table if the cursor is on the header row. If I<keep_header> and I<table_expand> are
enabled, the table closes by selecting the first row twice in succession.

If the cursor is not on the first row:

=over

=item *

with the option I<table_expand> disabled the cursor jumps to the table head if C<Return> is pressed.

=item *

with the option I<table_expand> enabled each column of the selected row is output in its own line preceded by the
column name if C<Return> is pressed. Another C<Return> closes this output and goes back to the table output. If a row is
selected twice in succession, the pointer jumps to the head of the table or to the first row if I<keep_header> is
enabled.

=back

If the width of the window is changed and the option I<table_expand> is enabled, the user can rewrite the screen by
choosing a row.

If the option I<choose_columns> is enabled, the C<SpaceBar> key (or the right mouse key) can be used to select columns -
see option L</choose_columns>.

=head2 OPTIONS

Defaults may change in a future release.

=head3 add_header

If I<add_header> is set to 1, C<print_table> adds a header row - the columns are numbered starting with 1.

Default: 0

=head3 binary_filter

If I<binary_filter> is set to 1, "BNRY" is printed instead of arbitrary binary data.

If the data matches the repexp C</[\x00-\x08\x0B-\x0C\x0E-\x1F]/>, it is considered arbitrary binary data.

Printing arbitrary binary data could break the output.

Default: 0

=head3 choose_columns

If I<choose_columns> is set to 1, the user can choose which columns to print. The columns can be marked with the
C<SpaceBar>. The list of marked columns including the highlighted column are printed as soon as C<Return> is pressed.

If I<choose_columns> is set to 2, it is possible to change the order of the columns. Columns can be added (with
the C<SpaceBar> and the C<Return> key) until the user confirms with the I<-ok-> menu entry.

Default: 0

=head3 keep_header

If I<keep_header> is set to 1, the table header is shown on top of each page.

If I<keep_header> is set to 0, the table header is shown on top of the first page.

Default: 1;

=head3 max_rows

Set the maximum number of used table rows. The used table rows are kept in memory.

To disable the automatic limit set I<max_rows> to 0.

If the number of table rows is equal to or higher than I<max_rows>, the last row of the output says "REACHED LIMIT" or
"=LIMIT=" if "REACHED LIMIT" doesn't fit in the row.

Default: 50_000

=head3 min_col_width

The columns with a width below or equal I<min_col_width> are only trimmed if it is still required to lower the row width
despite all columns wider than I<min_col_width> have been trimmed to I<min_col_width>.

Default: 30

=head3 mouse

Set the I<mouse> mode (see option C<mouse> in L<Term::Choose/OPTIONS>).

Default: 0

=head3 progress_bar

Set the progress bar threshold. If the number of fields (rows x columns) is higher than the threshold, a progress bar is
shown while preparing the data for the output.

Default: 40_000

=head3 tab_width

Set the number of spaces between columns.

Default: 2

=head3 table_expand

If the option I<table_expand> is set to 1 and C<Return> is pressed, the selected table row is printed with each column
in its own line.

If I<table_expand> is set to 0, the cursor jumps to the to first row (if not already there) when C<Return> is pressed.

Default: 1

=head3 undef

Set the string that will be shown on the screen instead of an undefined field.

Default: "" (empty string)

=head1 ERROR HANDLING

=head2 Carp

C<print_table> warns

=over

=item

if an unknown option name is passed.

=back

=head2 Croak

C<print_table> dies

=over

=item

if an invalid number of arguments is passed.

=item

if an invalid argument is passed.

=item

if an invalid option value is passed.

=back

if the first argument refers to an empty array.

=head1 REQUIREMENTS

=head2 Perl version

Requires Perl version 5.8.0 or greater.

=head2 Decoded strings

C<print_table> expects decoded strings.

=head2 Encoding layer for STDOUT

For a correct output it is required to set an encoding layer for C<STDOUT> matching the terminal's character set.

=head2 Monospaced font

It is required a terminal that uses a monospaced font which supports the printed characters.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Term::TablePrint

=head1 SEE ALSO

L<App::DBBrowser>

=head1 CREDITS

Thanks to the L<Perl-Community.de|http://www.perl-community.de> and the people form
L<stackoverflow|http://stackoverflow.com> for the help.

=head1 AUTHOR

Matthäus Kiem <cuer2s@gmail.com>

=head1 LICENSE AND COPYRIGHT

Copyright 2012-2014 Matthäus Kiem.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl 5.10.0. For
details, see the full text of the licenses in the file LICENSE.

=cut
