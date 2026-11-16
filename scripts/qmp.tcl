#!/usr/bin/env tclsh
# Small QMP client for scripted VM screenshots and input.
package require json
package require json::write
# QMP is a line-oriented protocol: one JSON object per line. json::write
# pretty-prints by default, which splits a request across several lines.
json::write indented 0

proc fail {message} {puts stderr "qmp: $message"; exit 1}
proc usage {} {
    fail {usage: qmp.tcl status | screenshot FILE [DEVICE HEAD] | key CHORD | motion X Y | button BUTTON up|down | trace on|off PATTERN | quit | execute JSON}
}
proc json_string {value} {json::write string $value}
proc json_bool {value} {expr {$value ? "true" : "false"}}
proc json_number {value} {
    if {![string is double -strict $value]} {fail "not a JSON number: $value"}
    return $value
}
proc json_object {args} {json::write object {*}$args}
proc request_json {command {arguments {}}} {
    if {![info exists ::next_request]} {set ::next_request 1}
    set fields [list execute [json_string $command] id [json_string "request-$::next_request"]]
    incr ::next_request
    if {[dict size $arguments]} {
        set encoded {}
        dict for {key value} $arguments {lappend encoded $key $value}
        lappend fields arguments [json_object {*}$encoded]
    }
    json_object {*}$fields
}

set socket_path [expr {[info exists ::env(QMP_SOCKET)] ? $::env(QMP_SOCKET) : ""}]
if {$socket_path eq ""} {
    set runtime [expr {[info exists ::env(XDG_RUNTIME_DIR)] ? $::env(XDG_RUNTIME_DIR) : "/tmp"}]
    set port [expr {[info exists ::env(GUIX_SSH_PORT)] ? $::env(GUIX_SSH_PORT) : 2223}]
    set socket_path [file join $runtime "hurdkit-guix-$port.qmp"]
}
if {[catch {
    if {[regexp {^tcp:([^:]+):([0-9]+)$} $socket_path -> host port]} {
        set channel [socket $host $port]
    } else {
        set channel [open [list |socat - "UNIX-CONNECT:$socket_path"] r+]
    }
    fconfigure $channel -blocking 1 -buffering line -translation lf -encoding utf-8
} error]} {fail "cannot connect to $socket_path: $error"}

set response {}
proc read_line {channel} {
    global buffer
    while {[gets $channel line] >= 0} {
        if {[catch {set object [json::json2dict $line]} error]} {
            set ::response [list error "invalid QMP response: $error"]
        } elseif {[dict exists $object id]} {
            set ::response $object
        }
        if {[info exists ::response] && $::response ne {}} break
    }
    if {[eof $channel]} {set ::response [list error "QMP closed the connection"]}
}
proc send_request {request} {
    global channel buffer
    if {![info exists buffer($channel)]} {set buffer($channel) {}}
    if {![info exists ::qmp_ready]} {
        fileevent $channel readable [list read_line $channel]
        set handshake [request_json qmp_capabilities]
        puts $channel $handshake
        set ::response {}
        set timer [after 15000 {catch {close $::channel}; set ::response [list error "timed out waiting for QMP handshake"]}]
        vwait ::response
        after cancel $timer
        if {[llength $::response] == 2 && [lindex $::response 0] eq "error"} {fail [lindex $::response 1]}
        if {[dict exists $::response error]} {fail [dict get $::response error desc]}
        set ::qmp_ready 1
    }
    set ::response {}
    puts $channel $request
    fileevent $channel readable [list read_line $channel]
    set timer [after 15000 {catch {close $::channel}; set ::response [list error "timed out waiting for QMP"]}]
    vwait ::response
    after cancel $timer
    fileevent $::channel readable {}
    if {[llength $::response] == 2 && [lindex $::response 0] eq "error"} {
        fail [lindex $::response 1]
    }
    if {[dict exists $::response error]} {
        fail [dict get $::response error desc]
    }
    dict get $::response return
}
proc key_event {key down} {
    json_object type [json_string key] data [json_object \
        key [json_object type [json_string qcode] data [json_string $key]] \
        down [json_bool $down]]
}
proc send_events {events} {
    set encoded [lmap event $events {json_object type [json_string [lindex $event 0]] data [lindex $event 1]}]
    send_request [request_json input-send-event [dict create events [json::write array {*}$encoded]]]
}
proc key_chord {chord} {
    array set aliases {super meta_l meta meta_l ctrl ctrl control ctrl shift shift alt alt}
    set keys [split [string tolower $chord] +]
    if {[llength $keys] < 1 || [lindex $keys end] eq ""} {fail "invalid key chord '$chord'"}
    set mapped {}
    foreach key $keys {
        if {[info exists aliases($key)]} {set key $aliases($key)}
        if {![regexp {^[a-z0-9_-]+$} $key]} {fail "invalid QMP key '$key'"}
        lappend mapped $key
    }
    set events {}
    foreach key $mapped {lappend events [list key [json_object key [json_object type [json_string qcode] data [json_string $key]] down [json_bool true]]]}
    foreach key [lreverse $mapped] {lappend events [list key [json_object key [json_object type [json_string qcode] data [json_string $key]] down [json_bool false]]]}
    send_events $events
}

if {$argc < 1} usage
set command [lindex $argv 0]
switch -- $command {
    status {
        if {$argc != 1} usage
        set result [send_request [request_json query-status]]
        puts "status=[dict get $result status] running=[dict get $result running]"
    }
    screenshot {
        if {$argc != 2 && $argc != 4} usage
        set output [file normalize [lindex $argv 1]]
        if {![file isdirectory [file dirname $output]]} {fail "output directory does not exist"}
        set arguments [dict create filename [json_string $output]]
        if {$argc == 4} {
            set device [lindex $argv 2]
            set head [lindex $argv 3]
            if {![regexp {^[A-Za-z0-9_.-]+$} $device]} {fail "invalid display device id"}
            if {![string is integer -strict $head] || $head < 0} {fail "display head must be a nonnegative integer"}
            dict set arguments device [json_string $device]
            dict set arguments head [json_number $head]
        }
        file delete -force $output
        send_request [request_json screendump $arguments]
        for {set attempt 0} {$attempt < 100} {incr attempt} {
            if {[file exists $output] && [file size $output] > 0} {puts $output; exit 0}
            after 50
        }
        fail "QEMU did not write $output"
    }
    key {
        if {$argc != 2} usage
        key_chord [lindex $argv 1]
    }
    motion {
        if {$argc != 3} usage
        foreach coordinate [lrange $argv 1 2] {if {![string is integer -strict $coordinate] || $coordinate < 0} {fail "coordinates must be nonnegative integers"}}
        set events {}
        foreach {axis value} [list x [lindex $argv 1] y [lindex $argv 2]] {
            lappend events [list abs [json_object axis [json_string $axis] value [json_number $value]]]
        }
        send_events $events
    }
    button {
        if {$argc != 3} usage
        set button [lindex $argv 1]
        set down [lindex $argv 2]
        if {$button ni {left right middle side extra}} {fail "unknown button '$button'"}
        if {$down ni {up down}} {fail "button state must be up or down"}
        send_events [list [list btn [json_object button [json_string $button] down [json_bool [expr {$down eq "down"}]]]]]
    }
    quit {
        if {$argc != 1} usage
        send_request [request_json quit]
    }
    execute {
        if {$argc != 2} usage
        if {[catch {json::json2dict [lindex $argv 1]}]} {fail "execute expects a JSON object"}
        set result [send_request [lindex $argv 1]]
        puts [json::dict2json $result]
    }
    trace {
        if {$argc != 3 || [lindex $argv 1] ni {on off}} usage
        set pattern [lindex $argv 2]
        if {![regexp {^[A-Za-z0-9_*?\[\]-]+$} $pattern]} {fail "invalid trace event pattern"}
        send_request [request_json trace-event-set-state [dict create \
            name [json_string $pattern] \
            enable [json_bool [expr {[lindex $argv 1] eq "on"}]] \
            ignore-unavailable [json_bool true]]]
    }
    default usage
}
close $channel
