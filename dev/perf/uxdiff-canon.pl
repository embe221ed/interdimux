#!/usr/bin/perl
# uxdiff-canon.pl -- canonicalise `capture-pane -p -e` output.
#
# Two screens that LOOK the same can differ in bytes: tmux carries the SGR
# state from cell to cell, and the attributes of a BLANK cell -- its
# foreground, bold, dim, italic, blink -- are invisible, yet depend on the
# order the cells happened to be redrawn in (fzf repaints parts of its window
# as async results land).  base-vs-base runs differed exactly there.
#
# So every cell is reduced to its VISIBLE style and the line is re-encoded:
#   * a space that is not reversed keeps only what shows on a blank: the
#     background, underline, strikethrough, overline (and their colours);
#   * every other cell keeps its full style;
#   * each line starts from the default style and ends reset; trailing
#     default-style blanks are dropped.
# Bytes, not characters: a multi-byte character's bytes always share one
# style, so no escape is ever inserted inside one.
use strict;
use warnings;
binmode STDIN;
binmode STDOUT;

my %st;    # current input state

sub colour {    # consumes from @$p after 38/48/58 (; or : forms)
    my ($p, $sub) = @_;
    my @s = $sub ne '' ? split(/:/, $sub, -1) : ();
    my $mode = @s ? shift @s : shift @$p;
    $mode //= '';
    if ($mode eq '5') {
        my $n = @s ? shift @s : shift @$p;
        return 'i' . ($n // 0);
    }
    if ($mode eq '2') {
        my @c = @s ? @s : (shift @$p, shift @$p, shift @$p);
        @c = @c[-3 .. -1] if @c > 3;    # 38:2:<cs>:r:g:b
        return sprintf('#%02x%02x%02x', map { $_ // 0 } @c);
    }
    return undef;
}

sub apply {
    my ($params) = @_;
    my @p = split(/;/, $params, -1);
    @p = ('0') unless @p;
    while (@p) {
        my $x = shift @p;
        my ($base, $sub) = $x =~ /^(\d*)(?::(.*))?$/ ? ($1, $2 // '') : ($x, '');
        $base = '0' if $base eq '';
        if    ($base eq '0')  { %st = () }
        elsif ($base eq '1')  { $st{b} = 1 }
        elsif ($base eq '2')  { $st{d} = 1 }
        elsif ($base eq '3')  { $st{i} = 1 }
        elsif ($base eq '4')  { if ($sub eq '0') { delete $st{u} } else { $st{u} = $sub eq '' ? 1 : $sub } }
        elsif ($base eq '5' || $base eq '6') { $st{k} = 1 }
        elsif ($base eq '7')  { $st{r} = 1 }
        elsif ($base eq '8')  { $st{h} = 1 }
        elsif ($base eq '9')  { $st{s} = 1 }
        elsif ($base eq '21') { $st{u} = 2 }
        elsif ($base eq '22') { delete @st{qw(b d)} }
        elsif ($base eq '23') { delete $st{i} }
        elsif ($base eq '24') { delete $st{u} }
        elsif ($base eq '25') { delete $st{k} }
        elsif ($base eq '27') { delete $st{r} }
        elsif ($base eq '28') { delete $st{h} }
        elsif ($base eq '29') { delete $st{s} }
        elsif ($base eq '53') { $st{o} = 1 }
        elsif ($base eq '55') { delete $st{o} }
        elsif ($base >= 30 && $base <= 37)   { $st{fg} = 'i' . ($base - 30) }
        elsif ($base >= 90 && $base <= 97)   { $st{fg} = 'i' . ($base - 90 + 8) }
        elsif ($base >= 40 && $base <= 47)   { $st{bg} = 'i' . ($base - 40) }
        elsif ($base >= 100 && $base <= 107) { $st{bg} = 'i' . ($base - 100 + 8) }
        elsif ($base eq '39') { delete $st{fg} }
        elsif ($base eq '49') { delete $st{bg} }
        elsif ($base eq '59') { delete $st{uc} }
        elsif ($base eq '38' || $base eq '48' || $base eq '58') {
            my $c = colour(\@p, $sub);
            my $k = { 38 => 'fg', 48 => 'bg', 58 => 'uc' }->{$base};
            if (defined $c) { $st{$k} = $c } else { delete $st{$k} }
        }
        # anything else (unknown) is ignored
    }
}

sub key_for {
    my ($blank) = @_;
    my %v = %st;
    if ($blank && !$v{r}) { delete @v{qw(fg b d i k h)} }
    delete $v{uc} unless $v{u};
    return join(',', map { "$_=$v{$_}" } sort keys %v);
}

sub sgr_of {
    my ($key) = @_;
    return "\e[0m" if $key eq '';
    my %v = map { split(/=/, $_, 2) } split(/,/, $key);
    my @o = ('0');
    push @o, '1' if $v{b};
    push @o, '2' if $v{d};
    push @o, '3' if $v{i};
    push @o, ($v{u} eq '1' ? '4' : "4:$v{u}") if $v{u};
    push @o, '5' if $v{k};
    push @o, '7' if $v{r};
    push @o, '8' if $v{h};
    push @o, '9' if $v{s};
    push @o, '53' if $v{o};
    for my $pair ([fg => 38], [bg => 48], [uc => 58]) {
        my ($k, $n) = @$pair;
        next unless defined $v{$k};
        if ($v{$k} =~ /^i(\d+)$/) { push @o, "$n;5;$1" }
        elsif ($v{$k} =~ /^#(..)(..)(..)$/) { push @o, join(';', $n, 2, hex $1, hex $2, hex $3) }
    }
    return "\e[" . join(';', @o) . 'm';
}

while (my $line = <STDIN>) {
    my $nl = $line =~ s/\n\z// ? "\n" : '';
    my @cells;    # [key, byte]
    while (length $line) {
        if ($line =~ s/^\e\[([0-9;:]*)m//) { apply($1); next }
        if ($line =~ s/^(\e\[[0-9;:?]*[A-Za-z])//) { next }    # other CSI: no cell
        if ($line =~ s/^(\e\][^\a\e]*(?:\a|\e\\))//) { next }  # OSC (hyperlinks)
        my $b = substr($line, 0, 1, '');
        push @cells, [key_for($b eq ' '), $b];
    }
    pop @cells while @cells && $cells[-1][0] eq '' && $cells[-1][1] eq ' ';
    my ($cur, $out) = ('', '');
    for my $c (@cells) {
        if ($c->[0] ne $cur) { $out .= sgr_of($c->[0]); $cur = $c->[0] }
        $out .= $c->[1];
    }
    $out .= "\e[0m" if $cur ne '';
    print $out, $nl;
}
