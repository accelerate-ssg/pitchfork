# Package

version       = "0.3.0"
author        = "Jonas Schubert Erlandsson, Claude"
description   = "Multi-language template engine: one bytecode VM, per-language frontends"
license       = "MIT"
srcDir        = "src"
installDirs   = @["pitchfork", "liquid", "liquid_lib"]

# Dependencies

requires "nim >= 1.6.12"

# The Liquid frontend renders against an arena context store, so that every
# context access can be tracked by node identity.
requires "git+ssh://git@github.com/accelerate-ssg/arena.git#v0.1.1"

# Tasks

task clib, "Build C shared library":
  exec "nim c --app:lib -d:release -o:libliquid.dylib src/liquid_c.nim"
