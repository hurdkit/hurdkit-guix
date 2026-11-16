#!/usr/bin/env tclsh
# Dimensions, colour-region and pixel-difference checks for binary PPM files.
proc fail {message} {puts stderr "ppm_check: $message"; exit 1}
proc usage {} {
    fail {usage: ppm_check.tcl dimensions FILE | region FILE X Y WIDTH HEIGHT RRGGBB MIN_PERCENT [TOLERANCE] | differs FILE REFERENCE MAX_PERCENT}
}
proc read_token {channel} {
    while true {
        set char [read $channel 1]
        if {$char eq ""} {fail "truncated PPM header"}
        if {$char eq "#"} {gets $channel; continue}
        if {![string is space -strict $char]} break
    }
    set token $char
    while true {
        set char [read $channel 1]
        if {$char eq "" || [string is space -strict $char]} break
        append token $char
    }
    if {![string is integer -strict $token]} {fail "invalid PPM header field '$token'"}
    return $token
}
proc read_ppm {path} {
    set channel [open $path rb]
    fconfigure $channel -translation binary
    try {
        set magic [read $channel 2]
        if {$magic ne "P6"} {fail "$path is not a binary P6 PPM"}
        set width [read_token $channel]
        set height [read_token $channel]
        set max [read_token $channel]
        if {$width < 1 || $height < 1 || $max != 255} {fail "unsupported PPM dimensions or maximum value"}
        set pixels [read $channel]
        set expected [expr {$width * $height * 3}]
        if {[string length $pixels] != $expected} {fail "$path has [string length $pixels] data bytes; expected $expected"}
        binary scan $pixels cu* values
        return [list $width $height $values]
    } finally {close $channel}
}
proc colour {text} {
    if {![regexp {^[0-9a-fA-F]{6}$} $text]} {fail "colour must be six hexadecimal digits"}
    binary scan [binary format H6 $text] cu3 rgb
    return $rgb
}
proc region {image x y width height wanted minimum {tolerance 0}} {
    lassign $image columns rows pixels
    if {![string is integer -strict $x] || ![string is integer -strict $y] ||
        ![string is integer -strict $width] || ![string is integer -strict $height] ||
        $x < 0 || $y < 0 || $width < 1 || $height < 1 || $x + $width > $columns || $y + $height > $rows} {
        fail "region lies outside the image"
    }
    if {![string is double -strict $minimum] || $minimum < 0 || $minimum > 100 ||
        ![string is integer -strict $tolerance] || $tolerance < 0 || $tolerance > 255} {
        fail "MIN_PERCENT must be 0..100 and TOLERANCE must be 0..255"
    }
    set matched 0
    for {set row $y} {$row < $y + $height} {incr row} {
        for {set column $x} {$column < $x + $width} {incr column} {
            set offset [expr {($row * $columns + $column) * 3}]
            set same true
            foreach got [lrange $pixels $offset $offset+2] want $wanted {
                if {abs($got - $want) > $tolerance} {set same false; break}
            }
            if {$same} {incr matched}
        }
    }
    set total [expr {$width * $height}]
    set percent [expr {100.0 * $matched / $total}]
    puts [format "match=%.3f%% (%d/%d pixels)" $percent $matched $total]
    if {$percent + 1e-9 < $minimum} {exit 1}
}
proc differs {image reference maximum} {
    lassign $image width height pixels
    lassign $reference other_width other_height other_pixels
    if {$width != $other_width || $height != $other_height} {fail "image dimensions differ"}
    if {![string is double -strict $maximum] || $maximum < 0 || $maximum > 100} {fail "MAX_PERCENT must be 0..100"}
    set different 0
    set total [expr {$width * $height}]
    for {set offset 0} {$offset < $total * 3} {incr offset 3} {
        if {[lrange $pixels $offset $offset+2] ne [lrange $other_pixels $offset $offset+2]} {incr different}
    }
    set percent [expr {100.0 * $different / $total}]
    puts [format "difference=%.3f%% (%d/%d pixels)" $percent $different $total]
    if {$percent - 1e-9 > $maximum} {exit 1}
}

if {$argc < 2} usage
set command [lindex $argv 0]
switch -- $command {
    dimensions {
        if {$argc != 2} usage
        lassign [read_ppm [lindex $argv 1]] width height
        puts "${width}x${height}"
    }
    region {
        if {$argc ni {8 9}} usage
        set image [read_ppm [lindex $argv 1]]
        set arguments [lrange $argv 2 5]
        lappend arguments [colour [lindex $argv 6]]
        lappend arguments {*}[lrange $argv 7 end]
        region $image {*}$arguments
    }
    differs {
        if {$argc != 4} usage
        differs [read_ppm [lindex $argv 1]] [read_ppm [lindex $argv 2]] [lindex $argv 3]
    }
    default usage
}
