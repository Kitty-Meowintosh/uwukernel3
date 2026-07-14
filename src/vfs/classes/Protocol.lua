local VFSProtocol = {};

VFSProtocol.Methods = {
    OPEN = "VFS_OPEN",
    CLOSE = "VFS_CLOSE",
    READ = "VFS_READ",
    WRITE = "VFS_WRITE",
    FLUSH = "VFS_FLUSH",
    SEEK = "VFS_SEEK",
    STAT = "VFS_STAT",
    LIST = "VFS_LIST",
    MKDIR = "VFS_MKDIR",
    REMOVE = "VFS_REMOVE",
    RENAME = "VFS_RENAME",
    COPY = "VFS_COPY",
    SETATTR = "VFS_SETATTR",
    IOCTL = "VFS_IOCTL"
}

VFSProtocol.Status = {
    OK = "OK",
    ERROR = "ERROR",
}

return VFSProtocol;