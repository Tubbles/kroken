package main

// Command line entry point. Owns argument parsing, exit codes, and wiring
// between the library packages. See DESIGN.md for the run flow.

import "core:fmt"
import "core:os"

VERSION :: "0.1.0"

USAGE :: `usage: kroken <command> [flags]

commands:
  complete   read a selection, run claude, print the replacement
  config     print the effective configuration and its sources
  version    print the version
`

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprint(USAGE)
		os.exit(2)
	}
	switch os.args[1] {
	case "version":
		fmt.println("kroken", VERSION)
	case "-h", "--help", "help":
		fmt.print(USAGE)
	case:
		fmt.eprintf("kroken: unknown command %q\n\n", os.args[1])
		fmt.eprint(USAGE)
		os.exit(2)
	}
}
