#!/bin/sh
# the next line restarts using tclsh \
        exec tclsh "$0" "$@"

set resolvedArgv0 [file dirname [file normalize $argv0/___]];  # Trick to resolve last symlink
set appname [file rootname [file tail $resolvedArgv0]]
set rootdir [file normalize [file dirname $resolvedArgv0]]
foreach module [list toclbox] {
    foreach search [list lib/$module ../common/$module] {
        set dir [file join $rootdir $search]
        if { [file isdirectory $dir] } {
            ::tcl::tm::path add $dir
        }
    }
}
foreach search [list lib/modules/w1] {
    set dir [file join $rootdir $search]
    if { [file isdirectory $dir] } {
        ::tcl::tm::path add $dir
    }
}
foreach module [list til] {
    foreach search [list lib/$module ../common/$module] {
        set dir [file join $rootdir $search]
        if { [file isdirectory $dir] } {
            lappend auto_path $dir
        }
    }
}


package require Tcl 8.6
package require toclbox
package require minihttpd
package require w1
set prg_args {
    -help       ""          "Print this help and exit"
    -verbose    "* DEBUG"   "Verbosity specification for program and modules"
    -period     "1M"        "Period for sensor value updates"
    -http       "http:8080" "List of protocols and ports for HTTP servicing"
    -aliases    ""          "Even-long list of pattern and nicknames for sensor aliasing"
    -authorization ""       "HTTPd authorizations (pattern realm authlist)"
}

namespace eval ::sensors {}

# ::help:dump -- Dump help
#
#       Dump help based on the command-line option specification and
#       exit.
#
# Arguments:
#	hdr	Leading text to prepend to help message
#
# Results:
#       None.
#
# Side Effects:
#       Exit program
proc ::help:dump { { hdr "" } } {
    global appname
    
    if { $hdr ne "" } {
        puts $hdr
        puts ""
    }
    puts "NAME:"
    puts "\t$appname - 1-wire data server"
    puts ""
    puts "USAGE"
    puts "\t${appname}.tcl \[options\] -- \[controlled program\]"
    puts ""
    puts "OPTIONS:"
    foreach { arg val dsc } $::prg_args {
        puts "\t[string range ${arg}[string repeat \  15] 0 15]$dsc (default: ${val})"
    }
    exit
}
# Did we ask for help at the command-line, print out all command-line
# options described above and exit.
toclbox pullopt argv opts
if { [toclbox getopt opts -help] } {
    ::help:dump
}

# Extract list of command-line options into array that will contain
# program state.  The description array contains help messages, we get
# rid of them on the way into the main program's status array.
array set ONEWIRE {
    servers {}
}
foreach { arg val dsc } $prg_args {
    set ONEWIRE($arg) $val
}
for { set eaten "" } {$eaten ne $opts } {} {
    set eaten $opts
    foreach opt [array names ONEWIRE -*] {
        toclbox pushopt opts $opt ONEWIRE
    }
}
# Remaining args? Dump help and exit
if { [llength $opts] > 0 } {
    ::help:dump "[lindex $opts 0] is an unknown command-line option!"
}
# Setup program verbosity and arrange to print out how we were started if
# relevant.
toclbox verbosity {*}$ONEWIRE(-verbose)
set startup "Starting $appname with following options\n"
foreach {k v} [array get ONEWIRE -*] {
    append startup "\t[string range $k[string repeat \  10] 0 10]: $v\n"
}
toclbox debug DEBUG [string trim $startup]

proc HowLong {len unit} {
    if { [string is integer -strict $len] } {
        switch -glob -- $unit {
            "\[Yy\]*" {
                return [expr {$len*31536000}];   # Leap years?
            }
            "\[Mm\]\[Oo\]*" -
            "m*" {
                return [expr {$len*2592000}]
            }
            "\[Ww\]*" {
                return [expr {$len*604800}]
            }
            "\[Dd\]*" {
                return [expr {$len*86400}]
            }
            "\[Hh\]*" {
                return [expr {$len*3600}]
            }
            "\[Mm\]\[Ii\]*" -
            "M" {
                return [expr {$len*60}]
            }
            "\[Ss\]*" {
                return $len
            }
        }
    }
    return 0
}


proc Duration { str } {
    set words {}
    while {[scan $str %s%n word length] == 2} {
        lappend words $word
        set str [string range $str $length end]
    }

    set seconds 0
    for {set i 0} {$i<[llength $words]} {incr i} {
        set f [lindex $words $i]
        if { [scan $f %d%n n length] == 2 } {
            set unit [string range $f $length end]
            if { $unit eq "" } {
                incr seconds [HowLong $n [lindex $words [incr i]]]
            } else {
                incr seconds [HowLong $n $unit]
            }
        }
    }

    return $seconds
}

proc ::dget { dic aliases {default ""}} {
    foreach key $aliases {
        if { [dict exists $dic $key] } {
            return [dict get $dic $key]
        }
    }
    return $default
}

proc ::w1:name {dev} {
    global ONEWIRE

    foreach {ptn name} $ONEWIRE(-aliases) {
        if { [string match $ptn $dev] } {
            return $name
        }
    }
    return $dev
}

proc ::w1:devices {prt sock url qry} {
    global ONEWIRE

    # Collect client headers
    if { [catch {::minihttpd::headers $prt $sock} hdrs] } {
        toclbox log warn "No headers available from client request: $hdrs"
        set hdrs {}
    }

    set family [dget $qry [list "family" "type"] "*"]
    set fmt [dget $qry [list "fmt" "format"] "txt"]
    switch -nocase -- $fmt {
        "json" {
            set json "\{"
            append json "\"devices\":\["
            foreach dev [onewire devices $family] {
                append json "\"[w1:name $dev]\","
            }
            set json [string trimright $json ","]
            append json "\]"
            append json "\}"
            return $json
        }
        "senml" {
            set json "\["
            foreach dev [onewire devices $family] {
                append json "\{"
                append json "\"n\":\"" [w1:name $dev] "\",\"u\":\"Cel\",\"v\":" [set ::sensors::$dev] ",\"t\":" [onewire when ::sensors::$dev]
                append json "\},"
            }
            set json [string trimright $json ","]
            append json "\]"
        }
        "txt" -
        default {
            set res ""
            foreach dev [onewire devices $family] {
                append res "[w1:name $dev]\n"
            }
            return [string trimright $res "\n"]
        }
    }
}

proc ::w1:value {prt sock url qry} {
    global ONEWIRE

    # Collect client headers
    if { [catch {::minihttpd::headers $prt $sock} hdrs] } {
        toclbox log warn "No headers available from client request: $hdrs"
        set hdrs {}
    }

    set dev [file tail $url]
    return [set ::sensors::$dev]
}

proc ::http:init { port } {
    global ONEWIRE
    
    toclbox log notice "Starting to serve HTTP request on port $port"
    set srv [::minihttpd::new "" $port -authorization $ONEWIRE(-authorization)]
    if { $srv < 0 } {
        return -1
    }
    
    set router {
        /get ::w1:devices
        /get/* ::w1:value
    }
    foreach { path handler } $router {
        ::minihttpd::handler $srv $path $handler "text/plain"
    }
    
    return $srv
}

proc ::htinit {} {
    global ONEWIRE
    
    foreach p $ONEWIRE(-http) {
        set srv -1
        
        if { [string is integer -strict $p] } {
            set srv [::http:init $p]
        } elseif { [string first ":" $p] >= 0 } {
            foreach {proto port} [split $p ":"] break
            switch -nocase -- $proto {
                "HTTP" {
                    set srv [::http:init $port]
                }
            }
        }
        
        if { $srv > 0 } {
            lappend ONEWIRE(servers) $srv
        }
    }
}

if { ! [string is integer -strict $ONEWIRE(-period)]} {
    toclbox debug NOTICE "Converting human-readable $ONEWIRE(-period)"
    set ONEWIRE(-period) [Duration $ONEWIRE(-period)]
}

toclbox https

foreach dev [onewire devices] {
    onewire bind $dev ::sensors::$dev $ONEWIRE(-period)
}
htinit

vwait forever