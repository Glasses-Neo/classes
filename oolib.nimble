# Package

version       = "0.6.1"
author        = "Glasses-Neo"
description   = "A nimble package which provides user-defined types, procedures, etc..."
license       = "WTFPL"
srcDir        = "src"


# Dependencies

requires "nim >= 2.0.0"

task tests, "Run all tests":
  exec "testament p 'tests/**.nim'"

task show, "Show testresults":
  exec "testament html"
  exec "open testresults.html"
