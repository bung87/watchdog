import winlean, os

type
  AlignedBuffer* = object
    base*: pointer
    start*: pointer

const FILE_LIST_DIRECTORY* = (0x00000001) ##  directory

proc shallowAssign*(dest: var string, source: string) {.inline.} =
  if dest.len() >= source.len():
    dest.setLen(source.len())
    copyMem(cast[pointer](dest), cast[pointer](source), dest.len()*sizeof(char))
  else:
    dest = source

proc GetFinalPathNameByHandle(hFile: Handle,  lpszFilePath: pointer,
                              cchFilePath, dwFlags: DWORD): DWORD
  {.stdcall, dynlib: "kernel32", importc: "GetFinalPathNameByHandleW".}

proc getPath*(h: Handle, initSize = 80): string =
  ## Retrieves a path from a handle.
  var
    lastSize = initSize
    buffer = alloc0(initSize * sizeOf(WinChar))

  while true:
    let bufSize = GetFinalPathNameByHandle(h, buffer, DWORD(lastSize), DWORD(0))
    if bufSize == 0:
      raiseOSError(osLastError(), "GetFinalPathNameByHandle results zero")
    elif bufSize > lastSize:
      buffer = realloc(buffer, (bufSize + 1) * sizeOf(WinChar))
      lastSize = bufSize + 1
      continue
    else:
      break
  buffer = cast[pointer](cast[int](buffer))
  result = $cast[WideCString](buffer)
  dealloc(buffer)


proc openDirHandle*(path: string, followSymlink=true): Handle =
  ## Open a directory handle suitable for use with ReadDirectoryChanges
  let accessFlags = FILE_SHARE_DELETE or FILE_SHARE_READ or FILE_SHARE_WRITE
  var modeFlags = FILE_FLAG_BACKUP_SEMANTICS or FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OVERLAPPED
  if not followSymlink:
    modeFlags = modeFlags or FILE_FLAG_OPEN_REPARSE_POINT

  when useWinUnicode:
    result = createFileW(newWideCString(path), FILE_LIST_DIRECTORY, accessFlags,
                         nil, OPEN_EXISTING, modeFlags, Handle(0))
  else:
    result = createFileA(path, FILE_LIST_DIRECTORY, accessFlags,
                         nil, OPEN_EXISTING, modeFlags, Handle(0))

  if result == INVALID_HANDLE_VALUE:
    raiseOSError(osLastError(), "createFile results invalid handle.")


proc openFileHandle*(path: string, followSymlink=true): Handle =
  var flags = FILE_FLAG_BACKUP_SEMANTICS or FILE_ATTRIBUTE_NORMAL
  if not followSymlink:
    flags = flags or FILE_FLAG_OPEN_REPARSE_POINT

  when useWinUnicode:
    result = createFileW(
      newWideCString(path), 0'i32, 
      FILE_SHARE_DELETE or FILE_SHARE_READ or FILE_SHARE_WRITE,
      nil, OPEN_EXISTING, flags, 0
      )
  else:
    result = createFileA(
      path, 0'i32, 
      FILE_SHARE_DELETE or FILE_SHARE_READ or FILE_SHARE_WRITE,
      nil, OPEN_EXISTING, flags, 0
      )
  if result == INVALID_HANDLE_VALUE:
    raiseOSError(osLastError(), "createFile results invalid handle.")
