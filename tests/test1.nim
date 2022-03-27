import unittest
import macros
import os
import asyncdispatch

import watchdog

var running = true
var watchNum {.compileTime.} = 0
var watchCount = 0
macro watchtest(e): untyped =
  result = quote do:
    if watchCount == `watchNum`:
      `e`
      watchCount.inc
      return
  watchNum.inc
macro watchend(): untyped =
  result = quote do:
    if watchCount == `watchNum`:
      running = false
      return
      
suite "nimwatch":
  test "file":
    removeDir("testdir")
    createDir("testdir")
    proc callback (name: string, event: FileEvent, overflowed: bool): Future[void] =
      # echo "In callback"
      # name.echo
      # event.echo
      # overflowed.echo
          
    # feNameChangedNew
    # feNameChangedOld
      watchtest:
        check(event == feFileCreated)
        check(name == "abc.txt")
      # watchtest:
      #   check(event == feFileModified)
      #   check(name == "abc.txt")
      # watchtest:
      #   check(event == feFileCreated)
      #   check(name == "oh.txt")
      # watchtest:
      #   check(event == feFileModified)
      #   check(name == "oh.txt")
      # watchtest:
      #   check(event == feFileModified)
      #   check(name == "abc.txt")
      watchtest:
        check(event == feFileRemoved)
        check(name == "abc.txt")
      watchend
    discard watchDir("testdir", callback, allFileEvents, 8000)
      

    addTimer(500, true) do (fd: AsyncFD) -> bool:
      # drain()
      writeFile("testdir/abc.txt", "ABC")
      drain()
      # writeFile("testdir/oh.txt", "triple")
      # drain()
      # writeFile("testdir/abc.txt", readFile("testdir/abc.txt") & "DEF")
      # drain()
      removeFile("testdir/abc.txt")
      drain()
      # writeFile("testdir/end.txt", "")
      # drain()
      return true
    while running:
      poll()