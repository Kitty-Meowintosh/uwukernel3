When I started this project, I decided to start by writing every syscall api and details about them. It helps with planning, scope and idea of how systems should interact and behave.
- 00-31: Process & Task Management
- 32-63: IPC
- 64-95: FIlesystem & I/O
- 96-127: System and Hardware
- 128-159: Synchronisation

Its a very rough file.

### Process & Task Management
---
`0` | `proc.spawn(path: string, args: string[]?, attributes: table?) -> pid: number`
Creates new process in one atomic method. Analogue of `posix_spawn`.

 **Arguments:**
`path`: Path to executable (Lua).
`args`: (Optional) Array of arguments
`attributes`: (Optional) Array of attributes, by default inherited.
- `env: table`- Table of environment variables
- `cwd: string`- Working directory path
- `fds: table`- Map of file descriptors
- `uid: number`-  Run as user (requires root)
- `gid: number`- Run as group (requires root)
- `groups: number[]` - Run with supplementary groups (requires root)
- `name: string`- Debug name for process list
- `limits: table` - limits for a child process, view `proc.limit` for more.
- `blob: string` - source to run from, if defined - process will run this as main task instead of reading source from path.
- `preload: table` - injects into package.preload of a child, those modules will run as part of child environment.

**Returns:**
`pid`: PID of child process.

**Errors:**
1. File on path not found.
2. Permission denied.
3. Too many processes.
4. Attempting to raise limits with no root permission.

---
`1` | `proc.exit(code: number) -> void`
Terminates calling process. Closes all owned handles/ports.

 **Arguments:**
`code: number` - Exit status (0 = success, >0 = error)

---
`2` | `proc.wait(pid: number, opts?: table) -> pid, code, usage | nil`
Blocks until child process exits.

 **Arguments:**
`pid`: PID of child to wait for, `-1` to wait for any child
`opts: (Optional):
- `nohang: boolean` - if true, returns immediately if no child has exited

**Returns:**
- `pid` - PID of process that exited.
- `code` - exit status of process that exited.
- `usage` - CPU time of process that exited.
OR
- `nil` - returned if `nohang` is active, and no child process exited.

**Errors:**
1. If caller has no child processes

---
`3` | `proc.kill(pid: number, signal: number) -> void`
Sends a control signal to the process.

**Arguments:**
 `pid` - process to send signal to
 `signal` - desired signal to be sent to the process

**Errors:**
1. If caller has no permission
2. If process was not found
   
---
`4` | `proc.info(pid?: number) -> table`
Returns metadata of process. If `pid` is nil - returns metadata of process itself.

 **Arguments:**
`pid` - PID of process to get metadata of.

**Returns:**
- `{ pid, ppid, uid, gid, state, groups, name, cpuTime, children, limits }` - process metadata

**Errors:**
1. if process was not found.

---
`5` | `proc.setattr(attr: table) -> void`
Changes attributes of running process.

 **Arguments:**
`attr`:
- `uid: number` - change user id (root-only)
- `gid: number` - change group id (root-only)
- `groups: number[]` - set supplementary groups
- `cwd` - change working directory

**Errors:**
1. Caller is not root (cannot change uid/gid).
2. Permission denied (if changing cwd).

---
`6` | `proc.limit(resource: string, value: number) -> void`
Sets strict limits for calling process (they are inherited by children). Limits cannot be raised without root permissions, but can be decreased at will.

 **Arguments:**
`resource`:
	- `maxFiles` - Max open file descriptors
	- `maxPorts` - Max open ports
	- `maxProcesses` - Max running child processes
	- `maxThreads` - Max running threads
`value` - limit (must be integer)

**Errors:**
1. No permissions
2. Invalid resource name
3. Invalid value
   
---
`7` | `proc.yield() -> void`
Voluntary gives up slice of CPU time.

> REDUNDANT AND REMOVED.

---
`8` | `proc.list() -> number[]`
Gets list of all active process ids in system.

---
`9` | `task.create(entry: function, args?: any[]) -> tid: number`
Creates a new thread (coroutine) within the current process.
The new thread shares the same environment (`_G`) and file descriptors with parent, but is scheduled independently by kernel.

 **Arguments:**
`entry` - the Lua function to execute. 
`args`- table of arguments to pass to `entry` when it starts.

**Returns:**
`tid` - unique id for a new thread.

**Errors:**
1. Process reached a thread limit.
2. `entry` is not a function.

---
`10` | `task.join(tid: number) -> success: boolean, ...results`
Blocks the calling thread until the target thread `tid` terminates.

 **Arguments:**
`tid` - id of the thread to wait for.

**Returns:**
`success`: `true` if the thread finished normally, `false` if it crashed.
`...results`: The return values of the thread function (if successful) or the error message (if failed).

**Errors:**
1. Thread not found.
2. Attempting to join yourself.

---
`11` | `task.id() -> tid: number`
Returns the thread id of the calling thread.

**Returns:**
`tid` - the current thread id.

---
`12` | `task.list() -> tid: number[]` 
Returns a list of all active threads belonging to the current process.

**Returns:** 
`tid`- Array of Thread IDs.

### IPC
---
`32` | `ipc.create() -> port: number`
Creates a new port kernel object. Calling process receives **receive right**.

**Returns:**
`port` - id pointing towards created port

**Errors:**
1. Process have reached limit on ports

---
`33` |  `ipc.send(port: number, msg: table, opts?: table) -> void`
Sends a message to a port. This is non-blocking by default, unless queue is full.

 **Arguments:**
 `port` - Port to use when sending message.
 `msg` - Data you want to send.
`opts`:
- `timeout: number` - Max wait time in seconds, if queue is full. `0` to fail immediately.
- `reply_port: number` - A handle to send back to the receiver.
- `transfer: number[]` - List of handles to move to the receiver. Kernel removes them from caller and creates new handles in the receiver space.
- `type: string` - Event type, used for filtering, default is `"IPC"`.

(Note: when handles are transferred, they are copied (kernel object is not actually copied tho), with exception of ports with receive right. Using transfer to pass port will give up your receive right. To grant another process right to send messages to the port - use `ipc.transfer` instead)

**Errors:**
1. Invalid handle.
2. Queue is full and timeout expired.

---
`34` | `ipc.receive(port: number, opts?: table) -> msg: table`
Blocks until a message arrives on specific port.

 **Arguments:**
`port` - handle identifying the port. 
`opts`:
- `timeout: number` - Max wait time in seconds.
-  `types: string[]` - Only wake up for messages  where `msg.type` matches one of strings. (e.g. `{ "timer", "key" }`)

**Returns:**
`msg`:
- `pid: number` - process id of sender
- `reply: number | nil` - id of a handle to send reply to, provides temporary reply right.
- `handles: number[] | nil` - list of handles transferred to a process.
- `data: table` - data transferred by another process, may contain anything.

**Errors:**
1. Timeout reached

---
`35` | `ipc.transfer(pid: number, port: number) -> void`
Manually grants a send right for specific port to another process.

> REDUNDANT AND REMOVED.

 **Arguments:**
`pid` - target process id.
`port` - handle to share.

**Errors:**
1. Invalid target pid
2. Invalid port handle

---
`36` | `ipc.close(port: number) -> void`
Releases a handle.

 **Arguments:**
`port` - handle to close. 

---
`37` | `ipc.stat(port: number) -> table`
Returns debug information about a port.

 **Arguments:**
`port` - handle to inspect.

**Returns:**
`{ messages: number, capacity: number }`
- `messages` - number of items in queue

**Errors:**
1. Invalid port handle

### Filesystem and I/O
---
`64` | `fs.open(path: string, mode: string) -> fd: number`
Opens a file or device.

 **Arguments:**
`path` - absolute path to the file.
`mode`:
- `"r"` - read-only (start at beginning).
- `"w"` - write
- `"a"` - append
- `"r+" - read/write`

**Returns:**
`fd` - handle id of file descriptor

**Errors:**
1. File not found.
2. Permission denied.
3. Path is a directory (use `fs.list` instead).
4. File a locked.

---
`65` | `fs.close(fd: number) -> void`
Closes the file descriptor. Releases any locks.

 **Arguments:**
`fd` - handle to close

---
`66` | `fs.read(fd: number, count: number, offset?: number) -> data: string | nil`
Reads data from the file.

 **Arguments:**
`fd` - the file descriptor.
[//]: # (`fmt` - reading mode:)

[//]: # (	`number`: Read exact amount of bytes &#40;or until EOF&#41;.)

[//]: # (	 `"*l"`: Read until the end of line.)

[//]: # (	 `"*a"`: Read all of file contents starting from cursor.)
`count` - number of bytes to read (or until EOF).
`offset` - if provided, performs a pread.

**Returns:**
`data` - the string to read, `nil` if reached EOF.

**Errors:**
1. Invalid file descriptor.
2. Attempting to read directory.

---
`67` | `fs.write(fd: number, data: string, offset?: number) -> count: number`
Writes data to a file.

 **Arguments:**
`fd` - the file descriptor. 
`data` - the string to write.
`offset` - if provided, performs a pwrite (writes to this absolute position, ignoring/not-moving cursor).

**Returns:**
`count`: Number of bytes written.

**Errors:**
1. Invalid FD or opened in read-only mode.
2. Disk full.

---
`68` | `fs.seek(fd: number, offset: number, whence?: string) -> new_pos: number`
Moves cursor.

 **Arguments:**
`fd` - the file descriptor.
`offset` - number of bytes to move
`whence` (default `"cur"`):
- `"set" or 0` - absolute position (from start).
- `"cur" or 1` - relative to current position.
- `"end" or 2` - relative to file end.

**Returns:**
`new_pos` - new absolute position.

---
`69` | `fs.stat(path: string) -> metadata: table`
Retrieves metadata about a file or directory.

 **Arguments:**
`path` - path to object.

[//]: # (`opts`:)

[//]: # (- `follow: boolean` &#40;default: `true`&#41;, if false, returns info about symlinks themselves &#40;lstat&#41;)

**Returns:**
`metadata`:
- `uid: number` - owner of file
- `gid: number - owner of file
- `size: number` - size of file
- `isDir: boolean` - if file is directory
- `isLink: boolean` - if file is a symlink
- `created: number` - time when file was created
- `modified: number` - time when file was last modified
- `accessed: number` - time when file was last read
- `linkTarget: string` - path link points to (if file is symlink)
- `permissions: table` - file permissions

> [!NOTE]
> Permissions structure looks like this:
> ```lua
> {
> 	-- For people who prefer using octal
> 	-- And in cases when performance is required, as its actually the only one generated by default.
> 	raw = 0o755,
> 
> 	-- String version for people who like it, or are used to default linux way, when accessed it is generated from octal value
> 	string = "rwxr-xr-x",
> 
> 	-- Structured object (for most people)
> 	user = { read = true, write = true, execute = true },
> 	group = { read = true, write = false, execute = true},
> 	other = { read = true, write = false, execute = true },
> 	
> 	-- Special flags
> 	setuid = false,
> 	setgid = false,
> 	sticky = false
>		
> }
> ```
>

**Errors:**
1. Path not found.
2. Permission denied.

---
`70` | `fs.list(path: string) -> string[]`
Lists entries in a directory.

 **Arguments:**
`path`: Directory path.

**Returns:**
Array of filenames.

**Errors:**
1. Path is not directory.
2. Path not found.
3. Permission denied.

[//]: # (---)

[//]: # (`71` | `fs.manage&#40;cmd: string, path: string, arg?: string&#41; -> void`)

[//]: # (Consolidated file management operations.)

[//]: # ()
[//]: # ( **Arguments:**)

[//]: # (`cmd` - operation type:)

[//]: # (- `"MKDIR"` - create directory.)

[//]: # (- `"RM"` - delete file or directory.)

[//]: # (- `"MV"` - move/rename &#40;`arg` is destination path&#41;.)

[//]: # (- `"CP"` - copy &#40;`arg` is destination path&#41;.)

[//]: # (- `"SYMLINK"` - create a symbolic link at `path` pointing to `arg`.)

[//]: # (`path` - target path.)

[//]: # (`arg` - second argument, if required by `cmd`.)

[//]: # (`**Errors:**)

[//]: # (1. Target already exists &#40;for MKDIR/MV&#41;.)

[//]: # (2. Removing a non-empty directory.)

[//]: # (3. File not existing &#40;RM, MV, CP&#41;)

[//]: # (4. Permission denied)

[//]: # (5. Filesystem not supporting symlinks`)

---
`72` | `fs.ioctl(fd: number, cmd: string, ...args) -> any`
Sends a raw command to the underlying driver.

 **Arguments:**
`fd` - handle to the device.
`cmd` - driver-specific command.
`...args` - variable arguments passed to driver.

**Returns:**
Values returned by driver.

**Errors:**
1. No permission
2. File descriptor is a file, and not a device

---
`73` | `io.pipe() -> read_fd, write_fd`
Creates unidirectional byte stream. Data written to `write_fd` can be read from `read_fd`.

**Returns:**
`read_fd` - read part of a pipe.
`write_fd` - write part of a pipe.

---
`74` | `io.dup(old_fd: number, new_fd: number) -> void`
Duplicates file descriptor.

 **Arguments:**
`old_fd` - file descriptor to copy.
`new_fd` - id of new file descriptor, can be used to override existing file descriptors.

---
`75` | `fs.mount(path: string, port: number) -> void`
Mounts a filesystem driver to a specific path.

 **Arguments:**
`path` - directory to be mounted, must exist and be empty.
`port` - IPC handle of the driver process.

**Errors:**
1. Invalid port
2. Invalid path, non-empty path, non-existing path
3. No permission (root-only)

---
`76` | `fs.unmount(path: string) -> void`
Unmount a filesystem driver from a specific path.

 **Arguments:**
`path` - absolute path to unmount.

**Errors:**
1. Path is not a mount point.
2. Files are open inside this mount.
3. No permission (root-only)

---
`77` | `fs.setaddr(path: string, attr: table) -> void`
Changes the metadata of a file or directory.

 **Arguments:**
`path` - path to file attributes of which to change.
`attr`:
- `mode: number` - new permissions
- `uid: number` - new owner (root-only)
- `gid: number` - new group (root-only)
- `modified: number` - new modification timestamp
- `created: number` - new creation timestamp
- `accessed: number` - new accessed timestamp

**Errors:**
1. Invalid path
2. No permissions
3. Invalid permissions

---
`78` | `fs.rename(path: string, destination: string) -> void`
Moves (or renames) file.
**Arguments:**
`path` - path to file that is to be moved
`destination` - destination of move

**Errors:**
1. Invalid path
2. Invalid destination
3. Invalid permissions

---
`79` | `fs.copy(path: string, destination: string) -> void`
Copies file.
**Arguments:**
`path` - path to file that is to be copy
`destination` - destination to copy to

**Errors:**
1. Invalid path
2. Invalid destination
3. Invalid permissions

---
`80` | `fs.remove(path: string) -> void`
Removes file.
**Arguments:**
`path` - path to file that has to be removed

**Errors:**
1. Invalid path
2. Invalid permissions

---
`81` | `fs.mkdir(path: string) -> void`
Creates directory at path.
**Arguments:**
`path` - path to new directory

**Errors:**
1. Invalid path
2. Invalid permissions

### System & Hardware
---
`96` | `sys.epoch(locale) -> number`
Returns number of milliseconds since an epoch depending on locale.

If called with `ingame`, returns the number of _in-game_ milliseconds since the world was created. This is the default.
If called with `utc`, returns the number of milliseconds since 1 January 1970 in the UTC timezone.
If called with `local`, returns the number of milliseconds since 1 January 1970 in the server's local timezone.

 **Arguments:**
`locale` - locale to get time for, defaults to `ingame` if not set.

**Returns:**
`number` - milliseconds since the epoch, depending on locale.

**Errors:**
1. Invalid locale provided.

---
`97` | `sys.timer(port: number, duration: number, cookie?: any) -> id: number`
Starts a system timer that fires after `duration` seconds.

 **Arguments:**
`port` - file descriptor pointing towards the port, which will receive relevant timer.
`duration` - time in seconds until timer should fire.
`cookie` - optional payload.

**Returns:**
`id` - id of a timer. Can be used for cancelling or distinguishing timers.

> [!NOTE]
> Payload of a timer should look like this:
> ```lua
> {
> 	type = "TIMER",
> 	id = 0, -- id of a timer
> 	cookie = "anything here...", -- your cookie
> ```

---
`98` | `sys.alarm(time: number) -> id: number`
Sets an alarm for a specific in-game time (0.0 to 24.0).

 **Arguments:**
`time` - time for alarm to be set to, between 0.0 and 24.0.

**Returns:**
`id` - id of alarm. 

---
`99` | `sys.cancel(id: number) -> void`
Cancel timer or alarm based on file descriptor.

 **Arguments:**
`id` - id of alarm or timer to be cancelled.

---
`100` | `sys.log(level: string, msg: string) -> void`
Writes a message to kernel ring buffer. This buffer is stored separately employing native CraftOS fs API. Can be used for driver debugging, in case of system not launching / crashing.

 **Arguments:**
`level` - log severity (`"INFO"`, `"WARN"`, `"ERROR"`).
`msg` - message content.

---
`101` | sys.info() -> table
Returns a table containing global system information.

**Returns:**
`table`:
	`version: string` - OS version, as well as native ComputerCraft version.
	`uptime: number` - Time since computer was started.

---
`102` | sys.bind_event(event: string, port: number) -> void
Subscribes a port to a specific raw ComputerCraft event type.
Once bound, kernel intercepts all events of this type and routes them exclusively to the specified port as IPC messages. Requires root.

 **Arguments:**
`event` - event name.
`port` - handle id of the port to receive events.

**Errors:**
1. Event type is already bound to another port.
2. No permissions.
3. Invalid port handle.

---
`103` | sys.unbind_event(event: string) -> void
Releases the exclusive subscription for an event type. Event will return to being ignored. Requires root.

 **Arguments:**
`event` - event name.

**Errors:**
1. Event was not found.
2. No permissions.

---
`104` | sys.shutdown() -> void
Shuts down the computer. Requires root permissions.

**Errors:**
1. No permissions.

---
`105` | sys.reboot() -> void
Reboots the computer. Requires root permissions.

**Errors:**
1. No permissions.

---
`106` | `dev.open(name: string) -> handle: number`
Wraps a native ComputerCraft peripheral into a kernel handle. This allows user-space driver to claim a hardware device.

**Arguments:**
`name` - The network / side name of a peripheral.

Returns:
`handle` - An id of a handle pointing to native device.

**Errors:**
1. Peripheral not found.
2. No root permissions.
3. Process handle limit reached.

---
`107` | `dev.call(handle: number, method: string, ...) -> any`
Calls a method on an already-opened device handle.

**Arguments:**
`handle` - Handle returned by `dev.open`.
`method` - Method name to call.
`...` - Arguments forwarded to the device's method.

**Errors:**
1. Invalid file descriptor.
2. File descriptor is not a device.

---
`108` | `dev.list() -> string[]`
Returns a list of all attached peripheral names. Root only.

**Returns:**
Names of devices returned.

**Errors:**
1. No permissions.

---
`109` | `dev.type(name: string) -> type: string`
Returns type of attached peripheral. Root only.

**Attributes:**
`name` - peripheral type of which we want to know.

**Returns:**
`type` - type of peripheral.

**Errors:**
1. No permissions.

---
`110` | `dev.methods(name: string) -> string[]`
Returns the list of methods available on the peripheral. Root only.

**Attributes:**
`name` - peripheral methods of which we want to know.

Returns:
Names of methods returned.

**Errors:**
1. No permissions.

---
`111` | `sys.signal(signal: number, port: number) -> void`
Asks system to send signals with this id to respective port, overrides default behaviour.
Default signals and their behaviour:

| Id  | Name    | Description                                    | Default action    | Args        |
| --- | ------- | ---------------------------------------------- | ----------------- |-------------|
| 1   | SIGHUP  | Sent when device (peripheral) is disconnected. | Terminate         | device_name |
| 2   | SIGINT  | Sent to cancel current action                  | Terminate         |             |
| 17  | SIGCHLD | Sent when child dies                           | None              | pid, status |
| 13  | SIGPIPE | Sent when pipe or port disconnects             | Terminate         | fd          |
| 19  | SIGSTOP | Stops process temporary (to be added later)    | Unstoppable force |             |
| 18  | SIGCONT | Continues process (to be added later)          | Unstoppable force |             |
| 9   | SIGKILL | Kills process immediately and ruthlessly       | Unstoppable force |             |
| 15  | SIGTERM | Tells process to kill itself                   | Terminate         |             |

**Attributes:**
`signal` - id of a signal we want to send
`port` - fd pointing to a port, signals will arrive here, if `nil` unregisters handler.

> [!NOTE]
> A routed signal arrives as a regular `ipc.receive` message (see `34`) with
> `msg.type == "SIGNAL"`. As with any other message, the payload lives under
> `msg.data`:
> ```lua
> {
> 	type = "SIGNAL",
> 	data = {
> 		signal = 0,   -- id of the signal
> 		origin = 0,   -- pid of the sender
> 		data = {},    -- the signal's own args (see the table above), if any
> 	},
> }
> ```

**Errors:**
1. No permissions.

### Synchronisation
---
`128` | `sync.create(type: string, init?: number) -> handle: number`
Creates a new kernel synchronization object.

**Attributes:**
`type` - the type of primitive to create.
- `MUTEX` - Mutual Exclusion lock. Ownership is tracked. Only the thread that locked it can unlock it. Default `init` is `1` (unlocked).
- `SEM` - Semaphore. a counter for shared resources. Default `init` is `0`.
- `COND` - Condition Variable. Used to wait for specific state changes. `init` is ignored. `init`: (Optional) Initial value for the semaphore or mutex state.

**Returns:**
`handle` - a unique id for the synchronization object.

**Errors:**
1. Invalid type specified.
2. Process handle limit reached.

---
`129` | `sync.lock(handle: number, timeout?: number) -> success: boolean`
Acquires a lock (Mutex) or decrements the counter (Semaphore). If the object is busy (Mutex held, Semaphore 0), the calling thread is blocked until it becomes available or the timeout expires.

**Arguments:** 
`handle` - the sync object handle. `timeout`: (Optional) Maximum wait time in seconds.
- `nil` (default): Wait forever.
- `0`: "TryLock" (return immediately if busy).
- `>0`: Wait for X seconds.

**Returns:**
`success` - `true` if acquired, `false` if timeout occured.

**Errors:**
1. Invalid handle.
2. Attempting to lock a mutex you already hold.

---
`130` | `sync.unlock(handle: number) -> void`
Releases a lock (Mutex) or increments the counter (Semaphore). If other threads are waiting on this object, the highest priority (or longest waiting) thread is woken up.

**Arguments:** 
`handle` - the sync object handle.

**Errors:**
1. Attempting to unlock mutex you do not own.
2. Invalid handle.

---
`131` | `sync.wait(cond: number, mutex: number, timeout?: number) -> success: boolean`
Atomically releases the attached `mutex` and blocks execution on the `cond` variable. When the thread wakes up (via `sync.notify` or timeout), it automatically re-acquires the `mutex` before returning.

**Arguments:** 
`cond`- Handle to the Condition Variable. 
`mutex`- Handle to the Mutex currently held by the caller. 
`timeout`- (Optional) Max wait time.

**Returns:** 
`success` - `true` if signaled via notify, `false` if timeout.

**Errors:**
1. Caller does not hold a mutex.
2. Handles are not correct types.

---
`132` | `sync.notify(cond: number, all? boolean) -> void`
Wakes up threads that are sleeping on the specified condition variable.

**Arguments:** 
`cond`: Handle to the Condition Variable. 
`all`: (Optional)
- `false` (default): Wake up **one** waiting thread.
- `true`: Wake up **all** waiting threads (Broadcast).

**Errors:**
1. Invalid handle.