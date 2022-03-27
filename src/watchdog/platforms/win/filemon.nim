import std / [os, asyncdispatch, winlean, sets]

import utils
{.pragma: libKernel32, stdcall, dynlib: "Kernel32.dll".}
proc cancelIo*(hFile: Handle): WINBOOL {.libKernel32, importc: "CancelIo".}

type
  FileNotifyInformation* = object
    NextEntryOffset*: DWORD
    Action*: DWORD
    FileNameLength*: DWORD
    FileName*: WideCString

when not declared(CustomOverlapped):
  type
      CustomOverlapped = object of OVERLAPPED
        data*: CompletionData
  when not declared(PCustomOverlapped):
    type
      PCustomOverlapped = ref CustomOverlapped
  when not declared(PtrCustomOverlapped):
    type 
      PtrCustomOverlapped = ptr CustomOverlapped
 
type 
  LPVOID* = pointer
  LPDWORD* = ptr DWORD
  LPOVERLAPPED* = ptr OVERLAPPED
  LPOVERLAPPED_COMPLETION_ROUTINE* = proc (dwErrorCode: DWORD, dwNumberOfBytesTransfered: DWORD,
                                             lpOverlapped: LPOVERLAPPED)

type
  FileEvent* = enum
    feFileCreated
    feFileRemoved
    # feFileModified
    # feNameChangedNew
    # feNameChangedOld

  FileEventCb* = proc (
    fileName: string, 
    eventKind: FileEvent,
    bufferOverflowed: bool
  ): Future[void]

  ChangeHandle* = ref object
    kind*: PathComponent
    callback: FileEventCb
    handle: Handle
    cancelled: bool

  WatchData = ref object
    handle: Handle
    buffer: string
    ol: PCustomOverlapped

const
  allFileEvents* = {FileEvent.low .. FileEvent.high}

const FILE_ACTION_ADDED* = 0x00000001
const FILE_ACTION_REMOVED* = 0x00000002
const FILE_ACTION_MODIFIED* = 0x00000003
const FILE_ACTION_RENAMED_OLD_NAME* = 0x00000004
const FILE_ACTION_RENAMED_NEW_NAME* = 0x00000005
const ERROR_OPERATION_ABORTED* = 995
const ERROR_NOTIFY_ENUM_DIR* = 1022

proc ReadDirectoryChangesW*(hDirectory: HANDLE, lpBuffer: LPVOID, nBufferLength: DWORD, bWatchSubtree: WINBOOL, dwNotifyFilter: DWORD, lpBytesReturned: LPDWORD, lpOverlapped: LPOVERLAPPED, lpCompletionRoutine: LPOVERLAPPED_COMPLETION_ROUTINE): WINBOOL {. stdcall, dynlib: "kernel32", importc.}

proc toWINBOOL(b: bool): WINBOOL = cast[WINBOOL](b)
proc initWatchData(handle: Handle, bufferSize: int): WatchData =
  ## Initializes a watch data object. **Note**: The overlapped structure's
  ## refcount is incremented. You **must** use the cleanup procedure
  ## to cleanup the data's internal structures.
  new(result)
  new(result.ol)

  result.handle = handle
  result.ol.data.fd = AsyncFd(handle)
  result.buffer = newString(bufferSize)
  GC_ref(result.ol)

proc initWatchData(handle: Handle, bufferSize: int, cb: proc): WatchData =
  result = initWatchData(handle, bufferSize)
  result.ol.data.cb = cb

proc toFileEvent(action: DWORD): FileEvent =
  case action
  of FILE_ACTION_ADDED:
    result = feFileCreated
  of FILE_ACTION_REMOVED:
    result = feFileRemoved
  # of FILE_ACTION_MODIFIED:
  #   result = feFileModified
  # of FILE_ACTION_RENAMED_OLD_NAME:
  #   result = feNameChangedNew
  # of FILE_ACTION_RENAMED_NEW_NAME:
  #   result = feNameChangedOld
  else:
    raise newException(ValueError, "Invalid file action: " & $action)

proc toDword(actions: set[FileEvent]): DWORD =
  for a in actions:
    case a
    of feFileCreated:
      result = result or FILE_ACTION_ADDED # Any file name change in the watched directory or subtree causes a change notification wait operation to return. Changes include renaming, creating, or deleting a file.
    of feFileRemoved:
      result = result or FILE_ACTION_REMOVED # Any directory-name change in the watched directory or subtree causes a change notification wait operation to return. Changes include creating or deleting a directory.
    # of feFileModified:
    #   result = result or FILE_ACTION_MODIFIED
    # of feNameChangedNew:
    #   result = result or FILE_ACTION_RENAMED_OLD_NAME
    # of feNameChangedOld:
    #   result = result or FILE_ACTION_RENAMED_NEW_NAME

proc callChanges(w: WatchData, bufferSize: DWORD,
                 filter: DWORD, recursive=true): WinBool =
  result = ReadDirectoryChangesW(
    w.handle,
    cast[LPVOID](w.buffer.cstring),
    bufferSize,
    toWINBOOL(recursive),
    filter,
    cast[ptr DWORD](nil),
    cast[POverlapped](w.ol),
    nil
  )

iterator getChanges(buffer: pointer): tuple[path: string, event: FileEvent] =
  var
    data = cast[ptr FileNotifyInformation](buffer)
    result: tuple[path: string, event: FileEvent]
  result.path = ""

  while true:
    # We loop through the data buffer, parsing each chunk of data, then
    # moving to the next chunk of data via the offset.
    let
      offset = data.NextEntryOffset
      nameLength = data.FileNameLength div sizeof(Utf16Char)
    result.path.setLen(nameLength)
    result.path = `$`(data.FileName, nameLength)
    result.event = data.Action.toFileEvent()
    yield result

    if offset == 0:
      break
    data = cast[ptr FileNotifyInformation](cast[int](data) + offset)

proc cleanup(data: var WatchData) =
  GC_unref(data.ol)
  unregister(AsyncFD(data.handle))
  discard closeHandle(data.handle)
  data.ol.data.reset()
  data.ol = nil

proc watchDir*(target: string, callback: FileEventCb, filter: set[FileEvent],
               bufferLen: int, recursive=true): ChangeHandle {.discardable.} =
  ## Watch a directory for changes, using ReadDirectoryChangesW
  ## on Windows, inotify on Linux, and KQueues on OpenBSD/MacOSX. Note that
  ## although this procedure attempts to abstract away the behavioral
  ## differences in file event notifications across various platforms, there
  ## are still some differences in the behavior of this procedure across
  ## platforms.
  new(result)
  var
    res = result
    targetPath = target
    targetHandle = openDirHandle(targetPath)

    bufferSize = DWORD(bufferLen * sizeOf(char))
    rawFilter = toDword(filter) # Filter passed to readDirectoryChanges

    liveWatch: WatchData

  proc rawEventCb(sock: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) {.closure, gcsafe.} =
    # GC_fullcollect()
    GC_ref(liveWatch.ol)
    assert(Handle(sock) == liveWatch.handle)

    var overflowed: bool
    if errcode == OSErrorCode(ERROR_OPERATION_ABORTED):
      cleanup(liveWatch)
      liveWatch = nil
      return
    elif errcode == ERROR_NOTIFY_ENUM_DIR.OSErrorCode:
      overflowed = true

      # Things to do if we aren't cancelled
    if not res.cancelled:
      for path, event in getChanges(cast[pointer](liveWatch.buffer)):
        if res.cancelled:
          break
        discard callback(path, event, overflowed)
      if callChanges(liveWatch, bufferSize, rawFilter) == toWINBOOL(false):
        let error = osLastError()
        cleanup(liveWatch)
        raiseOSError(error)
    if res.cancelled:
      discard cancelIo(targetHandle)

  # GC_ref(ol)
  echo targetHandle
  liveWatch = initWatchData(targetHandle, bufferLen, rawEventCb) # The current watch
  register(AsyncFD(targetHandle))
  let called = callChanges(liveWatch, bufferSize, rawFilter)
  echo called
  if called == toWINBOOL(false):
    let error = osLastError()
    cleanup(liveWatch)
    raiseOSError(error, "callChanges(ReadDirectoryChangesW) fails")

  result.kind = pcDir
  result.handle = targetHandle
  result.callback = callback

proc watchFile*(target: string, callback: FileEventCb, filter: set[FileEvent],
                bufferLen: int): ChangeHandle =
  ## Watch a file for changes, using ReadDirectoryChangesW plus a custom filter
  ## on Windows, inotify on Linux, and KQueues on OpenBSD/MacOSX. Note that
  ## although this procedure attempts to abstract away the behavioral
  ## differences in file event notifications across various platforms, there
  ## are still some differences in the behavior of this procedure across
  ## platforms.
  new(result)
  result.cancelled = false
  var
    res = result
    targetPath = target
    targetName = extractFileName(target)
    parentPath = parentDir(targetPath)
    targetHandle = openFileHandle(targetPath)
    parentHandle = openDirHandle(parentPath)

    bufferSize = DWORD(bufferLen * sizeOf(char))
    rawFilter = toDword(filter) # Filter passed to readDirectoryChanges

    liveWatch: WatchData
    deadWatches = newSeq[WatchData]() # Sequence of dead watch data
    lastEventWasRenamed = false

  proc rawEventCb(sock: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) {.closure, gcsafe.} =
    # GC_fullcollect()
    var selectedWatch: WatchData # The watch that the socket belongs to.

    # Locate the set of data associated with the handle, and act upon it accordingly
    if Handle(sock) == liveWatch.handle:
      selectedWatch = liveWatch

      # Prevent the overlapped structure in the watch data from being collected:
      GC_ref(selectedWatch.ol)

      # Handle error codes
      var overflowed: bool
      if errcode == OSErrorCode(ERROR_OPERATION_ABORTED):
        cleanup(liveWatch)
        liveWatch = nil
        return
      elif errcode == ERROR_NOTIFY_ENUM_DIR.OSErrorCode:
        overflowed = true

      # Things to do if we aren't cancelled
      if not res.cancelled:

        # Handle file events
        # Change target name when overflowed, file deleted, or renamed
        for path, event in getChanges(cast[pointer](liveWatch.buffer)):
          if res.cancelled:
            break
          # elif cmpPaths(targetName, extractFileName(path)) == 0:
          #   lastEventWasRenamed = (event == feNameChangedNew)
          #   discard callback(path, event, overflowed)
          elif lastEventWasRenamed:
            discard callback(path, event, overflowed)
            lastEventWasRenamed = false

        # Handle parent-child synchronization
        let
          newTargetPath = getPath(targetHandle)
          newParentPath = parentDir(newTargetPath)

        if cmpPaths(getPath(parentHandle), newParentPath) != 0:
          shallowAssign(targetPath, newTargetPath)
          shallowAssign(parentPath, newParentPath)
          parentHandle = openDirHandle(newParentPath)
          deadWatches.add(liveWatch)

          liveWatch = initWatchData(parentHandle, bufferLen, rawEventCb)
          register(AsyncFD(liveWatch.handle))
          discard callChanges(selectedWatch, bufferSize, rawFilter)
          discard cancelIo(selectedWatch.handle)
      if callChanges(liveWatch, bufferSize, rawFilter) == toWINBOOL(false):
        let error = osLastError()
        cleanup(liveWatch)
        raiseOSError(error, "callChanges(ReadDirectoryChangesW) fails")
      if res.cancelled:
        discard cancelIo(parentHandle)

    else:
      # Find the corresponding watch
      var
        dataIndex: int
      for index, watch in deadWatches:
        if Handle(sock) == watch.handle:
          selectedWatch = watch
          break

      # Prevent the overlapped structure in the watch data from being collected:
      GC_ref(selectedWatch.ol)

      # Handle the events
      if errcode == OSErrorCode(ERROR_OPERATION_ABORTED):
        cleanup(selectedWatch)
        deadWatches.delete(dataIndex)
        return
      discard callChanges(selectedWatch, bufferSize, rawFilter)
      discard cancelIo(selectedWatch.handle)


  # GC_ref(ol)
  liveWatch = initWatchData(parentHandle, bufferLen, rawEventCb) # The current watch


  register(AsyncFD(parentHandle))
  if callChanges(liveWatch, bufferSize, rawFilter) == toWINBOOL(false):
    let error = osLastError()
    cleanup(liveWatch)
    raiseOSError(error, "callChanges(ReadDirectoryChangesW) fails")

  result.kind = pcFile
  result.handle = targetHandle
  result.callback = callback

when isMainModule:
  proc echoBack(name: string, event: FileEvent, overflowed: bool): Future[void] =
    echo "In callback"
    name.echo
    event.echo
    overflowed.echo

  # sleep(10000)
  let handle = watchFile(r"C:\Users\Clay\Projects\Nimrod-Scripts\testFolder\testFile.txt", echoBack, allFileEvents, 8000)
  runForever()